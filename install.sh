#!/bin/bash
# MTProxy Installer
# ---->>>> Configure aqui o seu repositório
REPO_URL="https://github.com/Ravenjk007/BSProxy.git"
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
else
    clear
    show_progress "Atualizando repositorios..."
    export DEBIAN_FRONTEND=noninteractive
    apt update -y > /dev/null 2>&1 || error_exit "Falha ao atualizar os repositorios"
    increment_step

    # ---->>>> Verificação do sistema
    show_progress "Verificando o sistema..."
    if ! command -v lsb_release &> /dev/null; then
        apt install lsb-release -y > /dev/null 2>&1 || error_exit "Falha ao instalar lsb-release"
    fi
    increment_step

    # ---->>>> Verificação do sistema
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

    # ---->>>> Instalação de pacotes requisitos e atualização do sistema
    show_progress "Atualizando o sistema..."
    apt upgrade -y > /dev/null 2>&1 || error_exit "Falha ao atualizar o sistema"
    apt-get install curl build-essential git -y > /dev/null 2>&1 || error_exit "Falha ao instalar pacotes"
    increment_step

    # ---->>>> Criando o diretório do script
    show_progress "Criando diretorio /opt/mtproxy..."
    mkdir -p /opt/mtproxy > /dev/null 2>&1
    increment_step

    # ---->>>> Instalar rust
    show_progress "Instalando Rust..."
    if ! command -v rustc &> /dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y > /dev/null 2>&1 || error_exit "Falha ao instalar Rust"
        source "$HOME/.cargo/env"
    fi
    increment_step

    # ---->>>> Instalar o MTProxy
    show_progress "Compilando MTProxy, isso pode levar algum tempo dependendo da maquina..."
    if [ -d "/root/BSProxy" ]; then
        rm -rf /root/BSProxy
    fi
    git clone --branch "$REPO_BRANCH" "$REPO_URL" /root/BSProxy > /dev/null 2>&1 || error_exit "Falha ao clonar MTProxy"
    if [ -f /root/BSProxy/menu.sh ]; then
        mv /root/BSProxy/menu.sh /opt/mtproxy/menu
    fi
    cd /root/BSProxy || error_exit "Diretório do MTProxy não encontrado"
    cargo build --release --jobs "$(nproc)" > /dev/null 2>&1 || error_exit "Falha ao compilar MTProxy"
    mv ./target/release/BSProxy /opt/mtproxy/proxy || error_exit "Binário compilado não encontrado"
    increment_step

    # ---->>>> Configuração de permissões
    show_progress "Configurando permissões..."
    chmod +x /opt/mtproxy/proxy
    [ -f /opt/mtproxy/menu ] && chmod +x /opt/mtproxy/menu
    if [ -f /opt/mtproxy/menu ]; then
        ln -sf /opt/mtproxy/menu /usr/local/bin/"$CMD_NAME"
    else
        ln -sf /opt/mtproxy/proxy /usr/local/bin/"$CMD_NAME"
    fi
    increment_step

    # ---->>>> Limpeza
    show_progress "Limpando diretórios temporários..."
    cd /root/
    rm -rf /root/BSProxy/
    increment_step

    # ---->>>> Instalação finalizada :)
    echo "Instalação concluída com sucesso. Digite '$CMD_NAME' para acessar o menu."
fi
