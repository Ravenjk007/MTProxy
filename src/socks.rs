use tokio::io::{copy_bidirectional, AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::timeout;
use log::{debug, error, warn, info};
use std::time::Duration;

/// Autenticação SOCKS5 opcional
#[derive(Clone, Debug)]
pub struct SocksAuth {
    pub username: Option<String>,
    pub password: Option<String>,
    pub timeout_secs: u64,
}

impl Default for SocksAuth {
    fn default() -> Self {
        Self {
            username: None,
            password: None,
            timeout_secs: 10,
        }
    }
}

impl SocksAuth {
    pub fn new(username: Option<String>, password: Option<String>) -> Self {
        Self {
            username,
            password,
            timeout_secs: 10,
        }
    }
}

/// Processar conexão SOCKS5 completa
pub async fn handle_socks5(mut client: TcpStream, auth: &SocksAuth) -> std::io::Result<()> {
    let peer_addr = client.peer_addr().ok();
    debug!("🔌 Nova conexão SOCKS5 de {:?}", peer_addr);

    let timeout_duration = Duration::from_secs(auth.timeout_secs);

    // Passo 1: Ler handshake de métodos
    let mut header = [0u8; 2];
    if timeout(timeout_duration, client.read_exact(&mut header)).await.is_err() {
        warn!("⏱️ Timeout no handshake SOCKS5");
        return Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "Handshake timeout",
        ));
    }

    let nmethods = header[1] as usize;
    if nmethods == 0 || nmethods > 255 {
        warn!("❌ SOCKS5: número inválido de métodos: {}", nmethods);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid number of methods",
        ));
    }

    let mut methods = vec![0u8; nmethods];
    client.read_exact(&mut methods).await?;
    debug!("📋 SOCKS5: métodos oferecidos: {:?}", methods);

    // Selecionar método de autenticação
    let auth_required = auth.username.is_some() && auth.password.is_some();
    let selected_method: u8;

    if auth_required && methods.contains(&0x02) {
        selected_method = 0x02; // Username/password
        debug!("🔐 SOCKS5: autenticação por usuário/senha selecionada");
    } else if methods.contains(&0x00) {
        selected_method = 0x00; // No authentication
        debug!("🔓 SOCKS5: sem autenticação");
    } else {
        warn!("❌ SOCKS5: nenhum método de autenticação compatível");
        client.write_all(&[0x05, 0xFF]).await?;
        return Ok(());
    }

    client.write_all(&[0x05, selected_method]).await?;

    // Passo 2: Autenticação se necessário
    if selected_method == 0x02 {
        let mut auth_header = [0u8; 2];
        if timeout(timeout_duration, client.read_exact(&mut auth_header)).await.is_err() {
            warn!("⏱️ Timeout na autenticação SOCKS5");
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Auth timeout",
            ));
        }

        if auth_header[0] != 0x01 {
            error!("❌ SOCKS5: versão de autenticação inválida: {}", auth_header[0]);
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Invalid auth version",
            ));
        }

        let ulen = auth_header[1] as usize;
        if ulen == 0 || ulen > 255 {
            warn!("❌ SOCKS5: tamanho de usuário inválido: {}", ulen);
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Invalid username length",
            ));
        }

        let mut username_buf = vec![0u8; ulen];
        client.read_exact(&mut username_buf).await?;

        let mut plen_buf = [0u8; 1];
        client.read_exact(&mut plen_buf).await?;
        let plen = plen_buf[0] as usize;
        
        if plen == 0 || plen > 255 {
            warn!("❌ SOCKS5: tamanho de senha inválido: {}", plen);
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Invalid password length",
            ));
        }

        let mut password_buf = vec![0u8; plen];
        client.read_exact(&mut password_buf).await?;

        let username = String::from_utf8_lossy(&username_buf);
        let password = String::from_utf8_lossy(&password_buf);

        let auth_ok = username.as_ref() == auth.username.as_deref().unwrap_or("")
            && password.as_ref() == auth.password.as_deref().unwrap_or("");

        if auth_ok {
            client.write_all(&[0x01, 0x00]).await?;
            info!("✅ SOCKS5: autenticação bem-sucedida para '{}'", username);
        } else {
            client.write_all(&[0x01, 0x01]).await?;
            warn!("❌ SOCKS5: autenticação falhou para '{}'", username);
            return Ok(());
        }
    }

    // Passo 3: Ler request de conexão
    let mut req_header = [0u8; 3];
    if timeout(timeout_duration, client.read_exact(&mut req_header)).await.is_err() {
        warn!("⏱️ Timeout no request SOCKS5");
        return Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "Request timeout",
        ));
    }

    let version = req_header[0];
    let cmd = req_header[1];

    if version != 0x05 {
        error!("❌ SOCKS5: versão inválida: {}", version);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid SOCKS version",
        ));
    }

    if cmd != 0x01 {
        send_reply(&mut client, 0x07).await?;
        warn!("❌ SOCKS5: comando não suportado: {}", cmd);
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
            debug!("🌐 SOCKS5: destino IPv4 = {}", addr_str);
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
            debug!("🌐 SOCKS5: destino domain = {}", addr_str);
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
            debug!("🌐 SOCKS5: destino IPv6 = {}", addr_str);
            addr_str
        }
        _ => {
            error!("❌ SOCKS5: tipo de endereço inválido: {}", atyp);
            send_reply(&mut client, 0x08).await?;
            return Ok(());
        }
    };

    // Passo 5: Conectar ao destino
    let timeout_duration = Duration::from_secs(auth.timeout_secs);
    info!("🔗 SOCKS5: conectando a {}", target_addr);
    
    match timeout(timeout_duration, TcpStream::connect(&target_addr)).await {
        Ok(Ok(mut remote)) => {
            info!("✅ SOCKS5: conectado ao destino {}", target_addr);
            send_reply(&mut client, 0x00).await?;

            match copy_bidirectional(&mut client, &mut remote).await {
                Ok(bytes) => {
                    info!("📊 SOCKS5: {} bytes transferidos para {}", bytes, target_addr);
                    Ok(())
                }
                Err(e) => {
                    debug!("⚠️ SOCKS5: erro ao encaminhar para {}: {}", target_addr, e);
                    Err(e)
                }
            }
        }
        Ok(Err(e)) => {
            warn!("❌ SOCKS5: falha ao conectar a {}: {}", target_addr, e);
            send_reply(&mut client, 0x05).await?;
            Err(e)
        }
        Err(_) => {
            warn!("⏱️ SOCKS5: timeout ao conectar a {}", target_addr);
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

/// Função auxiliar para processar SOCKS5 com dados já lidos
pub async fn handle_socks5_with_data(
    client: TcpStream,
    auth: &SocksAuth,
    initial_data: &[u8],
) -> std::io::Result<()> {
    debug!("📥 SOCKS5: dados iniciais recebidos ({} bytes)", initial_data.len());
    
    // Reconstruir o stream com os dados iniciais
    // Nota: Isso é um placeholder - você precisará de um buffer personalizado
    // ou usar um BufReader para manter os dados já lidos
    
    handle_socks5(client, auth).await
}
