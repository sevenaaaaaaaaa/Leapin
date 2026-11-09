#!/bin/bash
# P2 end-to-end: two isolated Leapin stores, LAN pairing, content-addressed
# version convergence, offline edit delivery and device-level override.
#
#   LEAPIN_BIN=.build-lead/debug/leapin scripts/sync-e2e.sh
set -uo pipefail

cd "$(dirname "$0")/.."
LEAPIN_BIN=$(printenv LEAPIN_BIN 2>/dev/null || true)
if [ -z "$LEAPIN_BIN" ]; then LEAPIN_BIN=".build/debug/leapin"; fi
if [ ! -x "$LEAPIN_BIN" ]; then echo "leapin not found: $LEAPIN_BIN"; exit 1; fi

ROOT=$(mktemp -d "/tmp/leapin-sync.XXXXXX")
A="$ROOT/a"
B="$ROOT/b"
mkdir -p "$A" "$B"
export LEAPIN_SYNC_FILE_KEY=1
pass=0; fail=0
check() {
  if [ "$2" -eq 0 ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi
}
json_get() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d$2)" "$1"; }

cat > "$ROOT/a.surge" <<'EOF'
[General]
[Rule]
DOMAIN-SUFFIX,example.com,DIRECT
DOMAIN,api.example.com,DIRECT
MATCH,DIRECT,DIRECT
EOF
cat > "$ROOT/b.surge" <<'EOF'
[General]
[Rule]
DOMAIN-SUFFIX,example.org,PROXY
DOMAIN-KEYWORD,offline,DIRECT
MATCH,DIRECT,DIRECT
EOF

APID=""
stop_server() {
  if [ -n "$APID" ] && kill -0 "$APID" 2>/dev/null; then
    kill "$APID" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$APID" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$APID" 2>/dev/null
  fi
  APID=""
}
cleanup() { stop_server; echo "work: $ROOT"; }
trap cleanup EXIT

wait_server() {
  local log="$1" i
  for i in $(seq 1 100); do
    PORT=$(grep -o '已启动：[0-9.]*:[0-9]*' "$log" | head -1 | sed 's/.*://')
    CODE=$(grep -o '配对码：[0-9]\{6\}' "$log" | grep -o '[0-9]\{6\}' | head -1)
    if [ -n "$PORT" ] && [ -n "$CODE" ]; then return 0; fi
    sleep 0.1
  done
  return 1
}

echo "== 1. A 生成首个版本"
LEAPIN_PROFILE_ROOT="$A" "$LEAPIN_BIN" sync record --profile "$ROOT/a.surge" > "$ROOT/a-record.log" 2>&1
check "A 记录版本" $?
A_STATUS="$ROOT/a-status.json"; LEAPIN_PROFILE_ROOT="$A" "$LEAPIN_BIN" sync status --json > "$A_STATUS"
A_V1=$(json_get "$A_STATUS" "['effective']")
check "A 生效版本非空" $([ -n "$A_V1" ] && echo 0 || echo 1)
check "A 只有 1 个版本" $([ "$(json_get "$A_STATUS" "['versions'].__len__()")" = "1" ] && echo 0 || echo 1)

echo "== 2. A 起服务，B 配对并拉取（计 5s 收敛）"
LEAPIN_PROFILE_ROOT="$A" "$LEAPIN_BIN" sync serve --port 0 > "$ROOT/a-serve.log" 2>&1 &
APID=$!
wait_server "$ROOT/a-serve.log"; check "A 同步服务就绪" $?

echo "== 2b. 只读面板：token 鉴权 + 只读 + 元数据"
PANEL_TOKEN=$(cat "$A/sync/panel-token" 2>/dev/null || echo "")
check "面板令牌文件存在" $([ -n "$PANEL_TOKEN" ] && echo 0 || echo 1)
check "面板令牌权限 0600" $([ "$(stat -f '%Lp' "$A/sync/panel-token" 2>/dev/null)" = "600" ] && echo 0 || echo 1)
NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/panel")
check "面板无令牌 401" $([ "$NOAUTH" = "401" ] && echo 0 || echo 1)
BADAUTH=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/panel?token=$(printf 'f%.0s' $(seq 64))")
check "面板错令牌 401" $([ "$BADAUTH" = "401" ] && echo 0 || echo 1)
PANEL_HTTP=$(curl -s -o "$ROOT/panel.html" -w '%{http_code}' "http://127.0.0.1:$PORT/panel?token=$PANEL_TOKEN")
check "面板 HTML 200" $([ "$PANEL_HTTP" = "200" ] && echo 0 || echo 1)
check "面板含只读横幅" $(grep -q '只读面板' "$ROOT/panel.html" && echo 0 || echo 1)
check "面板不含规则值" $(grep -q 'example.com' "$ROOT/panel.html" && echo 1 || echo 0)
curl -s "http://127.0.0.1:$PORT/panel.json?token=$PANEL_TOKEN" > "$ROOT/panel.json" 2>/dev/null
check "panel.json 有 1 个版本" $([ "$(json_get "$ROOT/panel.json" "['versions'].__len__()")" = "1" ] && echo 0 || echo 1)
check "panel.json readOnly=true" $([ "$(json_get "$ROOT/panel.json" "['readOnly']")" = "True" ] && echo 0 || echo 1)
MUT=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/panel?token=$PANEL_TOKEN")
check "面板 POST 405" $([ "$MUT" = "405" ] && echo 0 || echo 1)
START=$(python3 -c 'import time;print(time.time())')
LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync pair "127.0.0.1:$PORT" --code "$CODE" > "$ROOT/b-pair.log" 2>&1
check "B 配对成功" $?
LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync pull "127.0.0.1:$PORT" > "$ROOT/b-pull.log" 2>&1
check "B 拉取成功" $?
END=$(python3 -c 'import time;print(time.time())')
ELAPSED=$(python3 -c "print(round($END-$START,2))")
check "配对+拉取 <5s（实际 $ELAPSED s）" $(python3 -c "print(0 if $END-$START < 5 else 1)")
B_STATUS="$ROOT/b-status.json"; LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync status --json > "$B_STATUS"
check "B 生效版本与 A 一致" $([ "$(json_get "$B_STATUS" "['effective']")" = "$A_V1" ] && echo 0 || echo 1)
check "B 已应用该版本" $([ "$(json_get "$B_STATUS" "['applied']")" = "$A_V1" ] && echo 0 || echo 1)

