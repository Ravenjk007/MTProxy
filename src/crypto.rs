use aes::cipher::{KeyIvInit, StreamCipher};
use rand::RngCore;
use sha1::{Digest, Sha1};
use std::collections::VecDeque;

type AesCtr = ctr::Ctr128BE<aes::Aes128>;

/// Cache LRU simples para proteção anti-replay
pub struct ReplayCache {
    cache: VecDeque<Vec<u8>>,
    max_size: usize,
}

impl ReplayCache {
    pub fn new(max_size: usize) -> Self {
        Self {
            cache: VecDeque::with_capacity(max_size),
            max_size,
        }
    }

    pub fn check_and_insert(&mut self, key: &[u8]) -> bool {
        if self.cache.iter().any(|k| k == key) {
            return false; // Replay detectado
        }
        if self.cache.len() >= self.max_size {
            self.cache.pop_front();
        }
        self.cache.push_back(key.to_vec());
        true
    }
}

/// Estado criptográfico para uma conexão MTProto
pub struct MtCrypto {
    pub encrypt_key: [u8; 16],
    pub encrypt_iv: [u8; 16],
    pub decrypt_key: [u8; 16],
    pub decrypt_iv: [u8; 16],
    encrypt_cipher: AesCtr,
    decrypt_cipher: AesCtr,
    pub secret_key: [u8; 16],
}

impl MtCrypto {
    pub fn from_secret(secret: &[u8; 16]) -> Self {
        // Gerar chave e IV de criptografia baseados no secret
        let (encrypt_key, encrypt_iv) = Self::derive_key_iv(secret);
        // Para a direção oposta, trocar bytes
        let mut decrypt_key = [0u8; 16];
        let mut decrypt_iv = [0u8; 16];
        for i in 0..16 {
            decrypt_key[i] = encrypt_key[15 - i];
            decrypt_iv[i] = encrypt_iv[15 - i];
        }

        let encrypt_cipher = AesCtr::new(encrypt_key.as_ref().into(), encrypt_iv.as_ref().into());
        let decrypt_cipher = AesCtr::new(decrypt_key.as_ref().into(), decrypt_iv.as_ref().into());

        Self {
            encrypt_key,
            encrypt_iv,
            decrypt_key,
            decrypt_iv,
            encrypt_cipher,
            decrypt_cipher,
            secret_key: *secret,
        }
    }

    /// Derivar chave e IV do secret usando SHA1
    fn derive_key_iv(secret: &[u8; 16]) -> ([u8; 16], [u8; 16]) {
        // Tentar gerar chave/IV que não sejam zeros e não coincidam com padrões
        let mut nonce = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut nonce);

        let mut key = [0u8; 16];
        let mut iv = [0u8; 16];

        loop {
            // Hash 1: key
            let mut hasher = Sha1::new();
            hasher.update(&nonce);
            hasher.update(secret);
            let hash1 = hasher.finalize();
            key.copy_from_slice(&hash1[0..16]);

            // Hash 2: iv
            let mut hasher = Sha1::new();
            hasher.update(secret);
            hasher.update(&nonce);
            let hash2 = hasher.finalize();
            iv.copy_from_slice(&hash2[0..16]);

            // Hash 3: verificar que não é zero
            let mut hasher = Sha1::new();
            hasher.update(&nonce);
            hasher.update(&nonce);
            let _hash3 = hasher.finalize();

            // Verificar que a chave não começa com zeros
            if key.iter().any(|&b| b != 0) {
                break;
            }
            // Gerar novo nonce
            rand::thread_rng().fill_bytes(&mut nonce);
        }

        (key, iv)
    }

    /// Criptografar dados (client -> server direction)
    pub fn encrypt(&mut self, data: &mut [u8]) {
        self.encrypt_cipher.apply_keystream(data);
    }

    /// Descriptografar dados (server -> client direction)
    pub fn decrypt(&mut self, data: &mut [u8]) {
        self.decrypt_cipher.apply_keystream(data);
    }

    /// Gerar o init frame (handshake) para FakeTLS
    pub fn generate_init_frame(&self) -> Vec<u8> {
        let mut frame = vec![0u8; 64];
        rand::thread_rng().fill_bytes(&mut frame);
        frame
    }

    /// Calcular o fingerprint da sessão para anti-replay
    pub fn session_fingerprint(data: &[u8]) -> Vec<u8> {
        if data.len() < 8 {
            return vec![];
        }
        let mut hasher = Sha1::new();
        hasher.update(&data[0..8]);
        hasher.finalize().to_vec()
    }
}

/// Gerenciar FakeTLS (TLS fronting)
pub mod faketls {
    use rand::RngCore;
    use std::collections::VecDeque;

    /// Verificar se os primeiros bytes são um ClientHello TLS
    pub fn is_tls_client_hello(data: &[u8]) -> bool {
        if data.len() < 3 {
            return false;
        }
        // ClientHello começa com 0x16 (Handshake)
        // seguido por 0x03 0x01 (TLS 1.0) ou 0x03 0x03 (TLS 1.2/1.3)
        data[0] == 0x16 && data[1] == 0x03
    }

    /// Verificar se os bytes iniciais são uma conexão MTProto com prefixo "ee" (FakeTLS)
    pub fn is_faketls_connection(data: &[u8], _prefix: &[u8]) -> bool {
        if data.len() < 2 {
            return false;
        }
        // FakeTLS usa prefixo "ee" nos primeiros bytes após criptografia
        data[0] == 0xee && data[1] == 0xee
    }

