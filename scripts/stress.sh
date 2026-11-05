#!/bin/bash
# TouchFlow 稳定性压力测试（P5）。只用系统自带工具。
#
# 用法：
#   scripts/stress.sh                       # 3 轮 × 500 并发随机中断
#   TF_STRESS_ROUNDS=5 TF_STRESS_CONCURRENCY=200 scripts/stress.sh
#
# 检查项：并发短连接后进程存活 / FD 回落、端口冲突必须报错、上游不可达、
#        TLS 失败、SIGINT 停止后端口释放与进程不残留。
# 不触碰系统代理（networksetup），避免污染开发者机器。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${TF_STRESS_SCRATCH:-"$ROOT/.build-bench"}
OUT=${TF_STRESS_OUT:-"$ROOT/.stress"}
TFCTL="$SCRATCH/release/tfctl"
ROUNDS=${TF_STRESS_ROUNDS:-3}
CONC=${TF_STRESS_CONCURRENCY:-500}
MIXED_PORT=${TF_STRESS_MIXED_PORT:-17990}
HTTP_PORT=$((MIXED_PORT + 1))
SOCKS_PORT=$((MIXED_PORT + 2))
ORIGIN_PORT=${TF_STRESS_ORIGIN_PORT:-18081}
PROXY_PID=""
ORIGIN_PID=""
FAILED=0
PASSES=0

