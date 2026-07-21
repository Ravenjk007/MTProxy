use clap::Parser;
use log::{debug, error, info, warn};
use parking_lot::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

mod config;
mod crypto;
mod mtproto;
mod socks;
mod wsproxy;

use config::Config;
use crypto::{ReplayCache, faketls};
// Argumentos de linha de comando do MTProxy
#[derive(Parser, Debug, Clone)]
#[command(name = "mtproxy", version = "2.0.0", about = "MTProxy - Multi-Protocol Telegram Proxy")]
pub struct Args {
    /// Endereço de binding
    #[arg(long, default_value = "0.0.0.0")]
    pub bind: String,

    /// Porta para escutar
    #[arg(long, default_value_t = 443)]
    pub port: u16,

    /// Chave secreta em hex (32 chars)
    #[arg(long, default_value = "00000000000000000000000000000000")]
    pub secret: String,

    /// Prefixo do protocolo (dd, ee)
    #[arg(long, default_value = "ee")]
    pub prefix: String,

    /// Hostname SNI para FakeTLS
    #[arg(long, default_value = "www.google.com")]
    pub sni: String,

    /// Servidores DC do Telegram
    #[arg(long)]
    pub dc_servers: Option<Vec<std::net::SocketAddr>>,

    /// Status/identificador do proxy
    #[arg(long, default_value = "@MTProxy")]
    pub status: String,

    /// Timeout de idle (segundos)
    #[arg(long, default_value_t = 300)]
    pub idle_timeout: u64,

    /// Timeout de handshake (segundos)
    #[arg(long, default_value_t = 5)]
    pub handshake_timeout: u64,

    /// Tamanho do cache anti-replay
    #[arg(long, default_value_t = 100000)]
    pub replay_cache: usize,

    /// Desativar WebSocket
    #[arg(long)]
    pub no_ws: bool,

    /// Desativar SOCKS5
    #[arg(long)]
    pub no_socks: bool,

    /// Desativar modo direto
    #[arg(long)]
    pub no_direct: bool,

    /// Host de fallback para probe resistance
    #[arg(long)]
    pub fallback: Option<String>,

    /// Nível de log
    #[arg(long, default_value = "info")]
    pub log: String,
}

/// Estatísticas do proxy
pub struct ProxyStats {
    pub total_connections: AtomicU64,
    pub socks_connections: AtomicU64,
    pub faketls_connections: AtomicU64,
    pub direct_connections: AtomicU64,
    pub ws_connections: AtomicU64,
    pub errors: AtomicU64,
}

impl ProxyStats {
    pub fn new() -> Self {
        Self {
            total_connections: AtomicU64::new(0),
            socks_connections: AtomicU64::new(0),
            faketls_connections: AtomicU64::new(0),
            direct_connections: AtomicU64::new(0),
            ws_connections: AtomicU64::new(0),
            errors: AtomicU64::new(0),
        }
    }
}

fn get_protocol_list(config: &Config) -> String {
    let mut protocols = Vec::new();

    if config.socks_enabled {
        protocols.push("SOCKS5");
    }
    if config.prefix == "ee" || config.prefix == "dd" {
        let prefix_name = if config.prefix == "ee" { "FakeTLS" } else { "Direct" };
        protocols.push(prefix_name);
    }
    if config.ws_enabled {
        protocols.push("WebSocket");
    }
    if config.direct_enabled {
        protocols.push("Direct");
    }

    protocols.join(", ")
}

