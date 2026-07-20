#!/bin/bash
# MTProxy Unified Menu - Versão Corrigida

PROJECT_NAME="MTProxy"
MT_BIN="/usr/local/bin/mtproxy"
PID_FILE="/tmp/mtproxy_"

# Cores
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'

print_header() {
    clear
    echo -e "${BLUE}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         ${PROJECT_NAME} Manager          ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════╝${NC}"
    echo ""
}

show_status() {
    echo -e "${CYAN}📊 Status:${NC}"
    for pidfile in ${PID_FILE}*.pid; do
        if [ -f "$pidfile" ]; then
            PORT=$(basename "$pidfile" .pid | sed 's/mtproxy_//')
            if ps -p $(cat "$pidfile") > /dev/null 2>&1; then
                echo -e "  ${GREEN}✅ Porta $PORT: ativa${NC}"
            else
                rm -f "$pidfile"
            fi
        fi
    done
    echo ""
}

open_port() {
    clear
    echo -e "${BLUE}🔓 ABRIR PORTA${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"
    echo ""
    
    read -p "Digite o número da porta: " PORT
    if [[ -z "$PORT" ]]; then
        echo -e "${RED}❌ Porta inválida!${NC}"
        sleep 2
        return
    fi
    
    sudo fuser -k $PORT/tcp 2>/dev/null
    if [[ -f "${PID_FILE}${PORT}.pid" ]]; then
        rm -f "${PID_FILE}${PORT}.pid"
    fi
    
    echo -e "${YELLOW}🔓 Abrindo porta ${PORT}...${NC}"
    if [ "$PORT" -lt 1024 ]; then
        nohup sudo ${MT_BIN} -p ${PORT} > "/tmp/mtproxy_${PORT}.log" 2>&1 &
    else
        nohup ${MT_BIN} -p ${PORT} > "/tmp/mtproxy_${PORT}.log" 2>&1 &
    fi
    
    echo $! > "${PID_FILE}${PORT}.pid"
    sleep 2
    
    if ps -p $(cat "${PID_FILE}${PORT}.pid") > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Porta ${PORT} aberta!${NC}"
        echo -e "📝 Log: /tmp/mtproxy_${PORT}.log"
    else
        echo -e "${RED}❌ Falha ao abrir porta ${PORT}!${NC}"
        rm -f "${PID_FILE}${PORT}.pid"
    fi
    sleep 2
}

close_port() {
    clear
    echo -e "${BLUE}🔒 FECHAR PORTA${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"
    echo ""
    
    read -p "Digite o número da porta: " PORT
    if [[ -z "$PORT" ]]; then
        echo -e "${RED}❌ Porta inválida!${NC}"
        sleep 2
        return
    fi
    
    if [[ -f "${PID_FILE}${PORT}.pid" ]]; then
        PID=$(cat "${PID_FILE}${PORT}.pid")
        sudo kill -9 $PID 2>/dev/null
        rm -f "${PID_FILE}${PORT}.pid"
        echo -e "${GREEN}✅ Porta ${PORT} fechada!${NC}"
    else
        echo -e "${RED}❌ Porta ${PORT} não está aberta!${NC}"
    fi
    sleep 2
}

show_logs() {
    clear
    echo -e "${BLUE}📝 LOGS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"
    echo ""
    
    ls -la /tmp/mtproxy_*.log 2>/dev/null || echo -e "${YELLOW}Nenhum log encontrado${NC}"
    echo ""
    read -p "Digite a porta para ver o log (Enter para sair): " PORT
    if [ -n "$PORT" ] && [ -f "/tmp/mtproxy_${PORT}.log" ]; then
        echo ""
        echo -e "${CYAN}=== Últimas 30 linhas ===${NC}"
        tail -n 30 "/tmp/mtproxy_${PORT}.log"
        echo ""
    fi
    sleep 2
}

show_menu() {
    print_header
    show_status
    
    echo -e "${CYAN}📋 OPÇÕES:${NC}"
    echo "  [1] • ABRIR PORTA"
    echo "  [2] • FECHAR PORTA"
    echo "  [3] • STATUS"
    echo "  [4] • VER LOGS"
    echo "  [5] • MULTIPROTOCOLO"
    echo "  [6] • MULTISTATUS"
    echo "  [0] • SAIR"
    echo ""
    echo -n "INFORME UMA OPCAO: "
}

show_multiprotocol() {
    clear
    echo -e "${BLUE}📡 MULTIPROTOCOLO${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"
    echo ""
    echo -e "${GREEN}Protocolos Suportados:${NC}"
    echo ""
    echo "  🔐 SOCKS5      - Proxy SOCKS5 (byte 0x05)"
    echo "  🔒 TLS/SSL     - Conexões TLS seguras"
    echo "  🌐 WebSocket   - WebSocket com upgrade"
    echo "  🌍 HTTP        - HTTP/HTTPS requests"
    echo "  🔐 SECURITY    - Protocolo de segurança"
    echo "  📦 TCP         - Fallback TCP"
    echo ""
    read -p "Pressione Enter para continuar..."
}

show_multistatus() {
    clear
    echo -e "${BLUE}📊 MULTISTATUS${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════${NC}"
    echo ""
    
    if pgrep -f "/usr/local/bin/mtproxy" > /dev/null; then
        echo -e "${GREEN}✅ Proxy está ATIVO${NC}"
        echo ""
        echo -e "${GREEN}Portas ativas:${NC}"
        for pidfile in ${PID_FILE}*.pid; do
            if [ -f "$pidfile" ]; then
                PORT=$(basename "$pidfile" .pid | sed 's/mtproxy_//')
                PID=$(cat "$pidfile")
                if ps -p $PID > /dev/null 2>&1; then
                    echo -e "  ${CYAN}✅ Porta $PORT (PID: $PID)${NC}"
                    LOG="/tmp/mtproxy_${PORT}.log"
                    if [ -f "$LOG" ]; then
                        CONNECTIONS=$(grep -c "📩" "$LOG" 2>/dev/null || echo "0")
                        echo -e "     Conexões: $CONNECTIONS"
                    fi
                fi
            fi
        done
    else
        echo -e "${RED}❌ Proxy está INATIVO${NC}"
    fi
    echo ""
    read -p "Pressione Enter para continuar..."
}

while true; do
    show_menu
    read OPTION
    case $OPTION in
        1) open_port ;;
        2) close_port ;;
        3) clear; show_status; read -p "Pressione Enter...";;
        4) show_logs ;;
        5) show_multiprotocol ;;
        6) show_multistatus ;;
        0) echo -e "${GREEN}👋 Saindo...${NC}"; exit 0 ;;
        *) echo -e "${RED}❌ Opção inválida!${NC}"; sleep 2 ;;
    esac
done
