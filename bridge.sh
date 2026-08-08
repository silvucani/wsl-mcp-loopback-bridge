#!/usr/bin/env bash
# Bridge a Windows MCP server bound to 127.0.0.1 so a client inside WSL2 can reach it.
#
#   ./bridge.sh [app-port] [relay-port]
#   ./bridge.sh --stop [app-port]
#
# Default app-port is 29979 (Paper Desktop). Relay port defaults to app-port + 10000.

set -euo pipefail

STOP=0
if [ "${1:-}" = "--stop" ]; then
  STOP=1
  shift
fi

APP_PORT="${1:-29979}"
RELAY_PORT="${2:-$((APP_PORT + 10000))}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

listener_pid() {
  ss -ltnp 2>/dev/null | grep ":$1 " | grep -oP 'pid=\K[0-9]+' | head -1
}

RELAY_PID_FILE="/tmp/mcp-bridge-relay-$APP_PORT.pid"

if [ "$STOP" = 1 ]; then
  pid="$(listener_pid "$APP_PORT")"
  if [ -n "$pid" ]; then
    kill "$pid" && echo "stopped the WSL listener on 127.0.0.1:$APP_PORT (pid $pid)"
  fi
  # Killing the interop process takes the Windows node.exe down with it, which is why the
  # pid is worth recording: the alternative is taskkill on every node.exe on the machine.
  if [ -f "$RELAY_PID_FILE" ]; then
    kill "$(cat "$RELAY_PID_FILE")" 2>/dev/null && echo "stopped the Windows relay"
    rm -f "$RELAY_PID_FILE"
  fi
  exit 0
fi

command -v socat >/dev/null || { echo "socat is missing: sudo apt install socat"; exit 1; }
command -v node.exe >/dev/null || { echo "node.exe is not reachable from WSL: install Node.js on Windows"; exit 1; }

WIN_IP="$(ip route show default | awk '{print $3}')"
[ -n "$WIN_IP" ] || { echo "could not read the Windows host address from the default route"; exit 1; }

# The relay has to sit on Windows: WSL2 cannot reach the Windows loopback at all.
# It listens on a spare port because the app already owns app-port on 127.0.0.1.
nohup node.exe "$(wslpath -w "$SCRIPT_DIR/relay.js")" "$RELAY_PORT" "$APP_PORT" \
  >/tmp/mcp-bridge-relay.log 2>&1 </dev/null &
echo $! >"$RELAY_PID_FILE"
sleep 1

# This half is the part that is easy to miss. It exists so the client connects to
# 127.0.0.1:<app-port> and therefore sends "Host: 127.0.0.1:<app-port>", which is what
# the app's anti-DNS-rebinding check wants to see. Point the client straight at the
# Windows address instead and it answers 403 Invalid host.
start_socat() {
  setsid nohup socat "TCP-LISTEN:$APP_PORT,bind=127.0.0.1,fork,reuseaddr" "TCP:$WIN_IP:$RELAY_PORT" \
    >/tmp/mcp-bridge-socat.log 2>&1 </dev/null &
  sleep 1
}

# A leftover listener is the normal case after "wsl --shutdown", and it is usually pointed at
# the address vEthernet (WSL) had during the previous boot. Reusing it blindly builds a bridge
# to a dead address and then blames the app for not answering, so compare targets first.
existing="$(listener_pid "$APP_PORT")"
if [ -z "$existing" ]; then
  start_socat
elif ! tr '\0' ' ' <"/proc/$existing/cmdline" 2>/dev/null | grep -q '\bsocat\b'; then
  echo "something other than this script holds 127.0.0.1:$APP_PORT (pid $existing), leaving it alone"
elif tr '\0' ' ' <"/proc/$existing/cmdline" | grep -q "TCP:$WIN_IP:$RELAY_PORT"; then
  echo "reusing the listener already on 127.0.0.1:$APP_PORT"
else
  echo "the listener on 127.0.0.1:$APP_PORT points at a stale address, replacing it"
  kill "$existing"
  sleep 1
  start_socat
fi

# One real check: a bridge that carries bytes but fails the host check is still broken,
# so ask the server to speak MCP rather than settling for "the port answered".
code="$(curl -s -o /tmp/mcp-bridge-check.json -w '%{http_code}' --max-time 10 \
  -X POST "http://127.0.0.1:$APP_PORT/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bridge-check","version":"1"}}}')"

if [ "$code" = "200" ]; then
  echo "bridge is up: http://127.0.0.1:$APP_PORT/mcp"
  grep -o '"name":"[^"]*","version":"[^"]*"' /tmp/mcp-bridge-check.json | tail -1
  exit 0
fi

echo "bridge check failed with HTTP $code"
case "$code" in
  000) echo "nothing answered. Is the app running on Windows? Windows Firewall may also be blocking node.exe on port $RELAY_PORT." ;;
  403) echo "the server rejected the Host header. The WSL listener must use the app's own port ($APP_PORT), not a different one." ;;
  404) echo "reached something other than the app. Check that $APP_PORT is really the app's port on Windows." ;;
esac
cat /tmp/mcp-bridge-check.json 2>/dev/null
exit 1
