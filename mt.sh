#!/bin/bash
# MTProxy Unified Menu

PROJECT_NAME="MTProxy"
MENU_BOX_WIDTH=62

MT_BIN="/usr/local/bin/mtproxy"
PID_FILE="/tmp/mtproxy_"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
BG_BLUE='\033[44m'
BG_GREEN='\033[42m'
BG_RED='\033[41m'
RESET='\033[0m'
BOLD='\033[1m'

strip_ansi() {
    printf '%s' "$1" | sed -u 's/\x1b\[[0-9;]*m//g'
}

print_box_open() {
    echo -e "${BLUE}╔$(printf '═%.0s' {1..62})╗${RESET}"
}

print_box_divider() {
    echo -e "${BLUE}╠$(printf '═%.0s' {1..62})╣${RESET}"
}

print_box_close() {
    echo -e "${BLUE}╚$(printf '═%.0s' {1..62})╝${RESET}"
}

print_box_line() {
    local content="$1"
    local inner_width="${2:-$MENU_BOX_WIDTH}"
    local pad=$((inner_width - $(strip_ansi "$content" | wc -c)))
    ((pad < 0)) && pad=0
    printf '%b' "${BLUE}║${RESET}${content}"
    printf '%*s' "$pad" ""
    printf '%b\n' "${BLUE}║${RESET}"
}

