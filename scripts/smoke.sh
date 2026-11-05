#!/bin/bash
# End-to-end smoke test: start tfctl, verify HTTP / SOCKS5 / CONNECT proxying.
# 端口可用 TF_SMOKE_PORT 错开（默认 7890；专用 socks 端口 = TF_SMOKE_PORT + 2）。
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=${TF_SMOKE_BIN:-".build/debug/tfctl"}
[ -x "$BIN" ] || { echo "build first: swift build --product tfctl"; exit 1; }

MIXED_PORT=${TF_SMOKE_PORT:-7890}
HTTP_PORT=$((MIXED_PORT + 1))
SOCKS_PORT=${TF_SMOKE_SOCKS_PORT:-$((MIXED_PORT + 2))}

# 最小专用配置：监听端口跟随 TF_SMOKE_PORT，避免与正在运行的实例抢默认端口。
PROFILE=$(mktemp -t tfctl-smoke.XXXXXX).surge
{
    echo "[General]"
    echo "mixed-listen = :$MIXED_PORT"
    echo "http-listen = :$HTTP_PORT"
    echo "socks5-listen = :$SOCKS_PORT"
    echo "loglevel = warning"
    echo
    echo "[Rule]"
    echo "FINAL,DIRECT"
} >"$PROFILE"

LOG=$(mktemp -t tfctl.XXXXXX)
"$BIN" run --profile "$PROFILE" >"$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -f "$PROFILE"' EXIT

for i in $(seq 1 40); do
    nc -z 127.0.0.1 "$MIXED_PORT" 2>/dev/null && break
    sleep 0.25
done

pass=0; fail=0
check() { # name cmd...
    local name="$1"; shift
    if out=$("$@" 2>&1); then echo "PASS  $name"; pass=$((pass+1));
    else echo "FAIL  $name :: $(echo "$out" | tail -2 | tr '\n' ' ')"; fail=$((fail+1)); fi
}

check "http proxy (plain)"      curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "http://127.0.0.1:$MIXED_PORT" http://example.com/
check "http proxy (CONNECT)"    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x "http://127.0.0.1:$MIXED_PORT" https://example.com/
check "socks5h proxy"           curl -s -o /dev/null -w '%{http_code}' --max-time 10 --socks5-hostname "127.0.0.1:$MIXED_PORT" https://example.com/
check "dedicated socks port"    curl -s -o /dev/null -w '%{http_code}' --max-time 10 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://example.com/
check "rule explain"            "$BIN" rules example.com
check "adblock verdict"         "$BIN" adblock doubleclick.net
check "dns resolve"             "$BIN" dns example.com
check "rule diagnostics"        "$BIN" rules example.com --diagnose
check "dns trace"               "$BIN" dns example.com --trace
check "http probe (json)"       "$BIN" http-probe http://example.com/ --json

echo "----"
echo "pass=$pass fail=$fail  (ports: mixed=$MIXED_PORT socks=$SOCKS_PORT, log: $LOG)"
[ "$fail" -eq 0 ] || tail -30 "$LOG"