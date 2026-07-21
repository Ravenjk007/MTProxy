use tokio::io::{copy_bidirectional, AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use log::{debug, error, warn};

/// Autenticação SOCKS5 opcional
#[derive(Clone, Debug)]
pub struct SocksAuth {
    pub username: Option<String>,
    pub password: Option<String>,
}

impl Default for SocksAuth {
    fn default() -> Self {
        Self {
            username: None,
            password: None,
        }
    }
}

/// Processar conexão SOCKS5 completa
pub async fn handle_socks5(mut client: TcpStream, auth: &SocksAuth) -> std::io::Result<()> {
    debug!("Nova conexão SOCKS5 recebida");

    // Passo 1: Ler handshake de métodos
    let mut header = [0u8; 2];
    client.read_exact(&mut header).await?;
    let nmethods = header[1] as usize;

    if nmethods == 0 || nmethods > 255 {
        warn!("SOCKS5: número inválido de métodos: {}", nmethods);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid number of methods",
        ));
    }

    let mut methods = vec![0u8; nmethods];
    client.read_exact(&mut methods).await?;

    debug!("SOCKS5: métodos oferecidos: {:?}", methods);

    // Selecionar método de autenticação
    let auth_required = auth.username.is_some() && auth.password.is_some();
    let selected_method: u8;

    if auth_required && methods.contains(&0x02) {
        selected_method = 0x02; // Username/password
    } else if methods.contains(&0x00) {
        selected_method = 0x00; // No authentication
    } else {
        warn!("SOCKS5: nenhum método de autenticação compatível");
        client.write_all(&[0x05, 0xFF]).await?;
        return Ok(());
    }

    client.write_all(&[0x05, selected_method]).await?;

    // Passo 2: Autenticação se necessário
    if selected_method == 0x02 {
        let mut auth_header = [0u8; 2];
        client.read_exact(&mut auth_header).await?;

        if auth_header[0] != 0x01 {
            error!("SOCKS5: versão de autenticação inválida: {}", auth_header[0]);
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Invalid auth version",
            ));
        }

        let ulen = auth_header[1] as usize;
        let mut username_buf = vec![0u8; ulen];
        client.read_exact(&mut username_buf).await?;

        let mut plen_buf = [0u8; 1];
        client.read_exact(&mut plen_buf).await?;
        let plen = plen_buf[0] as usize;
        let mut password_buf = vec![0u8; plen];
        client.read_exact(&mut password_buf).await?;

        let username = String::from_utf8_lossy(&username_buf);
        let password = String::from_utf8_lossy(&password_buf);

        let auth_ok = username.as_ref() == auth.username.as_deref().unwrap_or("")
            && password.as_ref() == auth.password.as_deref().unwrap_or("");

        if auth_ok {
            client.write_all(&[0x01, 0x00]).await?; // Auth success
        } else {
            client.write_all(&[0x01, 0x01]).await?; // Auth failure
            warn!("SOCKS5: autenticação falhou para usuário '{}'", username);
            return Ok(());
        }
    }

    // Passo 3: Ler request de conexão
    let mut req_header = [0u8; 3];
    client.read_exact(&mut req_header).await?;

    let version = req_header[0];
    let cmd = req_header[1];
    let _rsv = req_header[2];

    if version != 0x05 {
        error!("SOCKS5: versão inválida: {}", version);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid SOCKS version",
        ));
    }

    // Apenas CONNECT suportado
    if cmd != 0x01 {
        send_reply(&mut client, 0x07).await?; // Command not supported
        warn!("SOCKS5: comando não suportado: {}", cmd);
        return Ok(());
    }

    // Passo 4: Ler endereço de destino
    let atyp_buf = [0u8; 1];
    let mut atype_byte = atyp_buf;
    client.read_exact(&mut atype_byte).await?;
    let atyp = atype_byte[0];

    let target_addr = match atyp {
        0x01 => {
            // IPv4
            let mut addr = [0u8; 4];
            client.read_exact(&mut addr).await?;
            let port = read_port(&mut client).await?;
            let addr_str = format!("{}.{}.{}.{}:{}", addr[0], addr[1], addr[2], addr[3], port);
            debug!("SOCKS5: destino IPv4 = {}", addr_str);
            addr_str
        }
        0x03 => {
            // Domain name
            let mut len_buf = [0u8; 1];
            client.read_exact(&mut len_buf).await?;
            let len = len_buf[0] as usize;
            if len == 0 || len > 255 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Invalid domain length",
                ));
            }
            let mut domain = vec![0u8; len];
            client.read_exact(&mut domain).await?;
            let port = read_port(&mut client).await?;
            let addr_str = format!("{}:{}", String::from_utf8_lossy(&domain), port);
            debug!("SOCKS5: destino domain = {}", addr_str);
            addr_str
        }
        0x04 => {
            // IPv6
            let mut addr = [0u8; 16];
            client.read_exact(&mut addr).await?;
            let port = read_port(&mut client).await?;
            let segments: Vec<String> = addr
                .chunks(2)
                .map(|c| format!("{:02x}{:02x}", c[0], c[1]))
                .collect();
            let addr_str = format!("[{}]:{}", segments.join(":"), port);
            debug!("SOCKS5: destino IPv6 = {}", addr_str);
            addr_str
        }
        _ => {
            error!("SOCKS5: tipo de endereço inválido: {}", atyp);
            send_reply(&mut client, 0x08).await?; // Address type not supported
            return Ok(());
        }
    };

    // Passo 5: Conectar ao destino
    let timeout = tokio::time::Duration::from_secs(10);
    match tokio::time::timeout(timeout, TcpStream::connect(&target_addr)).await {
        Ok(Ok(mut remote)) => {
            debug!("SOCKS5: conectado ao destino {}", target_addr);
            send_reply(&mut client, 0x00).await?; // Success

            // Encaminhar dados bidirecionalmente
            match copy_bidirectional(&mut client, &mut remote).await {
                Ok(_) => {
                    debug!("SOCKS5: conexão encerrada normalmente para {}", target_addr);
                    Ok(())
                }
                Err(e) => {
                    debug!("SOCKS5: erro ao encaminhar para {}: {}", target_addr, e);
                    Err(e)
                }
            }
        }
        Ok(Err(e)) => {
            warn!("SOCKS5: falha ao conectar a {}: {}", target_addr, e);
            send_reply(&mut client, 0x05).await?; // Connection refused
            Err(e)
        }
        Err(_) => {
            warn!("SOCKS5: timeout ao conectar a {}", target_addr);
            send_reply(&mut client, 0x05).await?; // Connection refused
            Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Connection timeout",
            ))
        }
    }
}