echo "== 3. 离线编辑：停 A，B 新建版本"
stop_server
LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync record --profile "$ROOT/b.surge" > "$ROOT/b-record.log" 2>&1
check "B 离线记录新版本" $?
B_OFFLINE="$ROOT/b-offline.json"; LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync status --json > "$B_OFFLINE"
B_V2=$(json_get "$B_OFFLINE" "['effective']")
check "B 本地已有 2 个版本" $([ "$(json_get "$B_OFFLINE" "['versions'].__len__()")" = "2" ] && echo 0 || echo 1)
check "B 离线版本与 v1 不同" $([ "$B_V2" != "$A_V1" ] && echo 0 || echo 1)

echo "== 4. 重连：B 把离线版本推给 A"
LEAPIN_PROFILE_ROOT="$A" "$LEAPIN_BIN" sync serve --port 0 > "$ROOT/a-serve2.log" 2>&1 &
APID=$!
wait_server "$ROOT/a-serve2.log"; check "A 同步服务重启" $?
LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync pair "127.0.0.1:$PORT" --code "$CODE" > "$ROOT/b-pair2.log" 2>&1
check "B 重新配对" $?
LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync pull "127.0.0.1:$PORT" > "$ROOT/b-pull2.log" 2>&1
check "B 第二轮拉取" $?
A_STATUS2="$ROOT/a-status2.json"; LEAPIN_PROFILE_ROOT="$A" "$LEAPIN_BIN" sync status --json > "$A_STATUS2"
B_STATUS2="$ROOT/b-status2.json"; LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync status --json > "$B_STATUS2"
check "A 收到 B 的离线版本（2 个版本）" $([ "$(json_get "$A_STATUS2" "['versions'].__len__()")" = "2" ] && echo 0 || echo 1)
check "A 生效版本 = B 的离线版本" $([ "$(json_get "$A_STATUS2" "['effective']")" = "$B_V2" ] && echo 0 || echo 1)
check "B 生效版本仍为离线版本" $([ "$(json_get "$B_STATUS2" "['effective']")" = "$B_V2" ] && echo 0 || echo 1)
LEAPIN_PROFILE_ROOT="$A" "$LEAPIN_BIN" sync panel --port "$PORT" --json > "$ROOT/a-panel-link.json" 2>/dev/null
A_PANEL_URL=$(json_get "$ROOT/a-panel-link.json" "['url']")
check "sync panel 打印链接" $([ -n "$A_PANEL_URL" ] && echo 0 || echo 1)
A_PANEL_JSON_URL=$(printf '%s' "$A_PANEL_URL" | sed 's|/panel?|/panel.json?|')
curl -s "$A_PANEL_JSON_URL" > "$ROOT/panel2.json" 2>/dev/null
check "面板显示 2 个版本" $([ "$(json_get "$ROOT/panel2.json" "['versions'].__len__()")" = "2" ] && echo 0 || echo 1)
check "面板生效版本与 A 状态一致" $([ "$(json_get "$ROOT/panel2.json" "['effective']")" = "$B_V2" ] && echo 0 || echo 1)

echo "== 5. 设备级 override：B 固定回 v1，A 保持 v2"
LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync override "$A_V1" > "$ROOT/b-override.log" 2>&1
check "B 设置 override" $?
LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync pull "127.0.0.1:$PORT" > "$ROOT/b-pull3.log" 2>&1
check "B override 后拉取" $?
B_STATUS3="$ROOT/b-status3.json"; LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync status --json > "$B_STATUS3"
check "B override 生效（仍是 v1）" $([ "$(json_get "$B_STATUS3" "['effective']")" = "$A_V1" ] && echo 0 || echo 1)
LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync override --clear >/dev/null 2>&1
B_STATUS4="$ROOT/b-status4.json"; LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync status --json > "$B_STATUS4"
check "清除 override 后回到 v2" $([ "$(json_get "$B_STATUS4" "['effective']")" = "$B_V2" ] && echo 0 || echo 1)

echo "== 6. 错误配对码被拒绝"
if LEAPIN_PROFILE_ROOT="$B" "$LEAPIN_BIN" sync pair "127.0.0.1:$PORT" --code 000000 > "$ROOT/bad-pair.log" 2>&1; then
  check "错误配对码应失败" 1
else
  check "错误配对码被拒绝" 0
fi

echo "----"
echo "pass=$pass fail=$fail  (work: $ROOT)"
[ "$fail" -eq 0 ]