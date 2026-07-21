#!/bin/bash

# MTProxy v2 Manager
# Gerenciador de serviços multi-porta

PROXY_BIN="/opt/mtproxy-v2/mtproxy"
SERVICE_PREFIX="mtproxy-"
DEFAULT_TARGET="149.154.175.50:443"
DEFAULT_STATUS="@MTProxy"
CONFIG_DIR="/opt/mtproxy-v2/config"

# Ler secret salvo
SECRET=""
if [ -f "$CONFIG_DIR/secret" ]; then
    SECRET=$(cat "$CONFIG_DIR/secret")
fi

# Detectar IP público
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "YOUR_IP")

list_ports() {
    systemctl list-units --type=service --all --no-legend "${SERVICE_PREFIX}*.service" 2>/dev/null \
        | awk '{print $1}' \
        | sed -E "s/^${SERVICE_PREFIX}([0-9]+)\.service\$/\1/"
}

show_menu() {
    clear
    local ports
    ports=$(list_ports | tr '\n' ' ')
    [ -z "$ports" ] && ports="nenhuma"

    local CYAN="\033[1;36m"
    local RED="\033[1;31m"
    local YELLOW="\033[1;33m"
    local NC="\033[0m"

    echo -e "${CYAN}┌──────────────────────────────┐${NC}"
    echo -e "${CYAN}│      MTProxy Proxy Menu       │${NC}"
    echo -e "${CYAN}└──────────────────────────────┘${NC}"
    echo -e "${YELLOW}Em uso: $ports${NC}"
    echo -e "${YELLOW}IP Público: $PUBLIC_IP${NC}"
    echo -e "${YELLOW}Secret: ${SECRET:0:16}...${NC}"
    echo -e "${CYAN}┌──────────────────────────────┐${NC}"
    echo -e "${CYAN}[01]${NC} • ${RED}ABRIR PORTA (FakeTLS)${NC}"
    echo -e "${CYAN}[02]${NC} • ${RED}ABRIR PORTA (Direct)${NC}"
    echo -e "${CYAN}[03]${NC} • ${RED}FECHAR PORTA${NC}"
    echo -e "${CYAN}[04]${NC} • ${RED}REINICIAR PORTA${NC}"
    echo -e "${CYAN}[05]${NC} • ${RED}GERAR SECRET${NC}"
    echo -e "${CYAN}[06]${NC} • ${RED}VER LOG DA PORTA${NC}"
    echo -e "${CYAN}[07]${NC} • ${RED}GERAR LINK PROXY${NC}"
    echo -e "${CYAN}[00]${NC} • ${RED}SAIR${NC}"
    echo -e "${CYAN}└──────────────────────────────┘${NC}"
}

open_port() {
    local prefix="$1"
    local prefix_name="$2"
    
    read -rp "Digite a porta: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "\033[1;31mPorta inválida.\033[0m"
        sleep 2
        return
    fi
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ -f "/etc/systemd/system/${service}" ]; then
        echo -e "\033[1;33mPorta já aberta.\033[0m"
        sleep 2
        return
    fi
    
    # Perguntar SNI
    read -rp "SNI hostname (padrão: www.google.com): " sni
    [ -z "$sni" ] && sni="www.google.com"
    
    # Perguntar fallback
    read -rp "Fallback host (padrão: www.google.com, vazio=desativar): " fallback
    [ -z "$fallback" ] && fallback="www.google.com"
    
    local fallback_opt=""
    if [ -n "$fallback" ] && [ "$fallback" != "none" ]; then
        fallback_opt="--fallback $fallback"
    fi
    
    # Gerar secret se não existir
    if [ -z "$SECRET" ]; then
        SECRET=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n')
        echo "$SECRET" > "$CONFIG_DIR/secret"
    fi
    
    cat > "/etc/systemd/system/${service}" <<EOF
[Unit]
Description=MTProxy v2 - Porta ${port} (${prefix_name})
After=network.target

[Service]
Type=simple
ExecStart=${PROXY_BIN} --port ${port} --secret ${SECRET} --prefix ${prefix} --sni ${sni} --status "${DEFAULT_STATUS}" --fallback ${fallback}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service}" > /dev/null 2>&1
    systemctl start "${service}"
    sleep 2
    
    if systemctl is-active --quiet "${service}"; then
        echo -e "\033[1;32m✅ Porta ${port} aberta! (${prefix_name})\033[0m"
        echo ""
        echo "Link Telegram:"
        echo "  tg://proxy?server=${PUBLIC_IP}&port=${port}&secret=${prefix}${SECRET}&hostname=${sni}"
        echo ""
        echo "Link HTTPS:"
        echo "  https://t.me/proxy?server=${PUBLIC_IP}&port=${port}&secret=${prefix}${SECRET}&hostname=${sni}"
    else
        echo -e "\033[1;31m❌ Falha ao iniciar.\033[0m"
        journalctl -u "${service}" --no-pager -n 10
        rm -f "/etc/systemd/system/${service}"
        systemctl daemon-reload
    fi
    sleep 3
}

