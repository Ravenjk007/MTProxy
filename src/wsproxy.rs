use tokio::io::{copy_bidirectional, AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use crate::config::Config;

async fn consume_http_headers(socket: &mut TcpStream) -> std::io::Result<()> {
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 1];

    loop {
        socket.read_exact(&mut tmp).await?;
        buf.push(tmp[0]);
        if buf.len() >= 4 && &buf[buf.len() - 4..] == b"\r\n\r\n" {
            break;
        }
        if buf.len() > 8192 {
            break;
        }
    }
    Ok(())
}

pub async fn handle_websocket(mut socket: TcpStream, cfg: &Config) -> std::io::Result<()> {
    consume_http_headers(&mut socket).await?;
    
    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n";
    socket.write_all(response.as_bytes()).await?;
    forward_to_target(socket, &cfg.default_target).await
}

pub async fn handle_direct(mut socket: TcpStream, cfg: &Config) -> std::io::Result<()> {
    let response = format!(
        "HTTP/1.1 200 {}\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n",
        cfg.status
    );
    socket.write_all(response.as_bytes()).await?;
    forward_to_target(socket, &cfg.default_target).await
}

async fn forward_to_target(mut client: TcpStream, target: &str) -> std::io::Result<()> {
    let mut remote = TcpStream::connect(target).await?;
    copy_bidirectional(&mut client, &mut remote).await?;
    Ok(())
}