/// Processar SOCKS5 com dados já lidos pelo main.rs
pub async fn handle_socks5_with_data(
    mut client: TcpStream,
    auth: &SocksAuth,
    initial_data: &[u8],
) -> std::io::Result<()> {
    debug!("SOCKS5: dados iniciais recebidos ({} bytes)", initial_data.len());

    // Passo 1: Parse handshake de métodos (primeiros 2 bytes)
    if initial_data.len() < 2 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Insufficient SOCKS5 handshake data",
        ));
    }

    let nmethods = initial_data[1] as usize;
    let expected_len = 2 + nmethods;

    if nmethods == 0 || nmethods > 255 {
        warn!("SOCKS5: número inválido de métodos: {}", nmethods);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid number of methods",
        ));
    }

    // Métodos podem estar nos dados iniciais ou precisar ler mais
    let methods = if expected_len <= initial_data.len() {
        initial_data[2..expected_len].to_vec()
    } else {
        // Ler os métodos restantes
        let mut methods = vec![0u8; nmethods];
        let available = initial_data.len().saturating_sub(2);
        methods[..available].copy_from_slice(&initial_data[2..]);
        if available < nmethods {
            let remaining = nmethods - available;
            let mut rem_buf = vec![0u8; remaining];
            client.read_exact(&mut rem_buf).await?;
            methods[available..].copy_from_slice(&rem_buf);
        }
        methods
    };

    debug!("SOCKS5: métodos oferecidos: {:?}", methods);

    // Selecionar método de autenticação
    let auth_required = auth.username.is_some() && auth.password.is_some();
    let selected_method: u8;

    if auth_required && methods.contains(&0x02) {
        selected_method = 0x02;
    } else if methods.contains(&0x00) {
        selected_method = 0x00;
    } else {
        warn!("SOCKS5: nenhum método compatível");
        client.write_all(&[0x05, 0xFF]).await?;
        return Ok(());
    }

    client.write_all(&[0x05, selected_method]).await?;
    client.flush().await?;

    // Passo 2: Autenticação se necessário
    if selected_method == 0x02 {
        let mut auth_header = [0u8; 2];
        client.read_exact(&mut auth_header).await?;

        if auth_header[0] != 0x01 {
            error!("SOCKS5: versão auth inválida: {}", auth_header[0]);
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Invalid auth version",
            ));
        }

        let ulen = auth_header[1] as usize;
        let mut username_buf = vec![0u8; ulen];
        client.read_exact(&mut username_buf).await?;

        let mut plen_buf = [0u8; 1];
        client.read_exact(&mut plen_buf).await?;
        let plen = plen_buf[0] as usize;
        let mut password_buf = vec![0u8; plen];
        client.read_exact(&mut password_buf).await?;

        let username = String::from_utf8_lossy(&username_buf);
        let password = String::from_utf8_lossy(&password_buf);

        let auth_ok = username.as_ref() == auth.username.as_deref().unwrap_or("")
            && password.as_ref() == auth.password.as_deref().unwrap_or("");

        if auth_ok {
            client.write_all(&[0x01, 0x00]).await?;
        } else {
            client.write_all(&[0x01, 0x01]).await?;
            warn!("SOCKS5: auth falhou para '{}'", username);
            return Ok(());
        }
    }

    // Passo 3: Ler request de conexão
    let mut req_header = [0u8; 3];
    client.read_exact(&mut req_header).await?;

    let cmd = req_header[1];
    if cmd != 0x01 {
        send_reply(&mut client, 0x07).await?;
        warn!("SOCKS5: comando não suportado: {}", cmd);
        return Ok(());
    }

    // Passo 4: Ler endereço de destino
    let mut atype_byte = [0u8; 1];
    client.read_exact(&mut atype_byte).await?;
    let atyp = atype_byte[0];

    let target_addr = match atyp {
        0x01 => {
            let mut addr = [0u8; 4];
            client.read_exact(&mut addr).await?;
            let port = read_port(&mut client).await?;
            let addr_str = format!("{}.{}.{}.{}:{}", addr[0], addr[1], addr[2], addr[3], port);
            debug!("SOCKS5: destino IPv4 = {}", addr_str);
            addr_str
        }
        0x03 => {
            let mut len_buf = [0u8; 1];
            client.read_exact(&mut len_buf).await?;
            let len = len_buf[0] as usize;
            if len == 0 || len > 255 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Invalid domain length",
                ));
            }
            let mut domain = vec![0u8; len];
            client.read_exact(&mut domain).await?;
            let port = read_port(&mut client).await?;
            let addr_str = format!("{}:{}", String::from_utf8_lossy(&domain), port);
            debug!("SOCKS5: destino domain = {}", addr_str);
            addr_str
        }
        0x04 => {
            let mut addr = [0u8; 16];
            client.read_exact(&mut addr).await?;
            let port = read_port(&mut client).await?;
            let segments: Vec<String> = addr
                .chunks(2)
                .map(|c| format!("{:02x}{:02x}", c[0], c[1]))
                .collect();
            let addr_str = format!("[{}]:{}", segments.join(":"), port);
            debug!("SOCKS5: destino IPv6 = {}", addr_str);
            addr_str
        }
        _ => {
            error!("SOCKS5: atyp inválido: {}", atyp);
            send_reply(&mut client, 0x08).await?;
            return Ok(());
        }
    };

    // Passo 5: Conectar ao destino
    let timeout = tokio::time::Duration::from_secs(10);
    match tokio::time::timeout(timeout, TcpStream::connect(&target_addr)).await {
        Ok(Ok(mut remote)) => {
            debug!("SOCKS5: conectado ao destino {}", target_addr);
            send_reply(&mut client, 0x00).await?;

            match copy_bidirectional(&mut client, &mut remote).await {
                Ok(_) => {
                    debug!("SOCKS5: conexão encerrada para {}", target_addr);
                    Ok(())
                }
                Err(e) => {
                    debug!("SOCKS5: erro ao encaminhar: {}", e);
                    Err(e)
                }
            }
        }
        Ok(Err(e)) => {
            warn!("SOCKS5: falha ao conectar a {}: {}", target_addr, e);
            send_reply(&mut client, 0x05).await?;
            Err(e)
        }
        Err(_) => {
            warn!("SOCKS5: timeout ao conectar a {}", target_addr);
            send_reply(&mut client, 0x05).await?;
            Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Connection timeout",
            ))
        }
    }
}

/// Ler porta (2 bytes big-endian)
async fn read_port(client: &mut TcpStream) -> std::io::Result<u16> {
    let mut port_buf = [0u8; 2];
    client.read_exact(&mut port_buf).await?;
    Ok(u16::from_be_bytes(port_buf))
}

/// Enviar resposta SOCKS5
async fn send_reply(client: &mut TcpStream, status: u8) -> std::io::Result<()> {
    // IPv4 reply com endereço 0.0.0.0:0
    client
        .write_all(&[
            0x05,       // Version
            status,     // Status
            0x00,       // Reserved
            0x01,       // IPv4
            0, 0, 0, 0, // 0.0.0.0
            0, 0,       // Port 0
        ])
        .await
}
