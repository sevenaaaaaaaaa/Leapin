#!/bin/bash
# P1 control-plane end-to-end test.
#
# Runs a throwaway leapin instance against an isolated profile store
# (LEAPIN_PROFILE_ROOT), then proves with curl only:
#   * token auth (401 without, 200 with Bearer)
#   * GET /v1/status, /v1/policies, /v1/connections
#   * SSE /v1/events delivers a live flow event
#   * POST /v1/policies/select switches a group without restarting
#   * POST /v1/reload applies a changed rule with restarted=false WHILE a
#     long download through the proxy keeps running (P1 acceptance)
#   * git-style audit trail /v1/audit records allowed + denied calls
#   * 404 / 405 handling
#
# Usage: scripts/control-e2e.sh   (needs .build/debug/leapin; LEAPIN_BIN= to override)
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=${LEAPIN_BIN:-.build/debug/leapin}
[ -x "$BIN" ] || { echo "build first: swift build --product leapin"; exit 1; }

WORK=$(mktemp -d -t leapin-control.XXXXXX)
export LEAPIN_PROFILE_ROOT="$WORK/store"
MIXED=${LEAPIN_E2E_MIXED:-17890}
CONTROL=${LEAPIN_E2E_CONTROL:-17900}
WEB=${LEAPIN_E2E_WEB:-18081}
LOG="$WORK/leapin.log"
SERVER_LOG="$WORK/server.log"

cleanup() {
    [ -n "${SLOW_PID:-}" ] && kill "$SLOW_PID" 2>/dev/null
    [ -n "${SSE_PID:-}" ] && kill "$SSE_PID" 2>/dev/null
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1${2:+ :: $2}"; fail=$((fail+1)); }
check() { # name condition-exit-status detail
    local name="$1" code="$2" detail="${3:-}"
    if [ "$code" -eq 0 ]; then ok "$name"; else bad "$name" "$detail"; fi
}

# ---- fixtures -------------------------------------------------------------

cat > "$WORK/server.py" <<'PY'
import http.server, socketserver, sys, time

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/slow":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "120000")
            self.end_headers()
            try:
                for _ in range(30):
                    self.wfile.write(b"x" * 4000); self.wfile.flush(); time.sleep(0.1)
            except Exception:
                pass
        else:
            body = b"hello from control e2e\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

with socketserver.ThreadingTCPServer(("127.0.0.1", int(sys.argv[1])), H) as srv:
    srv.allow_reuse_address = True
    srv.serve_forever()
PY

profile_v1() {
cat <<YAML
mixed-port: $MIXED
allow-lan: false
control-port: $CONTROL
control-allow-lan: false
log-level: warning
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT, REJECT]
rules:
  - DOMAIN-SUFFIX,example.com,DIRECT
  - DOMAIN-SUFFIX,blocked.example.org,REJECT
  - MATCH,DIRECT
YAML
}

profile_v2() {
cat <<YAML
mixed-port: $MIXED
allow-lan: false
control-port: $CONTROL
control-allow-lan: false
log-level: warning
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT, REJECT]
rules:
  - DOMAIN-SUFFIX,example.com,REJECT
  - DOMAIN-SUFFIX,blocked.example.org,REJECT
  - MATCH,DIRECT
YAML
}

profile_v1 > "$WORK/v1.yaml"
profile_v2 > "$WORK/v2.yaml"

# ---- start local origin + engine -----------------------------------------

python3 "$WORK/server.py" "$WEB" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
"$BIN" import "$WORK/v1.yaml" >"$WORK/import1.txt" 2>&1 || { echo "import failed"; cat "$WORK/import1.txt"; exit 1; }

"$BIN" run >"$LOG" 2>&1 &
PID=$!

ready=0
for _ in $(seq 1 60); do
    if nc -z 127.0.0.1 "$MIXED" 2>/dev/null && nc -z 127.0.0.1 "$CONTROL" 2>/dev/null; then ready=1; break; fi
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.25
done
if [ "$ready" -ne 1 ]; then
    echo "engine did not start (mixed=$MIXED control=$CONTROL)"
    tail -20 "$LOG"
    exit 1
fi

TOKEN_PATH=$(find "$LEAPIN_PROFILE_ROOT" -maxdepth 3 \( -name 'control-token' -o -name 'token' \) -type f 2>/dev/null | head -1)
if [ -z "$TOKEN_PATH" ]; then
    echo "token file not found under $LEAPIN_PROFILE_ROOT"
    find "$LEAPIN_PROFILE_ROOT" -maxdepth 3 -type f | sed 's/^/  /'
    exit 1
fi
TOKEN=$(cat "$TOKEN_PATH")
BASE="http://127.0.0.1:$CONTROL"
AUTH=(-H "Authorization: Bearer $TOKEN")
say() { echo "---- $1"; }

# ---- auth ----------------------------------------------------------------

say "auth"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/v1/status")
[ "$code" = "401" ]; check "无 token → 401" $? "got $code"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer wrong" "$BASE/v1/status")
[ "$code" = "401" ]; check "错误 token → 401" $? "got $code"

perms=$(stat -f '%Lp' "$TOKEN_PATH")
[ "$perms" = "600" ]; check "token 文件权限 0600" $? "got $perms"

# ---- status / policies ---------------------------------------------------

