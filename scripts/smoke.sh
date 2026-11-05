#!/bin/bash
# End-to-end smoke test: start tfctl, verify HTTP / SOCKS5 / CONNECT proxying.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=".build/debug/tfctl"
[ -x "$BIN" ] || { echo "build first: swift build --product tfctl"; exit 1; }

LOG=$(mktemp -t tfctl.XXXXXX)
"$BIN" run >"$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null' EXIT

for i in $(seq 1 40); do
    nc -z 127.0.0.1 7890 2>/dev/null && break
    sleep 0.25
done

pass=0; fail=0
check() { # name cmd...
    local name="$1"; shift
    if out=$("$@" 2>&1); then echo "PASS  $name"; pass=$((pass+1));
    else echo "FAIL  $name :: $(echo "$out" | tail -2 | tr '\n' ' ')"; fail=$((fail+1)); fi
}

check "http proxy (plain)"      curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x http://127.0.0.1:7890 http://example.com/
check "http proxy (CONNECT)"    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x http://127.0.0.1:7890 https://example.com/
check "socks5h proxy"           curl -s -o /dev/null -w '%{http_code}' --max-time 10 --socks5-hostname 127.0.0.1:7890 https://example.com/
check "dedicated socks port"    curl -s -o /dev/null -w '%{http_code}' --max-time 10 --socks5-hostname 127.0.0.1:7892 https://example.com/
check "rule explain"            "$BIN" rules example.com
check "adblock verdict"         "$BIN" adblock doubleclick.net
check "dns resolve"             "$BIN" dns example.com

echo "----"
echo "pass=$pass fail=$fail  (log: $LOG)"
[ "$fail" -eq 0 ] || tail -30 "$LOG"
