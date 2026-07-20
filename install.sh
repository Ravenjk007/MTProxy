#!/bin/bash
# MTProxy Installer
REPO_URL="https://github.com/Ravenjk007/MTProxy.git"
REPO_BRANCH="main"
CMD_NAME="mtproxy"
MENU_NAME="mt"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

error_exit() {
    echo -e "\n${RED}❌ Erro: $1${NC}"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    error_exit "EXECUTE COMO ROOT"
fi

clear
echo -e "${BLUE}╔═══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         MTProxy Installer               ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════╝${NC}"
echo ""

echo "👉 Atualizando sistema..."
apt update -y > /dev/null 2>&1 || error_exit "Falha ao atualizar"
apt install -y curl build-essential git > /dev/null 2>&1 || error_exit "Falha ao instalar pacotes"

echo "👉 Instalando Rust..."
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y > /dev/null 2>&1 || error_exit "Falha ao instalar Rust"
    source "$HOME/.cargo/env"
fi

echo "👉 Criando diretório..."
mkdir -p /opt/mtproxy

echo "👉 Clonando repositório..."
cd /root
rm -rf MTProxy
git clone --branch "$REPO_BRANCH" "$REPO_URL" /root/MTProxy > /dev/null 2>&1 || error_exit "Falha ao clonar"

cd /root/MTProxy || error_exit "Diretório não encontrado"

echo "👉 Compilando MTProxy..."
cargo build --release > /tmp/mtproxy_build.log 2>&1

if [ $? -ne 0 ]; then
    echo "${RED}❌ Falha na compilação:${NC}"
    tail -n 20 /tmp/mtproxy_build.log
    exit 1
fi

echo "👉 Instalando binário..."
cp target/release/mtproxy /opt/mtproxy/proxy
chmod +x /opt/mtproxy/proxy
cp /opt/mtproxy/proxy /usr/local/bin/mtproxy
chmod +x /usr/local/bin/mtproxy

echo "👉 Instalando menu..."
if [ -f /root/MTProxy/mt.sh ]; then
    cp /root/MTProxy/mt.sh /usr/local/bin/mt
    chmod +x /usr/local/bin/mt
else
    error_exit "mt.sh não encontrado"
fi

echo "👉 Limpando..."
cd /root
rm -rf /root/MTProxy

echo ""
echo -e "${GREEN}✅ Instalação concluída!${NC}"
echo ""
echo "🚀 Comandos:"
echo "   mt          - Menu interativo"
echo "   mtproxy -p 80 - Iniciar na porta 80"
echo ""
echo "📡 Protocolos: SOCKS5 | TLS | WebSocket | SECURITY | TCP"
echo "💓 Keep-Alive ativo para VPN/HTTP Inject"