say "status"
body=$(curl -s --max-time 5 "${AUTH[@]}" "$BASE/v1/status")
echo "$body" | grep -q '"ok":true'; check "status ok:true" $? "$body"
echo "$body" | grep -q 'running'; check "status 引擎 running" $? "$body"
echo "$body" | grep -q '\"controlPort\":'"$CONTROL"; check "status 报告 controlPort" $? "$body"

say "policies"
policies=$(curl -s --max-time 5 "${AUTH[@]}" "$BASE/v1/policies")
echo "$policies" | grep -q 'PROXY'; check "policies 含 PROXY 组" $? "$policies"

# ---- explain + select ----------------------------------------------------

say "explain"
explain=$(curl -s --max-time 5 "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d '{"host":"example.com","port":443}' "$BASE/v1/explain")
echo "$explain" | grep -q 'DOMAIN-SUFFIX,example.com'; check "explain 命中 v1 规则" $? "$explain"
echo "$explain" | grep -q '"policy":"DIRECT"'; check "explain 策略 DIRECT" $? "$explain"

say "select"
sel=$(curl -s --max-time 5 "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d '{"group":"PROXY","outbound":"REJECT"}' "$BASE/v1/policies/select")
echo "$sel" | grep -q '"effective":"REJECT"'; check "select PROXY→REJECT" $? "$sel"
policies=$(curl -s --max-time 5 "${AUTH[@]}" "$BASE/v1/policies")
echo "$policies" | grep -q '\"selected\":\"REJECT\"'; check "policies 记录 selected" $? "$policies"
curl -s --max-time 5 "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d '{"group":"PROXY","outbound":"DIRECT"}' "$BASE/v1/policies/select" >/dev/null

# ---- SSE + connections ---------------------------------------------------

say "sse"
curl -sN --max-time 4 "${AUTH[@]}" "$BASE/v1/events?since=0" > "$WORK/sse.txt" 2>&1 &
SSE_PID=$!
sleep 0.4
curl -s -o /dev/null --max-time 10 -x "http://127.0.0.1:$MIXED" "http://example.com/"
sleep 0.8
kill "$SSE_PID" 2>/dev/null; wait "$SSE_PID" 2>/dev/null
grep -q 'data:' "$WORK/sse.txt"; check "SSE 收到事件帧" $? "$(head -3 "$WORK/sse.txt")"
grep -q 'example.com' "$WORK/sse.txt"; check "SSE 事件含 example.com" $? "$(head -3 "$WORK/sse.txt")"

say "connections"
conns=$(curl -s --max-time 5 "${AUTH[@]}" "$BASE/v1/connections?limit=20")
echo "$conns" | grep -q 'example.com'; check "connections 列出 example.com" $? "$conns"

# ---- diff reload while a download survives --------------------------------

say "reload (diff, connections preserved)"
curl -s -o "$WORK/slow.out" -w '%{http_code}' --max-time 20 \
    -x "http://127.0.0.1:$MIXED" "http://127.0.0.1:$WEB/slow" > "$WORK/slow.code" 2>"$WORK/slow.err" &
SLOW_PID=$!
sleep 0.8
"$BIN" import "$WORK/v2.yaml" >"$WORK/import2.txt" 2>&1
ID2=$(sed -n 's/^id: //p' "$WORK/import2.txt" | head -1)
[ -n "$ID2" ] && printf '%s' "$ID2" > "$LEAPIN_PROFILE_ROOT/active.json"
reload=$(curl -s --max-time 30 "${AUTH[@]}" -X POST "$BASE/v1/reload")
echo "$reload" | grep -q '"restarted":false'; check "reload restarted=false" $? "$reload"
echo "$reload" | grep -q 'rules'; check "reload 报告应用项" $? "$reload"

wait "$SLOW_PID"; slow_rc=$?
code=$(cat "$WORK/slow.code" 2>/dev/null)
size=$(wc -c < "$WORK/slow.out" | tr -d ' ')
[ "$slow_rc" -eq 0 ] && [ "$code" = "200" ] && [ "$size" -gt 100000 ]
check "reload 期间慢速下载未断开 (200, ${size}B)" $? "rc=$slow_rc code=$code size=$size $(tail -1 "$WORK/slow.err")"

explain=$(curl -s --max-time 5 "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d '{"host":"example.com","port":443}' "$BASE/v1/explain")
echo "$explain" | grep -q 'DOMAIN-SUFFIX,example.com,REJECT'; check "reload 后新规则生效 (REJECT)" $? "$explain"

# ---- audit ---------------------------------------------------------------

say "audit"
audit=$(curl -s --max-time 5 "${AUTH[@]}" "$BASE/v1/audit?limit=50")
echo "$audit" | grep -q 'reload'; check "audit 记录 reload" $? "$audit"
echo "$audit" | grep -q '"allowed":false'; check "audit 记录被拒请求" $? "$audit"

# ---- 404 / 405 -----------------------------------------------------------

say "http semantics"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${AUTH[@]}" "$BASE/v1/does-not-exist")
[ "$code" = "404" ]; check "未知路径 404" $? "got $code"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${AUTH[@]}" -X DELETE "$BASE/v1/status")
[ "$code" = "405" ]; check "错误方法 405" $? "got $code"

# ---- summary -------------------------------------------------------------

echo "----"
echo "pass=$pass fail=$fail  (work: $WORK, log: $LOG)"
if [ "$fail" -ne 0 ]; then
    echo "---- leapin log (tail)"
    tail -30 "$LOG"
    exit 1
fi