note() { printf '\n== %s\n' "$*"; }
ok() { PASSES=$((PASSES + 1)); printf '  [PASS] %s\n' "$*"; }
bad() { FAILED=$((FAILED + 1)); printf '  [FAIL] %s\n' "$*"; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000'; }

stop_proxy() {
  if [ -z "$PROXY_PID" ]; then return 0; fi
  kill -INT "$PROXY_PID" 2>/dev/null || true
  local i
  for i in $(seq 1 50); do
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then PROXY_PID=""; return 0; fi
    sleep 0.2
  done
  kill -9 "$PROXY_PID" 2>/dev/null || true
  PROXY_PID=""
  return 1
}

cleanup() {
  stop_proxy || true
  if [ -n "$ORIGIN_PID" ]; then kill "$ORIGIN_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

mkdir -p "$OUT/profiles"
if [ ! -x "$TFCTL" ]; then
  echo "缺少 ${TFCTL}；先跑 scripts/bench.sh 或 swift build -c release --product tfctl --scratch-path .build-bench" >&2
  exit 1
fi

gen_profile() { # $1=输出文件，$2=额外段落（含 [Proxy]/[Rule]）
  local path=$1 extra=${2:-}
  {
    echo "[General]"
    echo "mixed-listen = :$MIXED_PORT"
    echo "http-listen = :$HTTP_PORT"
    echo "socks5-listen = :$SOCKS_PORT"
    echo "loglevel = warning"
    echo
    if [ -n "$extra" ]; then
      printf '%s\n' "$extra"
      echo
    else
      echo "[Rule]"
      echo "DOMAIN-SUFFIX,example.com,DIRECT"
      echo "FINAL,DIRECT"
    fi
  } > "$path"
}

start_proxy() { # $1=profile；0 表示已监听
  local profile=$1 i
  "$TFCTL" run --profile "$profile" >"$OUT/proxy.log" 2>&1 &
  PROXY_PID=$!
  for i in $(seq 1 50); do
    if nc -z 127.0.0.1 "$MIXED_PORT" 2>/dev/null; then return 0; fi
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then PROXY_PID=""; return 1; fi
    sleep 0.2
  done
  return 1
}

fd_count() { lsof -p "$1" 2>/dev/null | wc -l | tr -d ' '; }

# ---------- 0. 本地 origin + 单请求脚本 ----------
note "准备：本地 origin + 压测配置"
ORIGIN_DIR="$OUT/origin"
mkdir -p "$ORIGIN_DIR"
printf 'ok\n' > "$ORIGIN_DIR/index.html"
# 单线程 http.server 会把 500 并发排成队，导致 FD 回落测试测的是 origin 队列而不是代理。
cat > "$OUT/origin_server.py" <<'PY'
import http.server, socketserver, sys

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        body = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

Server(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
python3 "$OUT/origin_server.py" "$ORIGIN_PORT" >"$OUT/origin.log" 2>&1 &
ORIGIN_PID=$!
sleep 1
gen_profile "$OUT/profiles/stress.surge"

export TF_MIXED_PORT="$MIXED_PORT" TF_ORIGIN_PORT="$ORIGIN_PORT"
cat > "$OUT/request.sh" <<'REQ'
#!/bin/bash
t=$(awk -v s="$1" 'BEGIN { srand(s); printf "%.2f", 0.05 + rand() * 0.75 }')
curl -s -o /dev/null --max-time "$t" -x "http://127.0.0.1:$TF_MIXED_PORT" "http://127.0.0.1:$TF_ORIGIN_PORT/" || true
REQ
chmod +x "$OUT/request.sh"

# ---------- 1. 并发 + 随机中断 ----------
note "1) $ROUNDS 轮 × $CONC 并发随机中断连接"
round=1
while [ "$round" -le "$ROUNDS" ]; do
  if ! start_proxy "$OUT/profiles/stress.surge"; then
    bad "第 $round 轮：代理启动失败（见 $OUT/proxy.log）"
    tail -10 "$OUT/proxy.log" | sed 's/^/      /'
    round=$((round + 1))
    continue
  fi
  fd_before=$(fd_count "$PROXY_PID")
  t0=$(now_ms)
  seq 1 "$CONC" | xargs -P "$CONC" -I{} "$OUT/request.sh" {} >/dev/null 2>&1
  t1=$(now_ms)
  # 中断连接的半关闭要等对端/空闲轮询收敛，给一个有界窗口而不是固定 2s。
  fd_after=$(fd_count "$PROXY_PID")
  settle_ms=0
  while [ "$fd_after" -gt $((fd_before + 20)) ] && [ "$settle_ms" -lt 12000 ]; do
    sleep 0.2
    settle_ms=$((settle_ms + 200))
    fd_after=$(fd_count "$PROXY_PID")
  done
  rss=$(ps -o rss= -p "$PROXY_PID" 2>/dev/null | tr -d ' ')
  printf '  第 %s 轮：%s ms，FD %s→%s（收敛 %s ms），RSS %s KB\n' "$round" "$((t1 - t0))" "$fd_before" "$fd_after" "$settle_ms" "${rss:-?}"
  if kill -0 "$PROXY_PID" 2>/dev/null; then ok "第 $round 轮进程存活"; else bad "第 $round 轮进程已崩溃"; fi
  if [ "$fd_after" -le $((fd_before + 20)) ]; then
    ok "第 $round 轮 FD 回落（+$((fd_after - fd_before))，${settle_ms} ms 内）"
  else
    bad "第 $round 轮 FD 未回落（${fd_before}→${fd_after}，等待 12s）"
  fi
  if stop_proxy; then ok "第 $round 轮 SIGINT 10s 内退出"; else bad "第 $round 轮 SIGINT 超时，已 SIGKILL"; fi
  if nc -z 127.0.0.1 "$MIXED_PORT" 2>/dev/null; then bad "第 $round 轮停止后端口仍被占用"; else ok "第 $round 轮停止后端口已释放"; fi
  round=$((round + 1))
done

# ---------- 2. 端口冲突 ----------
note "2) 端口冲突：第二个实例必须报错退出"
if start_proxy "$OUT/profiles/stress.surge"; then
  ok "第一个实例已监听 $MIXED_PORT"
  second_log="$OUT/conflict.log"
  "$TFCTL" run --profile "$OUT/profiles/stress.surge" >"$second_log" 2>&1
  second_status=$?
  if [ "$second_status" -ne 0 ]; then ok "第二个实例退出码 $second_status"; else bad "第二个实例居然启动成功（退出码 0）"; fi
  if grep -q "already in use" "$second_log"; then
    ok "错误文案可读：$(grep -m1 "already in use" "$second_log" | cut -c1-90)"
  else
    bad "错误文案缺少 already in use（见 ${second_log}）"
  fi
  stop_proxy || bad "冲突测试后第一个实例无法停止"
else
  bad "端口冲突测试无法启动基础实例（见 $OUT/proxy.log）"
fi

# ---------- 3. 上游不可达 ----------
note "3) 上游不可达：HTTP 应快速 502，进程存活"
gen_profile "$OUT/profiles/dead.surge" '[Proxy]
Dead = http, 127.0.0.1, 9

[Rule]
FINAL,Dead'
if start_proxy "$OUT/profiles/dead.surge"; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "http://127.0.0.1:$MIXED_PORT" http://upstream.invalid/ 2>/dev/null || true)
  [ -z "$code" ] && code="000"
  case "$code" in
    502|000) ok "上游不可达返回 $code" ;;
    *) bad "上游不可达返回 ${code}（期望 502/000）" ;;
  esac
  if kill -0 "$PROXY_PID" 2>/dev/null; then ok "进程存活"; else bad "进程在失败路径上崩溃"; fi
  stop_proxy || true
else
  bad "dead 配置未能启动（见 $OUT/proxy.log）"
fi

# ---------- 4. TLS 失败 ----------
note "4) TLS 失败：CONNECT 到已关闭端口，进程存活且 FD 不累积"
if start_proxy "$OUT/profiles/stress.surge"; then
  curl -s -o /dev/null --max-time 8 -x "http://127.0.0.1:$MIXED_PORT" https://127.0.0.1:1/ >/dev/null 2>&1
  tls_status=$?
  if [ "$tls_status" -ne 0 ]; then ok "TLS/CONNECT 失败按预期返回错误（curl=${tls_status}）"; else bad "TLS 失败却被当作成功"; fi
  sleep 1
  if kill -0 "$PROXY_PID" 2>/dev/null; then ok "进程存活"; else bad "TLS 失败路径崩溃"; fi
  before_fd=$(fd_count "$PROXY_PID")
  sleep 2
  after_fd=$(fd_count "$PROXY_PID")
  if [ "$after_fd" -le $((before_fd + 5)) ]; then ok "失败连接 FD 未累积（${before_fd}→${after_fd}）"; else bad "失败连接 FD 累积（${before_fd}→${after_fd}）"; fi
  stop_proxy || bad "TLS 测试后无法停止代理"
else
  bad "TLS 测试无法启动代理"
fi

# ---------- 5. 残留 ----------
note "5) 残留检查"
left=$(pgrep -f "$OUT/profiles/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$left" = 0 ]; then ok "无残留 tfctl 进程"; else bad "仍有 $left 个 tfctl 进程残留"; pgrep -fl "$OUT/profiles/" | sed 's/^/      /'; fi
if nc -z 127.0.0.1 "$MIXED_PORT" 2>/dev/null; then bad "压测端口 $MIXED_PORT 仍在监听"; else ok "压测端口已释放"; fi

note "汇总：PASS=$PASSES FAIL=${FAILED}（产物：${OUT}）"
if [ "$FAILED" -eq 0 ]; then exit 0; else exit 1; fi
