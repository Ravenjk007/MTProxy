#!/bin/bash

# MTProxy v2 Installer
# Proxy multi-protocolo (MTProto, FakeTLS, SOCKS5, WebSocket)

set -e

TOTAL_STEPS=10
CURRENT_STEP=0

show_progress() {
    PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    echo -e "\033[1;36m[${PERCENT}%]\033[0m $1"
}

error_exit() {
    echo -e "\n\033[1;31mERRO: $1\033[0m"
    exit 1
}

increment_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

if [ "$EUID" -ne 0 ]; then
    error_exit "Execute como root (sudo ./install.sh)"
fi

clear
echo "╔══════════════════════════════════════════════╗"
echo "║       MTProxy v2.0 - Installer               ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

show_progress "Atualizando repositórios..."
export DEBIAN_FRONTEND=noninteractive
apt update -y || error_exit "Falha ao atualizar repositórios"
increment_step

show_progress "Verificando sistema..."
if ! command -v lsb_release >/dev/null 2>&1; then
    apt install -y lsb-release || error_exit "Falha ao instalar lsb-release"
fi
increment_step

show_progress "Instalando dependências..."
apt upgrade -y
apt install -y curl build-essential git pkg-config libssl-dev pkg-config
increment_step

show_progress "Criando diretório de instalação..."
mkdir -p /opt/mtproxy-v2
mkdir -p /opt/mtproxy-v2/config
increment_step

show_progress "Instalando Rust..."
if ! command -v rustc >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# Garantir que Rust está no PATH
if [ -f "$HOME/.cargo/env" ]; then
    source "$HOME/.cargo/env"
fi

# Verificar versão do Rust
RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
echo "  Rust versão: $RUST_VERSION"
increment_step

show_progress "Compilando MTProxy v2..."
cd "$(dirname "$0")" || error_exit "Diretório não encontrado"

echo "  Compilando com otimizações (pode levar alguns minutos)..."
cargo build --release || error_exit "Falha ao compilar"

cp target/release/mtproxy /opt/mtproxy-v2/mtproxy || error_exit "Binário não encontrado"
increment_step

show_progress "Copiando scripts de gerenciamento..."
[ -f manager.sh ] && cp manager.sh /opt/mtproxy-v2/manager.sh
[ -f menu.sh ] && cp menu.sh /opt/mtproxy-v2/menu.sh
increment_step

show_progress "Configurando permissões..."
chmod +x /opt/mtproxy-v2/mtproxy
[ -f /opt/mtproxy-v2/manager.sh ] && chmod +x /opt/mtproxy-v2/manager.sh
[ -f /opt/mtproxy-v2/menu.sh ] && chmod +x /opt/mtproxy-v2/menu.sh

if [ -f /opt/mtproxy-v2/manager.sh ]; then
    ln -sf /opt/mtproxy-v2/manager.sh /usr/local/bin/mtproxy
elif [ -f /opt/mtproxy-v2/menu.sh ]; then
    ln -sf /opt/mtproxy-v2/menu.sh /usr/local/bin/mtproxy
else
    ln -sf /opt/mtproxy-v2/mtproxy /usr/local/bin/mtproxy
fi
increment_step

show_progress "Gerando secret aleatório..."
SECRET=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n')
echo "  Secret gerado: $SECRET"
echo "$SECRET" > /opt/mtproxy-v2/config/secret
increment_step

show_progress "Limpando arquivos temporários..."
cd /root
rm -rf /root/MTProxy-v2-build 2>/dev/null || true
increment_step

echo ""
echo -e "\033[1;32m╔══════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;32m║     ✅ MTProxy v2 instalado com sucesso!      ║\033[0m"
echo -e "\033[1;32m╠══════════════════════════════════════════════╣\033[0m"
echo -e "\033[1;32m║  Localização: /opt/mtproxy-v2/mtproxy        ║\033[0m"
echo -e "\033[1;32m║  Comando: mtproxy                            ║\033[0m"
echo -e "\033[1;32m║  Secret: $SECRET                             ║\033[0m"
echo -e "\033[1;32m╚══════════════════════════════════════════════╝\033[0m"
echo ""
echo "Exemplo de uso:"
echo "  mtproxy --port 443 --secret $SECRET --prefix ee --sni www.google.com"
echo ""
echo "Para gerar um novo secret:"
echo "  head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n'"
echo ""