#[tokio::main]
async fn main() {
    let args = Args::parse();

    // Configurar logging
    let log_level = match args.log.as_str() {
        "trace" => "trace",
        "debug" => "debug",
        "info" => "info",
        "warn" => "warn",
        "error" => "error",
        _ => "info",
    };

    std::env::set_var("RUST_LOG", format!("mtproxy={}", log_level));
    env_logger::init();

    // Construir configuração
    let config = build_config(&args);

    // Imprimir banner
    info!("╔══════════════════════════════════════════════╗");
    info!("║          MTProxy v2.0 - Multi-Protocol       ║");
    info!("╠══════════════════════════════════════════════╣");
    info!("║  🎯 Binding: {:<40}║", format!("{}:{}", config.bind_addr.ip(), config.bind_addr.port()));
    info!("║  🔐 Secret: {:<41}║", &config.secret_hex);
    info!("║  📡 Protocol: {:<39}║", if config.prefix == "ee" { "FakeTLS (ee)" } else if config.prefix == "dd" { "Direct (dd)" } else { "Unknown" });
    info!("║  🌐 SNI: {:<44}║", &config.sni_hostname);
    info!("║  📊 Status: {:<41}║", config.status);
    info!("║  🔌 Protocols: {:<36}║", get_protocol_list(&config));
    info!("╚══════════════════════════════════════════════╝");

    // Imprimir links de proxy
    info!("📱 Telegram link: {}", config.proxy_link());
    info!("🌐 HTTPS link: {}", config.https_link());
    info!("Proxy escutando e pronto para aceitar conexões...");

    // Estatísticas
    let stats = Arc::new(ProxyStats::new());

    // Cache anti-replay
    let replay_cache = Arc::new(Mutex::new(ReplayCache::new(config.replay_cache_size)));

    // Iniciar listener
    let listener = match TcpListener::bind(config.bind_addr).await {
        Ok(l) => l,
        Err(e) => {
            error!("Falha ao abrir porta {}: {}", config.bind_addr.port(), e);
            std::process::exit(1);
        }
    };

    // Loop principal
    let cfg = config.clone();
    loop {
        match listener.accept().await {
            Ok((socket, peer_addr)) => {
                let cfg = cfg.clone();
                let stats = stats.clone();
                let replay_cache = replay_cache.clone();

                stats.total_connections.fetch_add(1, Ordering::Relaxed);
                debug!("Nova conexão de: {}", peer_addr);

                tokio::spawn(async move {
                    socket.set_nodelay(true).ok();

                    match detect_and_handle_protocol(socket, cfg, stats.clone(), replay_cache).await {
                        Ok(_) => {
                            debug!("Conexão encerrada normalmente");
                        }
                        Err(e) => {
                            debug!("Erro na conexão: {}", e);
                            stats.errors.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                });
            }
            Err(e) => {
                error!("Erro ao aceitar conexão: {}", e);
            }
        }
    }
}

/// Detectar protocolo e rotear para o handler correto
async fn detect_and_handle_protocol(
    mut socket: tokio::net::TcpStream,
    config: Config,
    stats: Arc<ProxyStats>,
    _replay_cache: Arc<Mutex<ReplayCache>>,
) -> std::io::Result<()> {
    use tokio::io::AsyncBufReadExt;
    use tokio::io::BufReader;

    let timeout = tokio::time::Duration::from_secs(config.handshake_timeout_secs);

    // Ler apenas os primeiros 2 bytes para detecção de protocolo
    let mut detect_buf = [0u8; 2];
    let n = tokio::time::timeout(timeout, socket.read(&mut detect_buf[..])).await??;

    if n == 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "Empty connection",
        ));
    }

    debug!("Detectando protocolo: primeiro byte = 0x{:02x}", detect_buf[0]);

    // Detectar protocolo pelos primeiros bytes
    let result = match detect_buf[0] {
        // SOCKS5
        0x05 => {
            stats.socks_connections.fetch_add(1, Ordering::Relaxed);
            info!("SOCKS5 connection");
            let auth = socks::SocksAuth::default();
            socks::handle_socks5_with_data(socket, &auth, &detect_buf[..n]).await
        }

        // TLS ClientHello (possível FakeTLS)
        0x16 => {
            // Ler TLS record completo
            let mut tls_buf = vec![0u8; 4096];
            let mut total = n;
            tls_buf[..n].copy_from_slice(&detect_buf[..n]);
            if n >= 5 {
                let rec_len = u16::from_be_bytes([detect_buf[3], detect_buf[4]]) as usize + 5;
                if rec_len > n && rec_len <= 4096 {
                    let mut extra = vec![0u8; rec_len - n];
                    socket.read_exact(&mut extra).await?;
                    tls_buf[n..rec_len].copy_from_slice(&extra);
                    total = rec_len;
                }
            }
            if faketls::is_tls_client_hello(&tls_buf[..total]) {
                stats.faketls_connections.fetch_add(1, Ordering::Relaxed);
                info!("FakeTLS connection");
                mtproto::handle_faketls_with_data(socket, &config, &tls_buf[..total]).await
            } else {
                warn!("TLS não reconhecido");
                handle_fallback_with_data(socket, &config, &tls_buf[..total]).await
            }
        }

        // MTProto Direct (dd)
        0xdd => {
            if n >= 2 && detect_buf[1] == 0xdd {
                // Ler 64 bytes para o init frame
                let mut frame = vec![0u8; 64];
                frame[..n].copy_from_slice(&detect_buf[..n]);
                if n < 64 {
                    socket.read_exact(&mut frame[n..64]).await?;
                }
                stats.direct_connections.fetch_add(1, Ordering::Relaxed);
                info!("MTProto Direct connection");
                mtproto::handle_direct_with_data(socket, &config, &frame[..64]).await
            } else {
                debug!("Byte 0xdd mas não é MTProto Direct");
                handle_fallback_with_data(socket, &config, &detect_buf[..n]).await
            }
        }

        // MTProto FakeTLS (ee)
        0xee => {
            if n >= 2 && detect_buf[1] == 0xee {
                // Ler TLS record completo após o prefixo ee
                let mut tls_buf = vec![0u8; 4096];
                // Re-ler porque já consumimos 2 bytes
                let mut extra_buf = vec![0u8; 4096];
                let extra_n = socket.read(&mut extra_buf).await?;
                // Re-criar buffer com os 2 bytes de prefixo + dados lidos
                let mut full_buf = Vec::with_capacity(2 + extra_n);
                full_buf.extend_from_slice(&detect_buf[..2]);
                full_buf.extend_from_slice(&extra_buf[..extra_n]);
                let total = full_buf.len();
                if total >= 5 {
                    let rec_len = u16::from_be_bytes([full_buf[3], full_buf[4]]) as usize + 5;
                    let needed = total.min(rec_len);
                    stats.faketls_connections.fetch_add(1, Ordering::Relaxed);
                    info!("MTProto FakeTLS connection");
                    mtproto::handle_faketls_with_data(socket, &config, &full_buf[..needed]).await
                } else {
                    handle_fallback_with_data(socket, &config, &full_buf[..total]).await
                }
            } else {
                debug!("Byte 0xee mas não é MTProto FakeTLS");
                handle_fallback_with_data(socket, &config, &detect_buf[..n]).await
            }
        }

        // HTTP GET/CONNECT
        b'G' | b'C' => {
            if n >= 1 {
                // Ler todo o HTTP request (request line + headers)
                // O primeiro byte (G ou C) já foi consumido, mas o resto está no buffer TCP
                let mut request_buf = Vec::with_capacity(4096);
                request_buf.push(detect_buf[0]);
                if n == 2 {
                    request_buf.push(detect_buf[1]);
                }

                // Ler bytes restantes até \r\n\r\n ou timeout
                let mut buf = [0u8; 1];
                let mut found_end = false;
                loop {
                    match tokio::time::timeout(timeout, socket.read(&mut buf)).await {
                        Ok(Ok(0)) | Ok(Err(_)) | Err(_) => break,
                        Ok(Ok(_)) => {
                            request_buf.push(buf[0]);
                            let len = request_buf.len();
                            if len >= 4 {
                                let last4 = &request_buf[len-4..];
                                if last4 == b"\r\n\r\n" {
                                    found_end = true;
                                    break;
                                }
                            }
                            if request_buf.len() >= 4096 {
                                break;
                            }
                        }
                    }
                }

                let request_str = String::from_utf8_lossy(&request_buf);
                let first_line = request_str.lines().next().unwrap_or("");
                let parts: Vec<&str> = first_line.split_whitespace().collect();

                if parts.len() >= 3 && (parts[0] == "GET" || parts[0] == "CONNECT") {
                    // As linhas de headers podem ter \r no final, e a última linha vazia deve ser excluída
                    let headers: Vec<String> = request_str
                        .split("\r\n")
                        .skip(1)  // Pular a request line
                        .filter(|l| !l.trim().is_empty())
                        .map(|l| l.trim().to_string())
                        .collect();
                    stats.ws_connections.fetch_add(1, Ordering::Relaxed);
                    if parts[0] == "GET" {
                        info!("HTTP GET/WebSocket");
                    } else {
                        info!("HTTP CONNECT");
                    }
                    wsproxy::handle_http_parsed(socket, &config, first_line, &headers).await
                } else {
                    handle_fallback_with_data(socket, &config, &request_buf).await
                }
            } else {
                handle_fallback_with_data(socket, &config, &detect_buf[..n]).await
            }
        }

        // Outro - possível probe ou conexão não reconhecida
        _ => {
            debug!("Protocolo não reconhecido (0x{:02x})", detect_buf[0]);
            handle_fallback_with_data(socket, &config, &detect_buf[..n]).await
        }
    };

    result
}

