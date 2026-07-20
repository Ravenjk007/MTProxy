#!/bin/bash

# MTProxy Installer

REPO_URL="https://github.com/Ravenjk007/MTProxy.git"
REPO_BRANCH="main"
CMD_NAME="mtproxy"

TOTAL_STEPS=9
CURRENT_STEP=0

show_progress() {
    PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    echo "Progresso: [${PERCENT}%] - $1"
}

error_exit() {
    echo -e "\nErro: $1"
    exit 1
}

increment_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

if [ "$EUID" -ne 0 ]; then
    error_exit "EXECUTE COMO ROOT"
fi

clear

show_progress "Atualizando repositórios..."
export DEBIAN_FRONTEND=noninteractive
apt update -y || error_exit "Falha ao atualizar repositórios"
increment_step

show_progress "Verificando sistema..."
if ! command -v lsb_release >/dev/null 2>&1; then
    apt install -y lsb-release || error_exit "Falha ao instalar lsb-release"
fi
increment_step

show_progress "Atualizando sistema..."
apt upgrade -y
apt install -y curl build-essential git pkg-config libssl-dev
increment_step

show_progress "Criando diretório..."
mkdir -p /opt/mtproxy
increment_step

show_progress "Instalando Rust..."
if ! command -v rustc >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi
increment_step

show_progress "Baixando MTProxy..."

rm -rf /root/MTProxy
git clone --branch "$REPO_BRANCH" "$REPO_URL" /root/MTProxy || error_exit "Falha ao clonar repositório"

cd /root/MTProxy || error_exit "Diretório não encontrado"

cargo build --release || error_exit "Falha ao compilar"

cp target/release/mtproxy /opt/mtproxy/proxy || error_exit "Binário não encontrado"

[ -f manager.sh ] && cp manager.sh /opt/mtproxy/manager.sh
[ -f menu.sh ] && cp menu.sh /opt/mtproxy/menu.sh

increment_step

show_progress "Configurando permissões..."

chmod +x /opt/mtproxy/proxy

[ -f /opt/mtproxy/manager.sh ] && chmod +x /opt/mtproxy/manager.sh
[ -f /opt/mtproxy/menu.sh ] && chmod +x /opt/mtproxy/menu.sh

if [ -f /opt/mtproxy/manager.sh ]; then
    ln -sf /opt/mtproxy/manager.sh /usr/local/bin/mtproxy
elif [ -f /opt/mtproxy/menu.sh ]; then
    ln -sf /opt/mtproxy/menu.sh /usr/local/bin/mtproxy
else
    ln -sf /opt/mtproxy/proxy /usr/local/bin/mtproxy
fi

increment_step

show_progress "Limpando arquivos..."

cd /root
rm -rf /root/MTProxy

increment_step

echo
echo "✅ Instalação concluída!"
echo "Digite: mtproxy"
echo
