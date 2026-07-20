#!/bin/bash

PROXY_BIN="/opt/mtproxy/proxy"
SERVICE_PREFIX="mtproxy-"
DEFAULT_TARGET="127.0.0.1:22"
DEFAULT_STATUS="@MTProxy"

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
    
    echo "=========================================="
    echo "        🔥 MTProxy Manager 🔥            "
    echo "=========================================="
    echo "| Porta(s) ativas: $ports"
    echo "------------------------------------------"
    echo "| 1 - Abrir Porta"
    echo "| 2 - Fechar Porta"
    echo "| 0 - Sair"
    echo "=========================================="
}

open_port() {
    read -rp "Digite a porta: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Porta inválida."
        sleep 2
        return
    fi
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ -f "/etc/systemd/system/${service}" ]; then
        echo "Porta já aberta."
        sleep 2
        return
    fi
    
    cat > "/etc/systemd/system/${service}" <<EOF
[Unit]
Description=MTProxy na porta ${port}
After=network.target

[Service]
Type=simple
ExecStart=${PROXY_BIN} --port ${port} --status "${DEFAULT_STATUS}" --target ${DEFAULT_TARGET}
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
        echo "✅ Porta ${port} aberta!"
    else
        echo "❌ Falha ao iniciar."
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
        echo "Nenhuma porta aberta."
        sleep 2
        return
    fi
    
    echo "Portas: $(echo "$ports" | tr '\n' ' ')"
    read -rp "Digite a porta para fechar: " port
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ ! -f "/etc/systemd/system/${service}" ]; then
        echo "Porta não encontrada."
        sleep 2
        return
    fi
    
    systemctl stop "${service}"
    systemctl disable "${service}" > /dev/null 2>&1
    rm -f "/etc/systemd/system/${service}"
    systemctl daemon-reload
    
    echo "✅ Porta ${port} fechada."
    sleep 2
}

while true; do
    show_menu
    read -rp "--> Opção: " opt
    case "$opt" in
        1) open_port ;;
        2) close_port ;;
        0) exit 0 ;;
        *) echo "Opção inválida."; sleep 1 ;;
    esac
done
