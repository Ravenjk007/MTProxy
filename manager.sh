#!/bin/bash

# MTProxy Manager - menu interativo de portas
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
    echo "| 3 - Status dos serviços"
    echo "| 4 - Ver logs de um serviço"
    echo "| 5 - Testar conexão"
    echo "| 0 - Sair"
    echo "=========================================="
}

open_port() {
    read -rp "Digite a porta que deseja abrir: " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "❌ Porta inválida."
        sleep 2
        return
    fi
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ -f "/etc/systemd/system/${service}" ]; then
        echo "⚠️  Essa porta já está aberta pelo MTProxy."
        sleep 2
        return
    fi
    
    echo "📡 Criando serviço para porta ${port}..."
    
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
        echo "✅ Porta ${port} aberta com sucesso!"
        echo ""
        echo "📌 Teste rápido:"
        echo "   curl --socks5 localhost:${port} http://api.ipify.org"
        echo ""
        echo "📌 Para ver os logs:"
        echo "   journalctl -u ${service} -f"
    else
        echo "❌ Falha ao iniciar. Veja os logs:"
        echo "   journalctl -u ${service} --no-pager -n 20"
        rm -f "/etc/systemd/system/${service}"
        systemctl daemon-reload
    fi
    sleep 3
}

close_port() {
    local ports
    ports=$(list_ports)
    if [ -z "$ports" ]; then
        echo "ℹ️  Nenhuma porta aberta no momento."
        sleep 2
        return
    fi
    
    echo "📋 Portas abertas: $(echo "$ports" | tr '\n' ' ')"
    read -rp "Digite a porta que deseja fechar: " port
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ ! -f "/etc/systemd/system/${service}" ]; then
        echo "❌ Essa porta não está aberta pelo MTProxy."
        sleep 2
        return
    fi
    
    systemctl stop "${service}"
    systemctl disable "${service}" > /dev/null 2>&1
    rm -f "/etc/systemd/system/${service}"
    systemctl daemon-reload
    
    echo "✅ Porta ${port} fechada com sucesso."
    sleep 2
}

show_status() {
    clear
    echo "=========================================="
    echo "        📊 Status dos Serviços           "
    echo "=========================================="
    
    local ports
    ports=$(list_ports)
    if [ -z "$ports" ]; then
        echo "ℹ️  Nenhum serviço MTProxy em execução."
    else
        for port in $ports; do
            local service="${SERVICE_PREFIX}${port}.service"
            local status=$(systemctl is-active "${service}" 2>/dev/null || echo "inactive")
            local enabled=$(systemctl is-enabled "${service}" 2>/dev/null || echo "disabled")
            
            if [ "$status" = "active" ]; then
                echo "✅ Porta ${port}: ATIVO (${enabled})"
            else
                echo "❌ Porta ${port}: INATIVO (${enabled})"
            fi
        done
    fi
    echo ""
    echo "=========================================="
    echo "Pressione Enter para voltar ao menu..."
    read -r
}

show_logs() {
    local ports
    ports=$(list_ports)
    if [ -z "$ports" ]; then
        echo "ℹ️  Nenhuma porta aberta no momento."
        sleep 2
        return
    fi
    
    echo "📋 Portas abertas: $(echo "$ports" | tr '\n' ' ')"
    read -rp "Digite a porta para ver os logs: " port
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ ! -f "/etc/systemd/system/${service}" ]; then
        echo "❌ Essa porta não está aberta pelo MTProxy."
        sleep 2
        return
    fi
    
    clear
    echo "=========================================="
    echo "        📜 Logs da porta ${port}          "
    echo "=========================================="
    echo "Pressione Ctrl+C para sair dos logs"
    echo ""
    journalctl -u "${service}" -f
}

test_connection() {
    local ports
    ports=$(list_ports)
    if [ -z "$ports" ]; then
        echo "ℹ️  Nenhuma porta aberta para testar."
        sleep 2
        return
    fi
    
    echo "📋 Portas abertas: $(echo "$ports" | tr '\n' ' ')"
    read -rp "Digite a porta para testar: " port
    
    local service="${SERVICE_PREFIX}${port}.service"
    if [ ! -f "/etc/systemd/system/${service}" ]; then
        echo "❌ Essa porta não está aberta pelo MTProxy."
        sleep 2
        return
    fi
    
    if ! systemctl is-active --quiet "${service}"; then
        echo "❌ O serviço da porta ${port} não está ativo."
        sleep 2
        return
    fi
    
    echo "📡 Testando conexão na porta ${port}..."
    echo ""
    
    echo "🔍 Verificando se a porta está ouvindo..."
    if netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        echo "✅ Porta ${port} está ouvindo"
    else
        echo "❌ Porta ${port} NÃO está ouvindo"
    fi
    
    echo ""
    
    echo "🔍 Testando conexão SOCKS5..."
    if command -v curl &> /dev/null; then
        local result
        result=$(curl --socks5 "localhost:${port}" --connect-timeout 5 http://api.ipify.org 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$result" ]; then
            echo "✅ Conexão SOCKS5 funcionando! IP: $result"
        else
            echo "❌ Falha na conexão SOCKS5"
        fi
    else
        echo "⚠️  curl não está instalado."
    fi
    
    echo ""
    echo "=========================================="
    echo "Pressione Enter para voltar ao menu..."
    read -r
}

while true; do
    show_menu
    read -rp "--> Selecione uma opção: " opt
    case "$opt" in
        1) open_port ;;
        2) close_port ;;
        3) show_status ;;
        4) show_logs ;;
        5) test_connection ;;
        0) echo "Saindo..."; exit 0 ;;
        *) echo "❌ Opção inválida."; sleep 1 ;;
    esac
done
