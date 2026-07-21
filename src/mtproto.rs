use log::{debug, error, warn};
use tokio::io::{copy_bidirectional, AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::crypto::MtCrypto;
use crate::config::Config;

/// Lidar com conexão MTProto no modo Direct (prefixo "dd")
pub async fn handle_direct(
    mut client: TcpStream,
    config: &Config,
) -> std::io::Result<()> {
    debug!("MTProto Direct: iniciando handshake");

    // Ler os primeiros 64 bytes do cliente (init frame)
    let mut init_frame = vec![0u8; 64];
    client.read_exact(&mut init_frame).await?;

    // Verificar prefixo "dd"
    if init_frame[0] != 0xdd || init_frame[1] != 0xdd {
        warn!("MTProto Direct: prefixo inválido");
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid MTProto prefix",
        ));
    }

    // Criar criptografia
    let secret = config.secret_bytes();
    let mut crypto = MtCrypto::from_secret(&secret);

    // Descriptografar o init frame
    crypto.decrypt(&mut init_frame);

    // O init frame contém a chave temporária do cliente nos bytes 8..24
    let mut client_temp_key = [0u8; 16];
    client_temp_key.copy_from_slice(&init_frame[8..24]);

    // Usar a chave temporária do cliente para criar novo crypto
    let mut crypto = MtCrypto::from_secret(&client_temp_key);

    // Criar resposta (também 64 bytes)
    let mut response_frame = crypto.generate_init_frame();

    // O servidor coloca sua chave temporária nos bytes 8..24
    let server_temp_key = {
        let mut key = [0u8; 16];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut key);
        key
    };
    response_frame[8..24].copy_from_slice(&server_temp_key);

    // Criptografar a resposta
    crypto.encrypt(&mut response_frame);

    // Enviar resposta
    client.write_all(&response_frame).await?;
    client.flush().await?;

    debug!("MTProto Direct: handshake concluído, encaminhando");

    // Encaminhar para servidor Telegram
    let target = pick_dc_server(config);
    forward_to_telegram(&mut client, &target).await
}

/// Lidar com conexão MTProto no modo FakeTLS (prefixo "ee")
pub async fn handle_faketls(
    mut client: TcpStream,
    config: &Config,
) -> std::io::Result<()> {
    use crate::crypto::faketls;

    debug!("MTProto FakeTLS: iniciando handshake");

    // Ler dados iniciais (deve ser um TLS ClientHello)
    let mut peek_buf = [0u8; 4096];
    let n = client.peek(&mut peek_buf).await?;

    if n < 43 {
        warn!("MTProto FakeTLS: dados iniciais muito curtos ({} bytes)", n);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "TLS handshake too short",
        ));
    }

    // Verificar se é ClientHello
    if !faketls::is_tls_client_hello(&peek_buf[..n]) {
        warn!("MTProto FakeTLS: não é um ClientHello TLS");
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Not a TLS ClientHello",
        ));
    }

    // Extrair SNI e validar
    let sni = faketls::extract_sni(&peek_buf[..n]);
    debug!("MTProto FakeTLS: SNI extraído = {:?}", sni);

    // Ler o ClientHello completo (TLS record)
    let tls_len = u16::from_be_bytes([peek_buf[3], peek_buf[4]]) as usize + 5;
    let mut client_hello = vec![0u8; tls_len];
    client.read_exact(&mut client_hello).await?;

    // Gerar e enviar ServerHello falso
    let server_hello = faketls::generate_server_hello();
    client.write_all(&server_hello).await?;
    client.flush().await?;

    debug!("MTProto FakeTLS: ServerHello enviado");

    // Agora recebemos os dados MTProto encapsulados em ApplicationData
    // Ler o próximo record TLS
    let mut record_header = [0u8; 5];
    client.read_exact(&mut record_header).await?;

    if record_header[0] != 0x17 {
        warn!("MTProto FakeTLS: esperado ApplicationData, recebido {:?}", record_header[0]);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Expected ApplicationData",
        ));
    }

    let record_len = u16::from_be_bytes([record_header[3], record_header[4]]) as usize;
    let mut mtproto_frame = vec![0u8; record_len];
    client.read_exact(&mut mtproto_frame).await?;

    // Descriptografar o init frame MTProto
    let secret = config.secret_bytes();
    let mut crypto = MtCrypto::from_secret(&secret);
    crypto.decrypt(&mut mtproto_frame);

    // Obter chave temporária do cliente
    let mut client_temp_key = [0u8; 16];
    client_temp_key.copy_from_slice(&mtproto_frame[8..24]);

    // Criar novo crypto com a chave do cliente
    let mut crypto = MtCrypto::from_secret(&client_temp_key);

    // Gerar resposta
    let mut response_frame = crypto.generate_init_frame();
    let server_temp_key = {
        let mut key = [0u8; 16];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut key);
        key
    };
    response_frame[8..24].copy_from_slice(&server_temp_key);
    crypto.encrypt(&mut response_frame);

    // Enviar resposta encapsulada em ApplicationData
    let response_record = faketls::wrap_in_application_data(&response_frame);
    client.write_all(&response_record).await?;
    client.flush().await?;

    debug!("MTProto FakeTLS: handshake concluído, encaminhando");

    // Encaminhar para Telegram
    let target = pick_dc_server(config);
    forward_to_telegram(&mut client, &target).await
}

