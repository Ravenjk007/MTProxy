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
    echo -e "\n❌ Erro: $1"
    exit 1
}

increment_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
}

if [ "$EUID" -ne 0 ]; then
    error_exit "EXECUTE COMO ROOT"
else
    clear
    show_progress "Atualizando repositorios..."
    export DEBIAN_FRONTEND=noninteractive
    apt update -y > /dev/null 2>&1 || error_exit "Falha ao atualizar os repositorios"
    increment_step

    show_progress "Verificando o sistema..."
    if ! command -v lsb_release &> /dev/null; then
        apt install lsb-release -y > /dev/null 2>&1 || error_exit "Falha ao instalar lsb-release"
    fi
    increment_step

    OS_NAME=$(lsb_release -is)
    VERSION=$(lsb_release -rs)
    case $OS_NAME in
        Ubuntu)
            case $VERSION in
                24.*|22.*|20.*|18.*)
                    show_progress "Sistema Ubuntu suportado, continuando..."
                    ;;
                *)
                    error_exit "Versão do Ubuntu não suportada. Use 18, 20, 22 ou 24."
                    ;;
            esac
            ;;
        Debian)
            case $VERSION in
                12*|11*|10*|9*)
                    show_progress "Sistema Debian suportado, continuando..."
                    ;;
                *)
                    error_exit "Versão do Debian não suportada. Use 9, 10, 11 ou 12."
                    ;;
            esac
            ;;
        *)
            error_exit "Sistema não suportado. Use Ubuntu ou Debian."
            ;;
    esac
    increment_step

    show_progress "Instalando dependencias do sistema..."
    apt upgrade -y > /dev/null 2>&1 || error_exit "Falha ao atualizar o sistema"
    apt-get install -y curl build-essential git pkg-config libssl-dev > /dev/null 2>&1 || error_exit "Falha ao instalar pacotes"
    increment_step

    show_progress "Criando diretorio /opt/mtproxy..."
    mkdir -p /opt/mtproxy > /dev/null 2>&1
    increment_step

    show_progress "Instalando Rust..."
    if ! command -v rustc &> /dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y > /dev/null 2>&1 || error_exit "Falha ao instalar Rust"
        source "$HOME/.cargo/env"
    fi
    rustup default stable > /dev/null 2>&1
    increment_step

    show_progress "Compilando MTProxy, isso pode levar alguns minutos..."
    if [ -d "/root/MTProxy" ]; then
        rm -rf /root/MTProxy
    fi
    
    git clone --branch "$REPO_BRANCH" "$REPO_URL" /root/MTProxy > /dev/null 2>&1 || error_exit "Falha ao clonar MTProxy"
    
    if [ -f /root/MTProxy/manager.sh ]; then
        mv /root/MTProxy/manager.sh /opt/mtproxy/manager
    fi
    
    cd /root/MTProxy || error_exit "Diretório do MTProxy não encontrado"
    
    echo "   ⏳ Compilando (isso pode levar 2-5 minutos)..."
    cargo build --release > /tmp/mtproxy_build.log 2>&1
    
    if [ $? -ne 0 ]; then
        echo "   ❌ Erro na compilação. Veja o log:"
        tail -30 /tmp/mtproxy_build.log
        error_exit "Falha ao compilar MTProxy"
    fi
    
    if [ -f ./target/release/mtproxy ]; then
        mv ./target/release/mtproxy /opt/mtproxy/proxy || error_exit "Binário compilado não encontrado"
    else
        error_exit "Binário não foi gerado"
    fi
    increment_step

    show_progress "Configurando permissões..."
    chmod +x /opt/mtproxy/proxy
    [ -f /opt/mtproxy/manager ] && chmod +x /opt/mtproxy/manager
    
    if [ -f /opt/mtproxy/manager ]; then
        ln -sf /opt/mtproxy/manager /usr/local/bin/"$CMD_NAME"
    else
        ln -sf /opt/mtproxy/proxy /usr/local/bin/"$CMD_NAME"
    fi
    increment_step

    show_progress "Limpando diretórios temporários..."
    cd /root/
    rm -rf /root/MTProxy/
    rm -f /tmp/mtproxy_build.log
    increment_step

    echo ""
    echo "✅ Instalação concluída com sucesso!"
    echo "📌 Digite '$CMD_NAME' para acessar o menu interativo."
    echo ""
    echo "Exemplo de uso:"
    echo "  $CMD_NAME"
    echo "  $CMD_NAME --port 8080 --status '@MTProxy' --target 127.0.0.1:22"
    echo ""
fi
