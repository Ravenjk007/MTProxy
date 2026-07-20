#!/bin/bash
MT_BIN="/usr/local/bin/mtproxy"
PID_FILE="/tmp/mtproxy_"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

while true; do
    clear
    echo "====================================="
    echo "          MTProxy Menu              "
    echo "====================================="
    echo ""
    
    ACTIVE_PORTS=""
    for pidfile in ${PID_FILE}*.pid; do
        if [ -f "$pidfile" ]; then
            PORT=$(basename "$pidfile" .pid | sed 's/mtproxy_//')
            if ps -p $(cat "$pidfile") > /dev/null 2>&1; then
                ACTIVE_PORTS="$ACTIVE_PORTS $PORT"
            else
                rm -f "$pidfile"
            fi
        fi
    done
    
    if [ -n "$ACTIVE_PORTS" ]; then
        echo "Porta(s) aberta(s): $ACTIVE_PORTS"
    else
        echo "Porta(s): nenhuma"
    fi
    echo ""
    echo " 1 - Abrir Porta"
    echo " 2 - Fechar Porta"
    echo " 3 - Status"
    echo " 4 - Ver Logs"
    echo " 5 - Sair"
    echo ""
    echo -n "--> "
    
    read OPTION
    
    case $OPTION in
        1)
            read -p "Digite a porta: " PORT
            if [ -z "$PORT" ]; then
                echo "Porta invalida!"
                sleep 2
                continue
            fi
            
            sudo fuser -k $PORT/tcp 2>/dev/null
            if [ -f "${PID_FILE}${PORT}.pid" ]; then
                rm -f "${PID_FILE}${PORT}.pid"
            fi
            
            echo "Abrindo porta ${PORT}..."
            if [ "$PORT" -lt 1024 ]; then
                nohup sudo ${MT_BIN} -p ${PORT} > "/tmp/mtproxy_${PORT}.log" 2>&1 &
            else
                nohup ${MT_BIN} -p ${PORT} > "/tmp/mtproxy_${PORT}.log" 2>&1 &
            fi
            
            echo $! > "${PID_FILE}${PORT}.pid"
            sleep 2
            
            if ps -p $(cat "${PID_FILE}${PORT}.pid})" > /dev/null 2>&1; then
                echo "Porta ${PORT} aberta!"
            else
                echo "Falha ao abrir porta ${PORT}!"
                rm -f "${PID_FILE}${PORT}.pid"
            fi
            sleep 2
            ;;
        2)
            read -p "Digite a porta: " PORT
            if [ -z "$PORT" ]; then
                echo "Porta invalida!"
                sleep 2
                continue
            fi
            
            if [ -f "${PID_FILE}${PORT}.pid" ]; then
                PID=$(cat "${PID_FILE}${PORT}.pid})
                sudo kill -9 $PID 2>/dev/null
                rm -f "${PID_FILE}${PORT}.pid"
                echo "Porta ${PORT} fechada!"
            else
                echo "Porta ${PORT} nao esta aberta!"
            fi
            sleep 2
            ;;
        3)
            echo "Status:"
            for pidfile in ${PID_FILE}*.pid; do
                if [ -f "$pidfile" ]; then
                    PORT=$(basename "$pidfile" .pid | sed 's/mtproxy_//')
                    PID=$(cat "$pidfile")
                    if ps -p $PID > /dev/null 2>&1; then
                        echo "Porta $PORT: ativa (PID: $PID)"
                    fi
                fi
            done
            echo ""
            read -p "Pressione Enter..."
            ;;
        4)
            echo "Logs disponiveis:"
            ls -la /tmp/mtproxy_*.log 2>/dev/null || echo "Nenhum log"
            echo ""
            read -p "Digite a porta para ver o log (Enter para sair): " PORT
            if [ -n "$PORT" ] && [ -f "/tmp/mtproxy_${PORT}.log" ]; then
                echo ""
                tail -n 30 "/tmp/mtproxy_${PORT}.log"
                echo ""
                read -p "Pressione Enter..."
            fi
            ;;
        5)
            echo "Saindo..."
            exit 0
            ;;
        *)
            echo "Opcao invalida!"
            sleep 2
            ;;
    esac
done
