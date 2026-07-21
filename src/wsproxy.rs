use log::{debug, error, warn};
use tokio::io::{copy_bidirectional, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::config::Config;

/// Lidar com HTTP/WS quando o request já foi parseado pelo main.rs
pub async fn handle_http_parsed(
    mut client: TcpStream,
    config: &Config,
    request_line: &str,
    _headers: &[String],
) -> std::io::Result<()> {
    let parts: Vec<&str> = request_line.trim().split_whitespace().collect();
    if parts.len() < 3 {
        warn!("HTTP: linha inválida: {}", request_line.trim());
        let error_resp = b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        client.write_all(error_resp).await?;
        client.flush().await?;
        return Ok(());
    }

    let method = parts[0];
    debug!("HTTP parsed: {} {}", method, parts[1]);

    if method == "GET" {
        // Verificar WebSocket upgrade
        let is_ws = _headers.iter().any(|h| h.to_lowercase().contains("upgrade: websocket"));

        if is_ws {
            handle_ws_upgrade(&mut client, _headers).await?;
            client.flush().await?;
            let target = config.default_target();
            let _ = forward_to_target(&mut client, &target).await;
        } else {
            handle_http_get(&mut client, config).await?;
            // Connection: close já está na resposta
        }
    } else if method == "CONNECT" {
        handle_http_connect(&mut client).await?;
        client.flush().await?;
        let target = config.default_target();
        let _ = forward_to_target(&mut client, &target).await;
    } else {
        let error_resp = b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        client.write_all(error_resp).await?;
        client.flush().await?;
    }

    Ok(())
}

/// Lidar com HTTP/WS quando os dados já foram lidos pelo main.rs
pub async fn handle_http_with_data(
    mut client: TcpStream,
    config: &Config,
    initial_data: &[u8],
) -> std::io::Result<()> {
    debug!("HTTP: processando request ({} bytes inicial)", initial_data.len());

    let request_str = String::from_utf8_lossy(initial_data);

    // Parse HTTP request
    let first_line = request_str.lines().next().unwrap_or("");
    let parts: Vec<&str> = first_line.split_whitespace().collect();

    if parts.len() < 3 {
        warn!("HTTP request inválido: {}", first_line);
        let error_resp = b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
        client.write_all(error_resp).await?;
        client.flush().await?;
        return Ok(());
    }

    let method = parts[0];
    let _path = parts[1];

    debug!("HTTP: {} {}", method, _path);

    if method != "GET" && method != "CONNECT" {
        warn!("Método HTTP não suportado: {}", method);
        let error_resp = b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
        client.write_all(error_resp).await?;
        client.flush().await?;
        return Ok(());
    }

    // Verificar se é WebSocket upgrade
    let is_ws_upgrade = request_str.to_lowercase().contains("upgrade: websocket");

    if is_ws_upgrade {
        // Parse headers para WebSocket upgrade
        let headers: Vec<String> = request_str
            .split("\r\n")
            .skip(1)
            .filter(|l| !l.trim().is_empty())
            .map(|l| l.trim().to_string())
            .collect();
        // WebSocket upgrade
        handle_ws_upgrade(&mut client, &headers).await?;
        client.flush().await?;

        // Encaminhar bidirecionalmente para o target
        let target = config.default_target();
        match forward_to_target(&mut client, &target).await {
            Ok(_) => {}
            Err(e) => debug!("Erro no encaminhamento WebSocket: {}", e),
        }
        Ok(())
    } else if method == "CONNECT" {
        // HTTP CONNECT - proxy
        handle_http_connect(&mut client).await?;
        client.flush().await?;

        let target = config.default_target();
        match forward_to_target(&mut client, &target).await {
            Ok(_) => {}
            Err(e) => debug!("Erro no encaminhamento CONNECT: {}", e),
        }
        Ok(())
    } else {
        // GET simples - apenas responder com status
        handle_http_get(&mut client, config).await?;
        client.flush().await?;

        debug!("HTTP GET: resposta enviada e flushed");
        Ok(())
    }
}

/// Processar WebSocket upgrade (101 Switching Protocols)
async fn handle_ws_upgrade(
    client: &mut TcpStream,
    headers: &[String],
) -> std::io::Result<()> {
    use sha1::{Digest, Sha1};

    // Extrair WebSocket-Key dos headers
    let ws_key = headers
        .iter()
        .find(|h| h.to_lowercase().starts_with("sec-websocket-key"))
        .and_then(|h| h.split(':').nth(1))
        .map(|v| v.trim())
        .unwrap_or("");

    if ws_key.is_empty() {
        error!("WebSocket: Sec-WebSocket-Key não encontrado");
        client
            .write_all(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            .await?;
        return Ok(());
    }

    // Calcular accept key (RFC 6455) - usar base64, não hex
    let mut hasher = Sha1::new();
    hasher.update(ws_key.as_bytes());
    hasher.update(b"258EAFA5-E914-47DA-95CA-5AB9DC85B14F");
    let accept_key = base64::encode(&hasher.finalize()[..20]);

    // Gerar resposta de upgrade
    let response = format!(
        "HTTP/1.1 101 Switching Protocols\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Accept: {}\r\n\r\n",
        accept_key
    );

    debug!("WebSocket: upgrade aceito (key={})", &ws_key[..8]);
    client.write_all(response.as_bytes()).await?;
    Ok(())
}

/// Processar HTTP CONNECT (proxy mode)
async fn handle_http_connect(client: &mut TcpStream) -> std::io::Result<()> {
    // Enviar 200 Connection Established imediatamente
    let response = "HTTP/1.1 200 Connection Established\r\n\r\n";
    client.write_all(response.as_bytes()).await?;
    debug!("HTTP CONNECT: tunel estabelecido");
    Ok(())
}

/// Processar HTTP GET simples (responde com status)
async fn handle_http_get(client: &mut TcpStream, config: &Config) -> std::io::Result<()> {
    let status = &config.status;
    let response = format!(
        "HTTP/1.1 200 OK\r\n\
         Server: MTProxy/2.0\r\n\
         Content-Type: text/plain\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n\
         {}",
        status.len(),
        status
    );

    client.write_all(response.as_bytes()).await?;
    client.flush().await?;
    // Fechar a escrita (Connection: close) para que o client receba os dados
    // shutdown Write para que o client receba FIN
    // Não podemos usar ? porque shutdown não retorna Result neste contexto
    let _ = client.shutdown();
    debug!("HTTP GET: resposta enviada e conexão fechada (status={})", status);
    Ok(())
}

/// Encaminhar dados para o servidor de destino (pública)
pub async fn forward_to_target(
    client: &mut TcpStream,
    target: &str,
) -> std::io::Result<()> {
    let timeout = tokio::time::Duration::from_secs(15);

    match tokio::time::timeout(timeout, TcpStream::connect(target)).await {
        Ok(Ok(mut remote)) => {
            debug!("Encaminhando para: {}", target);
            copy_bidirectional(client, &mut remote).await?;
            Ok(())
        }
        Ok(Err(e)) => {
            debug!("Falha ao conectar a {}: {}", target, e);
            Err(e)
        }
        Err(_) => {
            debug!("Timeout ao conectar a {}", target);
            Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Target connection timeout",
            ))
        }
    }
}

/// Lidar com conexão direta (TCP puro - modo raw proxy)
pub async fn handle_direct_proxy(
    mut client: TcpStream,
    config: &Config,
) -> std::io::Result<()> {
    debug!("Direct proxy: conexão recebida");

    let status = &config.status;
    let response = format!(
        "HTTP/1.1 200 OK\r\n\
         Server: MTProxy/2.0\r\n\
         Content-Type: text/plain\r\n\
         Content-Length: {}\r\n\
         \r\n\
         {}",
        status.len(),
        status
    );
    client.write_all(response.as_bytes()).await?;
    client.flush().await?;

    Ok(())
}
