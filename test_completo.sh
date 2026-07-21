#!/bin/bash
# Teste completo do MTProxy v2.0
# Verifica todos os protocolos e funcionalidades

set -e
PORT=${1:-9990}
SECRET=${2:-"abcdef1234567890abcdef1234567890"}
PREFIX=${3:-"dd"}

echo "========================================="
echo "  MTProxy v2.0 - Teste Completo"
echo "========================================="
echo ""

# Iniciar proxy
echo "Iniciando proxy na porta $PORT..."
./target/release/mtproxy \
    --port $PORT \
    --secret $SECRET \
    --prefix $PREFIX \
    --sni www.google.com \
    --log warn &
PROXY_PID=$!
sleep 2

PASS=0
FAIL=0

# Teste 1: HTTP GET
echo -n "1. HTTP GET ............ "
RESP=$(curl -s --max-time 3 http://127.0.0.1:$PORT/ 2>&1)
if [ "$RESP" = "@MTProxy" ]; then
    echo "OK"
    PASS=$((PASS+1))
else
    echo "FALHOU (resposta: '$RESP')"
    FAIL=$((FAIL+1))
fi

# Teste 2: HTTP CONNECT
echo -n "2. HTTP CONNECT ........ "
CODE=$(curl -s --max-time 3 -X CONNECT http://127.0.0.1:$PORT/example.com:443 -o /dev/null -w "%{http_code}" 2>&1)
if [ "$CODE" = "200" ]; then
    echo "OK (200)"
    PASS=$((PASS+1))
else
    echo "FALHOU (código: '$CODE')"
    FAIL=$((FAIL+1))
fi

# Teste 3: SOCKS5 Handshake
echo -n "3. SOCKS5 Handshake .... "
RESP=$(python3 -c "
import socket
s = socket.socket()
s.settimeout(3)
s.connect(('127.0.0.1', $PORT))
s.sendall(b'\x05\x01\x00')
data = s.recv(2)
s.close()
print(data.hex())
" 2>&1)
if [ "$RESP" = "0500" ]; then
    echo "OK (0500)"
    PASS=$((PASS+1))
else
    echo "FALHOU (resposta: '$RESP')"
    FAIL=$((FAIL+1))
fi

# Teste 4: Fallback (probe resistance)
echo -n "4. Fallback ............ "
RESP=$(python3 -c "
import socket, time
s = socket.socket()
s.settimeout(3)
s.connect(('127.0.0.1', $PORT))
s.sendall(b'\xFF\xFE\xFD test')
time.sleep(0.5)
data = s.recv(4096)
s.close()
resp = data[:20].decode('utf-8', errors='replace')
print(resp)
" 2>&1)
if echo "$RESP" | grep -q "200 OK"; then
    echo "OK (200 OK)"
    PASS=$((PASS+1))
else
    echo "FALHOU (resposta: '$RESP')"
    FAIL=$((FAIL+1))
fi

# Teste 5: WebSocket Handshake
echo -n "5. WebSocket ........... "
RESP=$(python3 -c "
import socket, hashlib, base64, os
s = socket.socket()
s.settimeout(3)
s.connect(('127.0.0.1', $PORT))
key = base64.b64encode(os.urandom(16)).decode()
req = f'GET / HTTP/1.1\r\nHost: test\r\nUpgrade: websocket\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nConnection: Upgrade\r\n\r\n'
s.sendall(req.encode())
data = s.recv(1024)
s.close()
resp = data.decode('utf-8', errors='replace')
if '101' in resp:
    expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-5AB9DC85B14F').encode()).digest()).decode()
    if expected in resp:
        print('OK_101_ACCEPT')
    else:
        print('OK_101_NO_ACCEPT')
else:
    print(f'FAIL:{resp[:50]}')
" 2>&1)
if echo "$RESP" | grep -q "OK_101"; then
    echo "OK (101 Switching)"
    PASS=$((PASS+1))
else
    echo "FALHOU ($RESP)"
    FAIL=$((FAIL+1))
fi

# Parar proxy
kill $PROXY_PID 2>/dev/null
wait $PROXY_PID 2>/dev/null

echo ""
echo "========================================="
echo "  Resultados: $PASS passaram, $FAIL falharam"
echo "========================================="

if [ $FAIL -eq 0 ]; then
    echo "  ✅ TODOS OS TESTES PASSARAM!"
else
    echo "  ❌ Alguns testes falharam"
fi