/// Lidar com conexão MTProto Direct com dados já lidos
pub async fn handle_direct_with_data(
    mut client: TcpStream,
    config: &Config,
    initial_data: &[u8],
) -> std::io::Result<()> {
    debug!("MTProto Direct: dados iniciais ({} bytes)", initial_data.len());

    // Verificar prefixo "dd"
    if initial_data.len() < 2 || initial_data[0] != 0xdd || initial_data[1] != 0xdd {
        warn!("MTProto Direct: prefixo inválido");
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid MTProto prefix",
        ));
    }

    // Precisamos de 64 bytes para o init frame
    let mut init_frame = vec![0u8; 64];
    let available = initial_data.len().min(64);
    init_frame[..available].copy_from_slice(&initial_data[..available]);

    if available < 64 {
        let remaining = 64 - available;
        let mut rem_buf = vec![0u8; remaining];
        client.read_exact(&mut rem_buf).await?;
        init_frame[available..].copy_from_slice(&rem_buf);
    }

    // Criar criptografia
    let secret = config.secret_bytes();
    let mut crypto = MtCrypto::from_secret(&secret);

    // Descriptografar o init frame
    crypto.decrypt(&mut init_frame);

    // Obter chave temporária do cliente
    let mut client_temp_key = [0u8; 16];
    client_temp_key.copy_from_slice(&init_frame[8..24]);

    // Criar novo crypto com a chave do cliente
    let mut crypto = MtCrypto::from_secret(&client_temp_key);

    // Gerar resposta
    let mut response_frame = crypto.generate_init_frame();
    let server_temp_key = {
        let mut key = [0u8; 16];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut key);
        key
    };
    response_frame[8..24].copy_from_slice(&server_temp_key);
    crypto.encrypt(&mut response_frame);

    client.write_all(&response_frame).await?;
    client.flush().await?;

    debug!("MTProto Direct: handshake concluído, encaminhando");

    let target = pick_dc_server(config);
    forward_to_telegram(&mut client, &target).await
}