    /// Verificar se os bytes iniciais são uma conexão MTProto direto com prefixo "dd"
    pub fn is_direct_connection(data: &[u8], _prefix: &[u8]) -> bool {
        if data.len() < 2 {
            return false;
        }
        // Direct mode usa prefixo "dd"
        data[0] == 0xdd && data[1] == 0xdd
    }

    /// Extrair SNI do TLS ClientHello
    pub fn extract_sni(data: &[u8]) -> Option<String> {
        if data.len() < 43 || data[0] != 0x16 {
            return None;
        }

        let tls_length = u16::from_be_bytes([data[3], data[4]]) as usize;
        if tls_length + 5 > data.len() {
            return None;
        }

        // Pular header TLS (5 bytes) e Handshake header (4 bytes)
        let mut offset = 5 + 4 + 2; // TLS header + handshake type + length
        if offset + 2 > data.len() {
            return None;
        }

        // Pular client version (2 bytes) + random (32 bytes)
        offset += 2 + 32;
        if offset + 1 > data.len() {
            return None;
        }

        // Session ID length
        let session_id_len = data[offset] as usize;
        offset += 1 + session_id_len;
        if offset + 2 > data.len() {
            return None;
        }

        // Cipher suites length
        let cipher_suites_len = u16::from_be_bytes([data[offset], data[offset + 1]]) as usize;
        offset += 2 + cipher_suites_len;
        if offset + 1 > data.len() {
            return None;
        }

        // Compression methods length
        let compression_len = data[offset] as usize;
        offset += 1 + compression_len;
        if offset + 2 > data.len() {
            return None;
        }

        // Extensions length
        let extensions_len = u16::from_be_bytes([data[offset], data[offset + 1]]) as usize;
        offset += 2;

        let ext_end = offset + extensions_len;
        if ext_end > data.len() {
            return None;
        }

        // Percorrer extensões procurando SNI (tipo 0)
        let mut pos = offset;
        while pos + 4 <= ext_end {
            let ext_type = u16::from_be_bytes([data[pos], data[pos + 1]]);
            let ext_len = u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize;

            if ext_type == 0x00 && pos + 4 + ext_len <= ext_end {
                // SNI extension encontrada
                let sni_data = &data[pos + 4..pos + 4 + ext_len];
                if sni_data.len() >= 5 {
                    let sni_type = sni_data[0]; // 0 = host_name
                    let sni_list_len = u16::from_be_bytes([sni_data[1], sni_data[2]]) as usize;
                    if sni_type == 0 && sni_list_len >= 3 {
                        let host_len = u16::from_be_bytes([sni_data[3], sni_data[4]]) as usize;
                        if 5 + host_len <= sni_data.len() {
                            return String::from_utf8(sni_data[5..5 + host_len].to_vec()).ok();
                        }
                    }
                }
            }
            pos += 4 + ext_len;
        }

        None
    }

    /// Gerar resposta FakeTLS ServerHello (sintética)
    pub fn generate_server_hello() -> Vec<u8> {
        let mut rng = rand::thread_rng();
        let mut server_random = [0u8; 32];
        rng.fill_bytes(&mut server_random);

        // TLS Record Header
        let mut response = Vec::new();
        response.push(0x16); // Handshake
        response.push(0x03); // TLS version 1.0
        response.push(0x03); // (representa TLS 1.2+)

        // ServerHello handshake
        let mut handshake = Vec::new();
        handshake.push(0x02); // Handshake type: ServerHello

        // Handshake length (preencher depois)
        let hs_start = handshake.len();
        handshake.extend_from_slice(&[0, 0, 0]); // placeholder

        // Server version: TLS 1.2
        handshake.push(0x03);
        handshake.push(0x03);

        // Server random
        handshake.extend_from_slice(&server_random);

        // Session ID (32 bytes, aleatório)
        handshake.push(32);
        let mut session_id = [0u8; 32];
        rng.fill_bytes(&mut session_id);
        handshake.extend_from_slice(&session_id);

        // Cipher suite: TLS_AES_256_GCM_SHA384 (0x1302)
        handshake.push(0x13);
        handshake.push(0x02);

        // Compression: null (0x00)
        handshake.push(0x00);

        // Extensions (vazias para simplificar)
        handshake.push(0x00);
        handshake.push(0x00);

        // Preencher handshake length
        let hs_len = (handshake.len() - 4) as u32;
        handshake[hs_start + 1] = ((hs_len >> 16) & 0xFF) as u8;
        handshake[hs_start + 2] = ((hs_len >> 8) & 0xFF) as u8;
        handshake[hs_start + 3] = (hs_len & 0xFF) as u8;

        response.extend_from_slice(&handshake);

        // Preencher TLS record length
        let tls_len = (response.len() - 5) as u16;
        response[3] = ((tls_len >> 8) & 0xFF) as u8;
        response[4] = (tls_len & 0xFF) as u8;

        response
    }

    /// Encapsular dados em um TLS ApplicationData record
    pub fn wrap_in_application_data(data: &[u8]) -> Vec<u8> {
        let mut record = Vec::with_capacity(5 + data.len());
        record.push(0x17); // ApplicationData
        record.push(0x03); // TLS 1.2
        record.push(0x03);
        let len = data.len() as u16;
        record.push((len >> 8) as u8);
        record.push((len & 0xFF) as u8);
        record.extend_from_slice(data);
        record
    }

    /// Desencapsular dados de um TLS ApplicationData record
    pub fn unwrap_application_data(record: &[u8]) -> Option<&[u8]> {
        if record.len() < 5 || record[0] != 0x17 {
            return None;
        }
        let len = u16::from_be_bytes([record[3], record[4]]) as usize;
        if 5 + len > record.len() {
            return None;
        }
        Some(&record[5..5 + len])
    }
}
