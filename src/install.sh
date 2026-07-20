#!/bin/bash
# MTProxy Installer
REPO="Ravenjk007/MTProxy"
PROJECT_NAME="MTProxy"
INSTALL_URL="https://raw.githubusercontent.com/Ravenjk007/MTProxy/main/install.sh"
MENU_URL="https://raw.githubusercontent.com/Ravenjk007/MTProxy/main/mt.sh"
BINARY_NAME="mtproxy"
MENU_NAME="mt"
INSTALL_DIR="/usr/local/bin"

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}👉 $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}" >&2; }

if [ "$EUID" -ne 0 ]; then
    log_error "EXECUTE COMO ROOT"
    exit 1
fi

clear
echo -e "${BLUE}╔═══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         MTProxy Installer               ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════╝${NC}"
echo ""

log_info "Atualizando sistema..."
apt update -y > /dev/null 2>&1
apt install -y curl build-essential git > /dev/null 2>&1

log_info "Instalando Rust..."
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y > /dev/null 2>&1
    source "$HOME/.cargo/env"
fi

log_info "Criando diretório /opt/mtproxy..."
mkdir -p /opt/mtproxy

log_info "Clonando repositório..."
cd /root
rm -rf MTProxy
git clone https://github.com/Ravenjk007/MTProxy.git > /dev/null 2>&1 || {
    log_error "Falha ao clonar"
    exit 1
}

cd MTProxy

log_info "Compilando MTProxy..."
cargo build --release > /tmp/mtproxy_build.log 2>&1

if [ $? -ne 0 ]; then
    log_error "Falha na compilação"
    tail -n 20 /tmp/mtproxy_build.log
    exit 1
fi

log_info "Instalando binário..."
cp target/release/mtproxy /opt/mtproxy/proxy
chmod +x /opt/mtproxy/proxy
cp /opt/mtproxy/proxy /usr/local/bin/mtproxy
chmod +x /usr/local/bin/mtproxy

log_info "Baixando menu (mt.sh)..."
curl -fsSL "$MENU_URL" -o /opt/mtproxy/mt.sh
chmod +x /opt/mtproxy/mt.sh
cp /opt/mtproxy/mt.sh /usr/local/bin/mt
chmod +x /usr/local/bin/mt

log_info "Limpando..."
cd /root
rm -rf MTProxy

echo ""
echo -e "${GREEN}✅ Instalação concluída!${NC}"
echo ""
echo "🚀 Comandos:"
echo "   mt          - Menu interativo"
echo "   mtproxy -p 80 - Iniciar na porta 80"
echo ""
echo "📡 Protocolos: SOCKS5 | TLS | WebSocket | SECURITY | TCP"
echo "💓 Keep-Alive ativo para VPN/HTTP Inject"
