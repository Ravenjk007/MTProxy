#!/bin/bash

# MTProxy v2 Menu
# Interface alternativa de gerenciamento

PROXY_BIN="/opt/mtproxy-v2/mtproxy"
SERVICE_PREFIX="mtproxy-"
CONFIG_DIR="/opt/mtproxy-v2/config"

# Ler secret
SECRET=""
if [ -f "$CONFIG_DIR/secret" ]; then
    SECRET=$(cat "$CONFIG_DIR/secret")
fi

# Detectar IP público
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "YOUR_IP")

get_active_ports() {
    systemctl list-units --type=service --all --no-legend "${SERVICE_PREFIX}*.service" 2>/dev/null \
        | awk '{print $1}' \
        | sed -E "s/^${SERVICE_PREFIX}([0-9]+)\.service\$/\1/"
}

get_proxy_status() {
    local ports
    ports=$(get_active_ports | tr '\n' ', ')
    [ -z "$ports" ] && ports="Inativas"
    echo "$ports"
}

main_menu() {
    clear
    local active_ports=$(get_proxy_status)
    
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  🛡️  MTProxy v2.0 - Multi-Protocol VPN       ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║                                              ║"
    echo "║  Status:     $active_ports"
    echo "║  IP:         $PUBLIC_IP"
    echo "║  Secret:     ${SECRET:0:8}...${SECRET: -8}"
    echo "║                                              ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  📡 PROTOCOLOS SUPORTADOS:                   ║"
    echo "║  • MTProto FakeTLS (ee) - Máximo stealth     ║"
    echo "║  • MTProto Direct (dd) - Baixa latência      ║"
    echo "║  • SOCKS5 - Proxy universal                  ║"
    echo "║  • WebSocket - Túnel HTTP/WS                 ║"
    echo "║  • HTTP CONNECT - Proxy HTTPS                ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  Opções:                                     ║"
    echo "║  1  - Gerenciar Portas                       ║"
    echo "║  2  - Configurações                          ║"
    echo "║  3  - Diagnóstico                            ║"
    echo "║  4  - Backup/Restore                         ║"
    echo "║  5  - Atualizar MTProxy                      ║"
    echo "║  0  - Sair                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
}

manage_ports() {
    while true; do
        clear
        local ports=$(get_active_ports)
        [ -z "$ports" ] && ports="nenhuma"
        
        echo "╔══════════════════════════════════════════════╗"
        echo "║  Gerenciamento de Portas                     ║"
        echo "╠══════════════════════════════════════════════╣"
        echo "║  Ativas: $ports"
        echo "╠══════════════════════════════════════════════╣"
        echo "║  1 - Abrir porta FakeTLS (ee)                ║"
        echo "║  2 - Abrir porta Direct (dd)                 ║"
        echo "║  3 - Fechar porta                            ║"
        echo "║  4 - Reiniciar porta                         ║"
        echo "║  5 - Listar todas                            ║"
        echo "║  6 - Gerar links                             ║"
        echo "║  0 - Voltar                                  ║"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
        read -rp "Opção: " opt
        
        case "$opt" in
            1)
                open_faketls_port
                ;;
            2)
                open_direct_port
                ;;
            3)
                close_port
                ;;
            4)
                restart_port
                ;;
            5)
                list_all_ports
                ;;
            6)
                generate_links
                ;;
            0) break ;;
        esac
    done
}

open_faketls_port() {
    read -rp "Porta: " port
    [[ "$port" =~ ^[0-9]+$ ]] || { echo "Porta inválida"; sleep 2; return; }
    
    local service="${SERVICE_PREFIX}${port}.service"
    [ -f "/etc/systemd/system/${service}" ] && { echo "Porta já ativa"; sleep 2; return; }
    
    read -rp "SNI (padrão: www.google.com): " sni
    [ -z "$sni" ] && sni="www.google.com"
    
    [ -z "$SECRET" ] && SECRET=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n') && echo "$SECRET" > "$CONFIG_DIR/secret"
    
    cat > "/etc/systemd/system/${service}" <<EOF
[Unit]
Description=MTProxy v2 - Porta ${port} (FakeTLS)
After=network.target

[Service]
Type=simple
ExecStart=${PROXY_BIN} --port ${port} --secret ${SECRET} --prefix ee --sni ${sni} --status "@MTProxy"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable "${service}" >/dev/null 2>&1 && systemctl start "${service}"
    sleep 2
    
    if systemctl is-active --quiet "${service}"; then
        echo -e "\033[1;32m✅ Porta $port aberta (FakeTLS)\033[0m"
        echo "Link: tg://proxy?server=${PUBLIC_IP}&port=${port}&secret=ee${SECRET}&hostname=${sni}"
    else
        echo -e "\033[1;31m❌ Falha\033[0m"
        journalctl -u "${service}" --no-pager -n 5
        rm -f "/etc/systemd/system/${service}"
        systemctl daemon-reload
    fi
    sleep 3
}

