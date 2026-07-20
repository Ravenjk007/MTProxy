#!/bin/bash

REPO_URL="https://github.com/Ravenjk007/MTProxy.git"
REPO_BRANCH="main"
CMD_NAME="mtproxy"

if [ "$EUID" -ne 0 ]; then
    echo "Execute como root"
    exit 1
fi

echo "📦 Instalando MTProxy..."

apt update -y
apt install -y curl build-essential git pkg-config libssl-dev

mkdir -p /opt/mtproxy

if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

rm -rf /root/MTProxy
git clone --branch "$REPO_BRANCH" "$REPO_URL" /root/MTProxy

cd /root/MTProxy
cargo build --release

cp ./target/release/mtproxy /opt/mtproxy/proxy
chmod +x /opt/mtproxy/proxy

ln -sf /opt/mtproxy/proxy /usr/local/bin/"$CMD_NAME"

rm -rf /root/MTProxy

echo "✅ Instalação concluída!"
echo "📌 Digite '$CMD_NAME' para acessar o menu"
