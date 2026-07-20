use tokio::net::TcpListener;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use clap::Parser;
use anyhow::Result;
use log::{info, error};
use std::time::Duration;

#[derive(Parser)]
#[command(name = "mtproxy")]
#[command(about = "MTProxy - Multiprotocol VPN/HTTP Inject")]
struct Cli {
    #[arg(short = 'p', long = "port", default_value = "8080")]
    port: u16,
    #[arg(short = 'd', long = "debug")]
    debug: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    
    env_logger::builder()
        .filter_level(if cli.debug { 
            log::LevelFilter::Debug 
        } else { 
            log::LevelFilter::Info 
        })
        .format_timestamp_millis()
        .init();
    
    let addr = format!("0.0.0.0:{}", cli.port);
    info!("🚀 MTProxy listening on {}", addr);
    info!("📡 Mode: Always 200 OK + Keep-Alive");
    info!("💡 Protocols: SOCKS5, TLS, WebSocket, HTTP, SECURITY, TCP");

    let listener = TcpListener::bind(&addr).await?;
    
    while let Ok((mut socket, peer_addr)) = listener.accept().await {
        tokio::spawn(async move {
            let mut buffer = vec![0u8; 4096];
            
            match socket.read(&mut buffer).await {
                Ok(n) if n > 0 => {
                    let request = String::from_utf8_lossy(&buffer[..n]);
                    let first_line = request.lines().next().unwrap_or("");
                    info!("📩 [{}] {}", peer_addr, first_line);
                    
                    // Detectar protocolo
                    let protocol = detect_protocol(&buffer[..n]);
                    info!("📡 [{}] Protocol: {}", peer_addr, protocol);
                    
                    // Resposta 200 OK para todos
                    let response = "HTTP/1.1 200 OK\r\n\
                                    Content-Type: text/plain\r\n\
                                    Content-Length: 2\r\n\
                                    Connection: keep-alive\r\n\
                                    Server: MTProxy\r\n\
                                    \r\n\
                                    OK";
                    
                    let _ = socket.write_all(response.as_bytes()).await;
                    info!("✅ [{}] 200 OK sent", peer_addr);
                    
                    // Keep-Alive infinito
                    let mut interval = tokio::time::interval(Duration::from_secs(15));
                    loop {
                        interval.tick().await;
                        if socket.write_all(b"\r\n").await.is_err() {
                            info!("🔚 [{}] Connection closed", peer_addr);
                            break;
                        }
                    }
                }
                Ok(_) => info!("📦 [{}] Empty request", peer_addr),
                Err(e) => error!("❌ [{}] Error: {}", peer_addr, e),
            }
        });
    }
    Ok(())
}

fn detect_protocol(data: &[u8]) -> &'static str {
    if data.is_empty() { return "UNKNOWN"; }
    
    // SOCKS5
    if data.len() >= 1 && data[0] == 0x05 { return "SOCKS5"; }
    
    // TLS
    if data.len() >= 3 && data[0] == 0x16 { return "TLS"; }
    
    // HTTP/WebSocket
    if let Ok(text) = std::str::from_utf8(data) {
        let text_lower = text.to_lowercase();
        
        if text_lower.contains("upgrade: websocket") || 
           text_lower.contains("sec-websocket-key") {
            return "WEBSOCKET";
        }
        
        if text.starts_with("GET ") || text.starts_with("POST ") || 
           text.starts_with("PUT ") || text.starts_with("DELETE ") || 
           text.starts_with("CONNECT ") || text.starts_with("HEAD ") ||
           text.starts_with("OPTIONS ") || text.starts_with("PATCH ") ||
           text.contains("HTTP/") {
            return "HTTP";
        }
        
        if text.starts_with("SECURITY") || text.starts_with("AUTH") {
            return "SECURITY";
        }
    }
    
    "TCP"
}