open_direct_port() {
    read -rp "Porta: " port
    [[ "$port" =~ ^[0-9]+$ ]] || { echo "Porta inválida"; sleep 2; return; }
    
    local service="${SERVICE_PREFIX}${port}.service"
    [ -f "/etc/systemd/system/${service}" ] && { echo "Porta já ativa"; sleep 2; return; }
    
    [ -z "$SECRET" ] && SECRET=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n') && echo "$SECRET" > "$CONFIG_DIR/secret"
    
    cat > "/etc/systemd/system/${service}" <<EOF
[Unit]
Description=MTProxy v2 - Porta ${port} (Direct)
After=network.target

[Service]
Type=simple
ExecStart=${PROXY_BIN} --port ${port} --secret ${SECRET} --prefix dd --sni www.google.com --status "@MTProxy"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable "${service}" >/dev/null 2>&1 && systemctl start "${service}"
    sleep 2
    
    if systemctl is-active --quiet "${service}"; then
        echo -e "\033[1;32m✅ Porta $port aberta (Direct)\033[0m"
        echo "Link: tg://proxy?server=${PUBLIC_IP}&port=${port}&secret=dd${SECRET}&hostname=www.google.com"
    else
        echo -e "\033[1;31m❌ Falha\033[0m"
    fi
    sleep 3
}

close_port() {
    local ports=$(get_active_ports)
    [ -z "$ports" ] && { echo "Nenhuma porta ativa"; sleep 2; return; }
    
    echo "Portas: $ports"
    read -rp "Porta para fechar: " port
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ -f "/etc/systemd/system/${service}" ]; then
        systemctl stop "${service}" 2>/dev/null
        systemctl disable "${service}" >/dev/null 2>&1
        rm -f "/etc/systemd/system/${service}"
        systemctl daemon-reload
        echo "✅ Porta $port fechada"
    else
        echo "Porta não encontrada"
    fi
    sleep 2
}

restart_port() {
    local ports=$(get_active_ports)
    [ -z "$ports" ] && { echo "Nenhuma porta ativa"; sleep 2; return; }
    
    echo "Portas: $ports"
    read -rp "Porta para reiniciar: " port
    
    systemctl restart "${SERVICE_PREFIX}${port}.service" 2>/dev/null && echo "✅ Reiniciada" || echo "❌ Falha"
    sleep 2
}

list_all_ports() {
    echo ""
    for port in $(get_active_ports); do
        local service="${SERVICE_PREFIX}${port}.service"
        local status=$(systemctl is-active "${service}" 2>/dev/null)
        local config=$(systemctl show "${service}" --property=ExecStart 2>/dev/null)
        local prefix=$(echo "$config" | grep -oP '(?<=--prefix )\S+' || echo "ee")
        
        echo "  Porta $port - Status: $status - Protocolo: $prefix"
        echo "    Link: tg://proxy?server=${PUBLIC_IP}&port=${port}&secret=${prefix}${SECRET}&hostname=www.google.com"
    done
    echo ""
    read -rp "Pressione Enter para voltar..."
}

generate_links() {
    echo ""
    echo "════════════════════════════════════════════════"
    echo "Links de Proxy:"
    echo "════════════════════════════════════════════════"
    
    for port in $(get_active_ports); do
        local service="${SERVICE_PREFIX}${port}.service"
        local config=$(systemctl show "${service}" --property=ExecStart 2>/dev/null)
        local prefix=$(echo "$config" | grep -oP '(?<=--prefix )\S+' || echo "ee")
        local sni=$(echo "$config" | grep -oP '(?<=--sni )\S+' || echo "www.google.com")
        
        echo ""
        echo "Porta $port ($prefix):"
        echo "  Telegram: tg://proxy?server=${PUBLIC_IP}&port=${port}&secret=${prefix}${SECRET}&hostname=${sni}"
        echo "  HTTPS:    https://t.me/proxy?server=${PUBLIC_IP}&port=${port}&secret=${prefix}${SECRET}&hostname=${sni}"
    done
    echo ""
    read -rp "Pressione Enter para voltar..."
}