print_box_heading() {
    local text="$1"
    local color="${2:-$WHITE}"
    local len=${#text}
    local left=$(( (MENU_BOX_WIDTH - len) / 2 ))
    local right=$((MENU_BOX_WIDTH - len - left))
    print_box_line "${color}$(printf '%*s%s%*s' "$left" "" "$text" "$right")${RESET}"
}

render_menu_option() {
    local item="$1"
    local emphasis="${2:-normal}"
    local num="${item%% *}"
    local label="${item#* • }"
    local content

    if [[ "$emphasis" == "red" ]]; then
        content="${RED}  [${num}] ${label}${RESET}"
    else
        content="${WHITE}  [${CYAN}${num}${WHITE}] ${BLUE}${label}${RESET}"
    fi
    print_box_line "$content"
}

print_header() {
    clear
    print_box_open
    local title="${PROJECT_NAME} Manager"
    local title_len=${#title}
    local title_left=$(( (MENU_BOX_WIDTH - title_len) / 2 ))
    local title_right=$((MENU_BOX_WIDTH - title_len - title_left))
    print_box_line "${BG_BLUE}${WHITE}$(printf '%*s%s%*s' "$title_left" "" "$title" "$title_right")${RESET}"
    print_box_heading "Proxy + Protocolo integrados"
    print_box_close
    echo
}

print_status() {
    local proxy_ports=""
    for pidfile in ${PID_FILE}*.pid; do
        if [ -f "$pidfile" ]; then
            PORT=$(basename "$pidfile" .pid | sed 's/mtproxy_//')
            if ps -p $(cat "$pidfile") > /dev/null 2>&1; then
                proxy_ports="$proxy_ports $PORT"
            else
                rm -f "$pidfile"
            fi
        fi
    done
    proxy_ports=$(echo "$proxy_ports" | xargs | tr ' ' ',')

    print_box_open
    if [ -n "$proxy_ports" ]; then
        print_box_line "${WHITE} Proxy ativo: ${GREEN}✅${RESET}"
        print_box_line "${WHITE} Portas: ${CYAN}${proxy_ports}${RESET}"
    else
        print_box_line "${WHITE} Proxy: ${RED}❌ INATIVO${RESET}"
    fi
    print_box_close
    echo
}

pause() {
    echo
    print_warning "Pressione Enter para continuar..."
    read -r
}

print_warning() { echo -e "${YELLOW}$1${RESET}"; }
print_success() { echo -e "${GREEN}$1${RESET}"; }
print_error() { echo -e "${RED}$1${RESET}"; }
print_info() { echo -e "${CYAN}$1${RESET}"; }

open_port() {
    print_header
    echo -e "${BLUE}🔓 ABRIR PORTA${RESET}"
    print_box_divider
    echo ""
    
    read -p "Digite o número da porta: " PORT
    if [[ -z "$PORT" ]]; then
        print_error "Porta inválida!"
        pause
        return
    fi
    
    sudo fuser -k $PORT/tcp 2>/dev/null
    if [[ -f "${PID_FILE}${PORT}.pid" ]]; then
        rm -f "${PID_FILE}${PORT}.pid"
    fi
    
    print_info "Abrindo porta ${PORT}..."
    if [ "$PORT" -lt 1024 ]; then
        nohup sudo ${MT_BIN} -p ${PORT} > "/tmp/mtproxy_${PORT}.log" 2>&1 &
    else
        nohup ${MT_BIN} -p ${PORT} > "/tmp/mtproxy_${PORT}.log" 2>&1 &
    fi
    
    echo $! > "${PID_FILE}${PORT}.pid"
    sleep 2
    
    if ps -p $(cat "${PID_FILE}${PORT}.pid})" > /dev/null 2>&1; then
        print_success "Porta ${PORT} aberta!"
        print_info "Log: /tmp/mtproxy_${PORT}.log"
    else
        print_error "Falha ao abrir porta ${PORT}!"
        rm -f "${PID_FILE}${PORT}.pid"
    fi
    pause
}

close_port() {
    print_header
    echo -e "${BLUE}🔒 FECHAR PORTA${RESET}"
    print_box_divider
    echo ""
    
    read -p "Digite o número da porta: " PORT
    if [[ -z "$PORT" ]]; then
        print_error "Porta inválida!"
        pause
        return
    fi
    
    if [[ -f "${PID_FILE}${PORT}.pid" ]]; then
        PID=$(cat "${PID_FILE}${PORT}.pid})
        sudo kill -9 $PID 2>/dev/null
        rm -f "${PID_FILE}${PORT}.pid"
        print_success "Porta ${PORT} fechada!"
    else
        print_error "Porta ${PORT} não está aberta!"
    fi
    pause
}

show_status() {
    print_header
    echo -e "${BLUE}📊 STATUS${RESET}"
    print_box_divider
    echo ""
    
    for pidfile in ${PID_FILE}*.pid; do
        if [ -f "$pidfile" ]; then
            PORT=$(basename "$pidfile" .pid | sed 's/mtproxy_//')
            PID=$(cat "$pidfile")
            if ps -p $PID > /dev/null 2>&1; then
                echo -e "${GREEN}✅ Porta $PORT: ativa (PID: $PID)${NC}"
                echo -e "   Log: /tmp/mtproxy_${PORT}.log"
            fi
        fi
    done
    echo ""
    pause
}

show_logs() {
    print_header
    echo -e "${BLUE}📝 LOGS${RESET}"
    print_box_divider
    echo ""
    
    ls -la /tmp/mtproxy_*.log 2>/dev/null || echo -e "${YELLOW}Nenhum log encontrado${NC}"
    echo ""
    read -p "Digite a porta para ver o log (Enter para sair): " PORT
    if [ -n "$PORT" ] && [ -f "/tmp/mtproxy_${PORT}.log" ]; then
        echo ""
        tail -n 50 "/tmp/mtproxy_${PORT}.log"
        echo ""
    fi
    pause
}

show_multiprotocol() {
    print_header
    echo -e "${BLUE}📡 MULTIPROTOCOLO${NC}"
    print_box_divider
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
    pause
}

show_multistatus() {
    print_header
    echo -e "${BLUE}📊 MULTISTATUS${NC}"
    print_box_divider
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
                        KEEP_ALIVE=$(grep -c "💓" "$LOG" 2>/dev/null || echo "0")
                        echo -e "     Conexões: $CONNECTIONS"
                        echo -e "     Keep-Alive: $KEEP_ALIVE"
                    fi
                fi
            fi
        done
    else
        echo -e "${RED}❌ Proxy está INATIVO${NC}"
    fi
    echo ""
    pause
}

show_menu_principal() {
    print_header
    print_status
    print_box_open
    print_box_heading "MENU PRINCIPAL"
    print_box_divider

    local menu_items=(
        "1 • Abrir Porta"
        "2 • Fechar Porta"
        "3 • Status"
        "4 • Ver Logs"
        "5 • Multiprotocolo"
        "6 • Multistatus"
        "0 • Sair"
    )

    for item in "${menu_items[@]}"; do
        if [[ $item == 0* ]]; then
            render_menu_option "$item" "red"
        else
            render_menu_option "$item"
        fi
    done

    print_box_close
    echo
    echo -n -e "${BLUE}Selecione uma opção [0-6]: ${RESET}"
}

while true; do
    show_menu_principal
    read OPTION
    case $OPTION in
        1) open_port ;;
        2) close_port ;;
        3) show_status ;;
        4) show_logs ;;
        5) show_multiprotocol ;;
        6) show_multistatus ;;
        0) 
            echo -e "${GREEN}👋 Saindo...${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}❌ Opção inválida!${NC}"
            sleep 2 
            ;;
    esac
done
