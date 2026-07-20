#!/bin/bash

PROXY_BIN="/opt/mtproxy/proxy"
SERVICE_PREFIX="mtproxy-"
DEFAULT_TARGET="127.0.0.1:22"
DEFAULT_STATUS="@MTProxy"

list_ports() {
    systemctl list-units --type=service --all --no-legend "${SERVICE_PREFIX}*.service" 2>/dev/null \
        | awk '{print $1}' \
        | sed -E "s/^${SERVICE_PREFIX}([0-9]+)\.service$/\1/"
}

show_menu() {
    clear
    local ports
    ports=$(list_ports | tr '\n' ' ')
    [ -z "$ports" ] && ports="Nenhuma"

    echo "========================================"
    echo "            MTProxy Manager"
    echo "========================================"
    echo " Portas abertas: $ports"
    echo "----------------------------------------"
    echo " 1) Abrir Porta"
    echo " 2) Fechar Porta"
    echo " 3) Reiniciar Porta"
    echo " 4) Ver Status"
    echo " 0) Sair"
    echo "========================================"
}

open_port() {
    read -rp "Digite a porta: " port

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Porta inválida!"
        sleep 2
        return
    fi

    local service="${SERVICE_PREFIX}${port}.service"

    if [ -f "/etc/systemd/system/${service}" ]; then
        echo "Essa porta já está aberta."
        sleep 2
        return
    fi

cat > /etc/systemd/system/${service} <<EOF
[Unit]
Description=MTProxy Porta ${port}
After=network.target

[Service]
Type=simple
ExecStart=${PROXY_BIN} --port ${port} --status "${DEFAULT_STATUS}" --target ${DEFAULT_TARGET}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service}" >/dev/null 2>&1
    systemctl start "${service}"

    echo "Porta ${port} aberta!"
    sleep 2
}

close_port() {
    read -rp "Digite a porta: " port

    local service="${SERVICE_PREFIX}${port}.service"

    if [ ! -f "/etc/systemd/system/${service}" ]; then
        echo "Essa porta não está aberta."
        sleep 2
        return
    fi

    systemctl stop "${service}"
    systemctl disable "${service}" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${service}"
    systemctl daemon-reload

    echo "Porta ${port} fechada."
    sleep 2
}

restart_port() {
    read -rp "Digite a porta: " port
    systemctl restart "${SERVICE_PREFIX}${port}.service"
    echo "Porta reiniciada."
    sleep 2
}

status_proxy() {
    systemctl --no-pager --type=service | grep "${SERVICE_PREFIX}"
    read -n1 -r -p "Pressione ENTER para voltar..."
}

while true; do
    show_menu
    read -rp "Escolha uma opção: " opt

    case "$opt" in
        1) open_port ;;
        2) close_port ;;
        3) restart_port ;;
        4) status_proxy ;;
        0) exit 0 ;;
        *) echo "Opção inválida."; sleep 1 ;;
    esac
done
