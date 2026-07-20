use std::env;
use tokio::net::{TcpListener, TcpStream};

mod config;
mod socks;
mod wsproxy;

use config::Config;

#[tokio::main]
async fn main() {
    let config = parse_args();
    let listener = TcpListener::bind(("0.0.0.0", config.port))
        .await
        .expect("Falha ao abrir a porta");

    println!("MTProxy escutando na porta {}", config.port);

    loop {
        let (socket, _addr) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                eprintln!("Erro ao aceitar conexão: {}", e);
                continue;
            }
        };
        let cfg = config.clone();
        tokio::spawn(async move {
            let _ = handle_client(socket, cfg).await;
        });
    }
}

fn parse_args() -> Config {
    let args: Vec<String> = env::args().collect();
    let mut port: u16 = 80;
    let mut status = "@MTProxy".to_string();
    let mut default_target = "127.0.0.1:22".to_string();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--port" => {
                port = args.get(i + 1).and_then(|v| v.parse().ok()).unwrap_or(port);
                i += 2;
            }
            "--status" => {
                status = args.get(i + 1).cloned().unwrap_or(status);
                i += 2;
            }
            "--target" => {
                default_target = args.get(i + 1).cloned().unwrap_or(default_target);
                i += 2;
            }
            _ => {
                i += 1;
            }
        }
    }

    Config { port, status, default_target }
}

async fn handle_client(socket: TcpStream, cfg: Config) -> std::io::Result<()> {
    let mut peek_buf = [0u8; 8];
    let n = socket.peek(&mut peek_buf).await?;

    if n >= 1 && peek_buf[0] == 0x05 {
        socks::handle_socks5(socket).await
    } else if n >= 3 && &peek_buf[0..3] == b"GET" {
        wsproxy::handle_websocket(socket, &cfg).await
    } else {
        wsproxy::handle_direct(socket, &cfg).await
    }
}