/// Fallback para dados já lidos no stream (sem BufReader)
async fn handle_fallback_stream(
    mut socket: tokio::net::TcpStream,
    config: &Config,
    first_byte: u8,
) -> std::io::Result<()> {
    debug!("Fallback stream: primeiro byte 0x{:02x}", first_byte);

    // Drenar dados restantes
    let mut buf = [0u8; 4096];
    loop {
        match tokio::time::timeout(
            tokio::time::Duration::from_millis(200),
            socket.read(&mut buf),
        )
        .await
        {
            Ok(Ok(n)) if n > 0 => {}
            _ => break,
        }
    }

    if let Some(ref fallback_host) = config.fallback_host {
        let timeout = tokio::time::Duration::from_secs(10);
        match tokio::time::timeout(timeout, TcpStream::connect(fallback_host)).await {
            Ok(Ok(mut remote)) => {
                remote.write_all(&[first_byte]).await?;
                tokio::io::copy_bidirectional(&mut socket, &mut remote).await?;
            }
            _ => {}
        }
        Ok(())
    } else {
        let response = format!(
            "HTTP/1.1 200 OK\r\nServer: MTProxy/2.0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
        socket.write_all(response.as_bytes()).await?;
        socket.flush().await?;
        Ok(())
    }
}

/// Encaminhar conexão não reconhecida para fallback (probe resistance)
async fn handle_fallback_with_data(
    mut socket: tokio::net::TcpStream,
    config: &Config,
    initial_data: &[u8],
) -> std::io::Result<()> {
    if let Some(ref fallback_host) = config.fallback_host {
        debug!("Fallback: encaminhando para {}", fallback_host);

        // Conectar ao fallback
        let timeout = tokio::time::Duration::from_secs(10);
        match tokio::time::timeout(timeout, TcpStream::connect(fallback_host)).await {
            Ok(Ok(mut remote)) => {
                // Enviar dados iniciais já lidos
                remote.write_all(initial_data).await?;
                // Encaminhar bidirecionalmente
                tokio::io::copy_bidirectional(&mut socket, &mut remote).await?;
            }
            Ok(Err(e)) => {
                debug!("Falha ao conectar fallback: {}", e);
            }
            Err(_) => {
                debug!("Timeout ao conectar fallback");
            }
        }
        Ok(())
    } else {
        // Sem fallback - enviar resposta genérica
        let response = format!(
            "HTTP/1.1 200 OK\r\nServer: MTProxy/2.0\r\nContent-Length: 0\r\n\r\n"
        );
        socket.write_all(response.as_bytes()).await?;
        socket.flush().await?;
        Ok(())
    }
}

/// Construir a configuração a partir dos argumentos
fn build_config(args: &Args) -> Config {
    let bind_addr: std::net::SocketAddr = format!("{}:{}", args.bind, args.port)
        .parse()
        .unwrap_or_else(|_| {
            eprintln!("Erro: endereço inválido");
            std::process::exit(1);
        });

    Config {
        bind_addr,
        secret_hex: args.secret.clone(),
        prefix: args.prefix.clone(),
        sni_hostname: args.sni.clone(),
        dc_servers: args.dc_servers.clone().unwrap_or_default(),
        status: args.status.clone(),
        idle_timeout_secs: args.idle_timeout,
        handshake_timeout_secs: args.handshake_timeout,
        replay_cache_size: args.replay_cache,
        ws_enabled: !args.no_ws,
        socks_enabled: !args.no_socks,
        direct_enabled: !args.no_direct,
        faketls_enabled: true,
        fallback_host: args.fallback.clone(),
        log_level: args.log.clone(),
    }
}