close_port() {
    local ports
    ports=$(list_ports)
    if [ -z "$ports" ]; then
        echo -e "\033[1;33mNenhuma porta aberta.\033[0m"
        sleep 2
        return
    fi
    
    echo -e "\033[1;36mPortas ativas: $(echo "$ports" | tr '\n' ' ')\033[0m"
    read -rp "Digite a porta para fechar: " port
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ ! -f "/etc/systemd/system/${service}" ]; then
        echo -e "\033[1;31mPorta não encontrada.\033[0m"
        sleep 2
        return
    fi
    
    systemctl stop "${service}"
    systemctl disable "${service}" > /dev/null 2>&1
    rm -f "/etc/systemd/system/${service}"
    systemctl daemon-reload
    
    echo -e "\033[1;32m✅ Porta ${port} fechada.\033[0m"
    sleep 2
}

restart_port() {
    local ports
    ports=$(list_ports)
    if [ -z "$ports" ]; then
        echo -e "\033[1;33mNenhuma porta aberta.\033[0m"
        sleep 2
        return
    fi
    
    echo -e "\033[1;36mPortas ativas: $(echo "$ports" | tr '\n' ' ')\033[0m"
    read -rp "Digite a porta para reiniciar: " port
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ ! -f "/etc/systemd/system/${service}" ]; then
        echo -e "\033[1;31mPorta não encontrada.\033[0m"
        sleep 2
        return
    fi
    
    systemctl restart "${service}"
    sleep 2
    
    if systemctl is-active --quiet "${service}"; then
        echo -e "\033[1;32m✅ Porta ${port} reiniciada.\033[0m"
    else
        echo -e "\033[1;31m❌ Falha ao reiniciar.\033[0m"
        journalctl -u "${service}" --no-pager -n 10
    fi
    sleep 2
}

generate_secret() {
    echo -e "\033[1;36mGerando novo secret...\033[0m"
    SECRET=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n')
    echo "$SECRET" > "$CONFIG_DIR/secret"
    echo -e "\033[1;32mNovo secret: ${SECRET}\033[0m"
    echo ""
    echo "⚠️  Atenção: portas abertas continuarão usando o secret antigo."
    echo "   Reinicie as portas para usar o novo secret."
    sleep 3
}

generate_link() {
    local ports
    ports=$(list_ports)
    if [ -z "$ports" ]; then
        echo -e "\033[1;33mNenhuma porta aberta.\033[0m"
        sleep 2
        return
    fi
    
    echo -e "\033[1;36mLinks dos proxies ativos:\033[0m"
    echo ""
    
    for port in $ports; do
        local service="${SERVICE_PREFIX}${port}.service"
        local config_line=$(systemctl show "${service}" --property=ExecStart 2>/dev/null)
        
        # Extrair prefixo da configuração
        local prefix="ee"
        if echo "$config_line" | grep -q "\-\-prefix dd"; then
            prefix="dd"
        fi
        
        # Extrair SNI
        local sni="www.google.com"
        local sni_match=$(echo "$config_line" | grep -oP '(?<=--sni )\S+')
        [ -n "$sni_match" ] && sni="$sni_match"
        
        local secret="${SECRET}"
        
        echo "  Porta $port ($prefix prefixo):"
        echo "    Telegram: tg://proxy?server=${PUBLIC_IP}&port=${port}&secret=${prefix}${secret}&hostname=${sni}"
        echo "    HTTPS: https://t.me/proxy?server=${PUBLIC_IP}&port=${port}&secret=${prefix}${secret}&hostname=${sni}"
        echo ""
    done
    sleep 5
}

view_log() {
    local ports
    ports=$(list_ports)
    if [ -z "$ports" ]; then
        echo -e "\033[1;33mNenhuma porta aberta.\033[0m"
        sleep 2
        return
    fi
    
    echo -e "\033[1;36mPortas ativas: $(echo "$ports" | tr '\n' ' ')\033[0m"
    read -rp "Digite a porta para ver log: " port
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ ! -f "/etc/systemd/system/${service}" ]; then
        echo -e "\033[1;31mPorta não encontrada.\033[0m"
        sleep 2
        return
    fi
    
    journalctl -u "${service}" --no-pager -n 50
    sleep 3
}

while true; do
    show_menu
    read -rp $'\xf0\x9f\x91\x89 Digite sua opção: ' opt
    case "$opt" in
        1|01) open_port "ee" "FakeTLS" ;;
        2|02) open_port "dd" "Direct" ;;
        3|03) close_port ;;
        4|04) restart_port ;;
        5|05) generate_secret ;;
        6|06) view_log ;;
        7|07) generate_link ;;
        0|00) exit 0 ;;
        *) echo -e "\033[1;31mOpção inválida.\033[0m"; sleep 1 ;;
    esac
done
