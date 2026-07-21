use std::net::SocketAddr;

/// Configuração principal do MTProxy
#[derive(Clone, Debug)]
pub struct Config {
    /// Endereço de escuta (ex: 0.0.0.0:443)
    pub bind_addr: SocketAddr,
    /// Chave secreta em hex (32 chars = 16 bytes)
    pub secret_hex: String,
    /// Prefixo do protocolo: "dd" (direct), "ee" (fake-tls)
    pub prefix: String,
    /// Hostname SNI para FakeTLS (ex: www.google.com)
    pub sni_hostname: String,
    /// Servidores Telegram DC para conectar
    pub dc_servers: Vec<SocketAddr>,
    /// Status/identificador do proxy
    pub status: String,
    /// Timeout de idle em segundos
    pub idle_timeout_secs: u64,
    /// Timeout de handshake em segundos
    pub handshake_timeout_secs: u64,
    /// Cache LRU para proteção anti-replay
    pub replay_cache_size: usize,
    /// Ativar WebSocket mode
    pub ws_enabled: bool,
    /// Ativar SOCKS5 mode
    pub socks_enabled: bool,
    /// Ativar modo direto (MTProto raw)
    pub direct_enabled: bool,
    /// Ativar modo FakeTLS
    pub faketls_enabled: bool,
    /// Forward não reconhecido para este host (probe resistance)
    pub fallback_host: Option<String>,
    /// Log level
    pub log_level: String,
}

impl Config {
    /// Obter o alvo padrão para conexões diretas
    pub fn default_target(&self) -> String {
        if let Some(dc) = self.dc_servers.first() {
            dc.to_string()
        } else {
            "149.154.175.50:443".to_string()
        }
    }

    /// Obter a chave secreta como bytes (16 bytes)
    pub fn secret_bytes(&self) -> [u8; 16] {
        let hex_str = if self.prefix.len() == 2 {
            if self.secret_hex.len() > 2 {
                &self.secret_hex[2..]
            } else {
                &self.secret_hex
            }
        } else {
            &self.secret_hex
        };
        let bytes = hex::decode(hex_str).unwrap_or_else(|_| vec![0u8; 16]);
        let mut result = [0u8; 16];
        let len = bytes.len().min(16);
        result[..len].copy_from_slice(&bytes[..len]);
        result
    }

    /// Gerar link tg://proxy para o cliente Telegram
    pub fn proxy_link(&self) -> String {
        let secret_with_prefix = format!("{}{}", self.prefix, self.secret_hex);
        format!(
            "tg://proxy?server=SERVER_IP&port={}&secret={}&hostname={}",
            self.bind_addr.port(),
            secret_with_prefix,
            self.sni_hostname
        )
    }

    /// Gerar link HTTPS para compartilhamento
    pub fn https_link(&self) -> String {
        let secret_with_prefix = format!("{}{}", self.prefix, self.secret_hex);
        format!(
            "https://t.me/proxy?server=SERVER_IP&port={}&secret={}&hostname={}",
            self.bind_addr.port(),
            secret_with_prefix,
            self.sni_hostname
        )
    }
}

/// Servidores DC do Telegram (endereços atuais conhecidos)
fn default_dc_servers() -> Vec<SocketAddr> {
    vec![
        "149.154.175.50:443".parse().unwrap(),
        "149.154.167.51:443".parse().unwrap(),
        "149.154.175.100:443".parse().unwrap(),
        "149.154.167.91:443".parse().unwrap(),
        "149.154.171.5:443".parse().unwrap(),
        "149.154.175.53:443".parse().unwrap(),
        "149.154.167.40:443".parse().unwrap(),
        "149.154.175.33:443".parse().unwrap(),
        // IPv6
        "[2001:b28:f23d::1]:443".parse().unwrap(),
        "[2001:b28:f23f::1]:443".parse().unwrap(),
        "[2001:67c:4e8:f002::a]:443".parse().unwrap(),
        "[2001:b28:f23e::1]:443".parse().unwrap(),
    ]
}

impl Default for Config {
    fn default() -> Self {
        Self {
            bind_addr: "0.0.0.0:443".parse().unwrap(),
            secret_hex: "00000000000000000000000000000000".to_string(),
            prefix: "ee".to_string(),
            sni_hostname: "www.google.com".to_string(),
            dc_servers: default_dc_servers(),
            status: "@MTProxy".to_string(),
            idle_timeout_secs: 300,
            handshake_timeout_secs: 5,
            replay_cache_size: 100_000,
            ws_enabled: true,
            socks_enabled: true,
            direct_enabled: true,
            faketls_enabled: true,
            fallback_host: Some("www.google.com".to_string()),
            log_level: "info".to_string(),
        }
    }
}