/// Lidar com conexão MTProto FakeTLS com dados já lidos
pub async fn handle_faketls_with_data(
    mut client: TcpStream,
    config: &Config,
    initial_data: &[u8],
) -> std::io::Result<()> {
    use crate::crypto::faketls;

    debug!("MTProto FakeTLS: dados iniciais ({} bytes)", initial_data.len());

    if initial_data.len() < 43 {
        warn!("MTProto FakeTLS: dados muito curtos ({} bytes)", initial_data.len());
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "TLS handshake too short",
        ));
    }

    if !faketls::is_tls_client_hello(initial_data) {
        warn!("MTProto FakeTLS: não é ClientHello");
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Not a TLS ClientHello",
        ));
    }

    let sni = faketls::extract_sni(initial_data);
    debug!("MTProto FakeTLS: SNI = {:?}", sni);

    // Ler o ClientHello completo
    let tls_len = u16::from_be_bytes([initial_data[3], initial_data[4]]) as usize + 5;
    let mut client_hello = vec![0u8; tls_len];
    let available = initial_data.len().min(tls_len);
    client_hello[..available].copy_from_slice(&initial_data[..available]);

    if available < tls_len {
        let remaining = tls_len - available;
        let mut rem_buf = vec![0u8; remaining];
        client.read_exact(&mut rem_buf).await?;
        client_hello[available..].copy_from_slice(&rem_buf);
    }

    // Gerar e enviar ServerHello falso
    let server_hello = faketls::generate_server_hello();
    client.write_all(&server_hello).await?;
    client.flush().await?;

    debug!("MTProto FakeTLS: ServerHello enviado");

    // Ler o próximo record TLS (ApplicationData)
    let mut record_header = [0u8; 5];
    client.read_exact(&mut record_header).await?;

    if record_header[0] != 0x17 {
        warn!("MTProto FakeTLS: esperado ApplicationData, recebido {:?}", record_header[0]);
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Expected ApplicationData",
        ));
    }

    let record_len = u16::from_be_bytes([record_header[3], record_header[4]]) as usize;
    let mut mtproto_frame = vec![0u8; record_len];
    client.read_exact(&mut mtproto_frame).await?;

    // Descriptografar o init frame MTProto
    let secret = config.secret_bytes();
    let mut crypto = MtCrypto::from_secret(&secret);
    crypto.decrypt(&mut mtproto_frame);

    let mut client_temp_key = [0u8; 16];
    client_temp_key.copy_from_slice(&mtproto_frame[8..24]);

    let mut crypto = MtCrypto::from_secret(&client_temp_key);

    let mut response_frame = crypto.generate_init_frame();
    let server_temp_key = {
        let mut key = [0u8; 16];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut key);
        key
    };
    response_frame[8..24].copy_from_slice(&server_temp_key);
    crypto.encrypt(&mut response_frame);

    let response_record = faketls::wrap_in_application_data(&response_frame);
    client.write_all(&response_record).await?;
    client.flush().await?;

    debug!("MTProto FakeTLS: handshake concluído, encaminhando");

    let target = pick_dc_server(config);
    forward_to_telegram(&mut client, &target).await
}

/// Encaminhar conexão para um servidor Telegram DC
async fn forward_to_telegram(
    client: &mut TcpStream,
    target: &std::net::SocketAddr,
) -> std::io::Result<()> {
    let timeout = tokio::time::Duration::from_secs(10);

    match tokio::time::timeout(timeout, TcpStream::connect(target)).await {
        Ok(Ok(mut remote)) => {
            debug!("Conectado ao DC: {}", target);
            match copy_bidirectional(client, &mut remote).await {
                Ok(_) => Ok(()),
                Err(e) => {
                    debug!("Erro no encaminhamento: {}", e);
                    Err(e)
                }
            }
        }
        Ok(Err(e)) => {
            error!("Falha ao conectar ao DC {}: {}", target, e);
            Err(e)
        }
        Err(_) => {
            warn!("Timeout ao conectar ao DC {}", target);
            Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "DC connection timeout",
            ))
        }
    }
}

/// Selecionar um servidor DC aleatório
fn pick_dc_server(config: &Config) -> std::net::SocketAddr {
    if config.dc_servers.is_empty() {
        return "149.154.175.50:443".parse().unwrap();
    }
    use rand::seq::SliceRandom;
    config
        .dc_servers
        .choose(&mut rand::thread_rng())
        .cloned()
        .unwrap()
}