settings_menu() {
    while true; do
        clear
        echo "╔══════════════════════════════════════════════╗"
        echo "║  Configurações                               ║"
        echo "╠══════════════════════════════════════════════╣"
        echo "║  1 - Gerar novo secret                       ║"
        echo "║  2 - Ver configuração atual                  ║"
        echo "║  3 - Editar SNI hostname                     ║"
        echo "║  0 - Voltar                                  ║"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
        read -rp "Opção: " opt
        
        case "$opt" in
            1)
                SECRET=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n')
                echo "$SECRET" > "$CONFIG_DIR/secret"
                echo -e "\033[1;32mNovo secret: ${SECRET}\033[0m"
                echo "⚠️  Reinicie as portas para aplicar"
                sleep 3
                ;;
            2)
                echo "Secret: $SECRET"
                echo "IP: $PUBLIC_IP"
                echo "Binário: $PROXY_BIN"
                echo "Config dir: $CONFIG_DIR"
                read -rp "Pressione Enter..." 
                ;;
            0) break ;;
        esac
    done
}

diagnostic_menu() {
    while true; do
        clear
        echo "╔══════════════════════════════════════════════╗"
        echo "║  Diagnóstico                                 ║"
        echo "╠══════════════════════════════════════════════╣"
        echo "║  1 - Testar conectividade DC Telegram        ║"
        echo "║  2 - Ver logs do proxy                       ║"
        echo "║  3 - Status do sistema                       ║"
        echo "║  4 - Teste de porta                          ║"
        echo "║  0 - Voltar                                  ║"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
        read -rp "Opção: " opt
        
        case "$opt" in
            1)
                echo "Testando conectividade com DCs Telegram..."
                for dc in "149.154.175.50" "149.154.167.51" "149.154.175.100"; do
                    if timeout 3 bash -c "echo > /dev/tcp/${dc}/443" 2>/dev/null; then
                        echo -e "  ✅ $dc:443 - OK"
                    else
                        echo -e "  ❌ $dc:443 - Falha"
                    fi
                done
                read -rp "Pressione Enter..."
                ;;
            2)
                local ports=$(get_active_ports)
                [ -z "$ports" ] && { echo "Nenhuma porta ativa"; sleep 2; continue; }
                echo "Portas: $ports"
                read -rp "Porta: " port
                journalctl -u "${SERVICE_PREFIX}${port}.service" --no-pager -n 30
                read -rp "Pressione Enter..."
                ;;
            3)
                echo "Sistema:"
                echo "  OS: $(uname -s -r)"
                echo "  RAM: $(free -h | awk '/Mem:/{print $2}')"
                echo "  CPU: $(nproc) cores"
                echo "  Rust: $(rustc --version 2>/dev/null || echo 'não instalado')"
                echo ""
                echo "Rede:"
                echo "  IP: $PUBLIC_IP"
                echo "  Firewall: $(iptables -L INPUT -n 2>/dev/null | head -5 || echo 'indisponível')"
                read -rp "Pressione Enter..."
                ;;
            4)
                echo "Portas: $(get_active_ports | tr '\n' ' ')"
                read -rp "Porta: " port
                if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
                    echo -e "\033[1;32m✅ Porta $port está escutando\033[0m"
                else
                    echo -e "\033[1;31m❌ Porta $port não está escutando\033[0m"
                fi
                read -rp "Pressione Enter..."
                ;;
            0) break ;;
        esac
    done
}

while true; do
    main_menu
    read -rp "Opção: " opt
    case "$opt" in
        1) manage_ports ;;
        2) settings_menu ;;
        3) diagnostic_menu ;;
        5) 
            echo "Atualização automática não disponível. Use git pull no diretório do projeto."
            sleep 2
            ;;
        0) exit 0 ;;
    esac
done
