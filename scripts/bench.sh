#!/bin/bash
# TouchFlow 性能基准（P4）。只用系统自带工具：swift / awk / perl / curl / lsof / nc / dig / python3。
#
# 用法：
#   scripts/bench.sh                      # 全量（首次 release 构建 tfctl，约 1-3 分钟）
#   TF_BENCH_SKIP_BUILD=1 scripts/bench.sh
#   TF_BENCH_RULES="1000 10000 100000" scripts/bench.sh
#
# 使用独立 scratch（--scratch-path .build-bench），不与 GUI 的 .build 抢锁。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${TF_BENCH_SCRATCH:-"$ROOT/.build-bench"}
OUT=${TF_BENCH_OUT:-"$ROOT/.bench"}
TFCTL="$SCRATCH/release/tfctl"
RULES_SIZES=${TF_BENCH_RULES:-"1000 10000 100000"}
MIXED_PORT=${TF_BENCH_MIXED_PORT:-17890}
HTTP_PORT=$((MIXED_PORT + 1))
SOCKS_PORT=$((MIXED_PORT + 2))
ORIGIN_PORT=${TF_BENCH_ORIGIN_PORT:-18080}
PROXY_PID=""
ORIGIN_PID=""

note() { printf '\n== %s\n' "$*"; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000'; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
  [ -n "$ORIGIN_PID" ] && kill "$ORIGIN_PID" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$OUT/profiles"

# ---------- 1. 构建 ----------
if [ -z "${TF_BENCH_SKIP_BUILD:-}" ]; then
  note "release 构建 tfctl（scratch: ${SCRATCH}）"
  ( cd "$ROOT" && swift build -c release --product tfctl --scratch-path "$SCRATCH" 2>&1 | grep -E 'error:' | head -20 || true )
fi
[ -x "$TFCTL" ] || { echo "缺少可执行文件 ${TFCTL}（先跑一次不带 TF_BENCH_SKIP_BUILD 的 bench.sh）" >&2; exit 1; }

# ---------- 2. 规则生成 ----------
gen_profile() { # $1=规则数 $2=输出文件
  local n=$1 path=$2
  {
    echo "[General]"
    echo "mixed-listen = :$MIXED_PORT"
    echo "http-listen = :$HTTP_PORT"
    echo "socks5-listen = :$SOCKS_PORT"
    echo "loglevel = warning"
    echo
    echo "[Rule]"
    awk -v n="$n" 'BEGIN {
      for (i = 0; i < n; i++) {
        k = i % 5
        if (k == 0) printf "DOMAIN-SUFFIX,host%d.example.com,DIRECT\n", i
        else if (k == 1) printf "DOMAIN,exact%d.example.net,DIRECT\n", i
        else if (k == 2) printf "DOMAIN-KEYWORD,kw%d,DIRECT\n", i
        else if (k == 3) printf "DOMAIN-SUFFIX,sub%d.cdn.example.org,DIRECT\n", i
        else printf "DOMAIN,host%d.example.com,DIRECT\n", i
      }
      print "FINAL,DIRECT"
    }'
  } > "$path"
}

# 单次 wall time（毫秒），取 3 次最小值；含进程启动 + 规则加载 + 1 次 decide。
min_ms() { # $@ = 命令
  local best=999999 d s e
  for _ in 1 2 3; do
    s=$(now_ms)
    "$@" >/dev/null 2>&1 || true
    e=$(now_ms)
    d=$((e - s))
    if [ "$d" -lt "$best" ]; then best=$d; fi
  done
  echo "$best"
}

note "规则引擎：加载 + 单次 decide（wall clock，3 次取最小）"
printf '%-10s %10s %12s %14s\n' "规则数" "总耗时ms" "启动基线ms" "净增ms/万条"
gen_profile 0 "$OUT/profiles/rules-0.surge"
base=$(min_ms "$TFCTL" rules example.com --profile "$OUT/profiles/rules-0.surge")
printf '%-10s %10s %12s %14s\n' 0 "$base" "$base" "-"
for n in $RULES_SIZES; do
  p="$OUT/profiles/rules-$n.surge"
  [ -f "$p" ] || gen_profile "$n" "$p"
  ms=$(min_ms "$TFCTL" rules example.com --profile "$p")
  net=$((ms - base))
  if [ "$net" -lt 0 ]; then net=0; fi
  denom=$n
  if [ "$denom" -le 0 ]; then denom=1; fi
  per=$(( net * 10000 / denom ))
  printf '%-10s %10s %12s %14s\n' "$n" "$ms" "$base" "$per"
done

# ---------- 2b. 规则 decide 延迟（10 万规则，2000 次，预热 100） ----------
note "10 万规则 p50/p95"
BIG_PROFILE="$OUT/profiles/rules-100000.surge"
[ -f "$BIG_PROFILE" ] || gen_profile 100000 "$BIG_PROFILE"
measure_line=$("$TFCTL" rules example.com --profile "$BIG_PROFILE" --measure 2000 | tail -1)
printf '%-24s %s\n' "10 万规则 p50/p95" "$measure_line"

# ---------- 3. AdBlock ----------
note "AdBlock：内置拦截列表（加载 + 单次判定）"
ms=$(min_ms "$TFCTL" adblock doubleclick.net)
printf '%-24s %10s\n' "内置列表 加载+判定ms" "$ms"
if ! [ -f "$OUT/profiles/abp-100k.txt" ]; then
  awk 'BEGIN { for (i = 0; i < 100000; i++) printf "||host%d.example.com^\n", i }' > "$OUT/profiles/abp-100k.txt"
fi
printf '%-24s %10s\n' "生成 ABP 列表条数" "$(wc -l < "$OUT/profiles/abp-100k.txt" | tr -d ' ')"

# ---------- 4. 并发短连接 ----------
note "并发短连接：100 并发 HTTP 经 mixed 端口到本地 origin"
ORIGIN_DIR="$OUT/origin"
mkdir -p "$ORIGIN_DIR"
printf 'ok\n' > "$ORIGIN_DIR/index.html"
python3 -m http.server "$ORIGIN_PORT" --bind 127.0.0.1 --directory "$ORIGIN_DIR" >"$OUT/origin.log" 2>&1 &
ORIGIN_PID=$!
sleep 1

gen_profile 1000 "$OUT/profiles/serve.surge"
"$TFCTL" run --profile "$OUT/profiles/serve.surge" >"$OUT/proxy.log" 2>&1 &
PROXY_PID=$!
ready=0
for _ in $(seq 1 50); do
  if nc -z 127.0.0.1 "$MIXED_PORT" 2>/dev/null; then ready=1; break; fi
  sleep 0.2
done
if [ "$ready" != 1 ]; then
  echo "代理未能在 10s 内监听 $MIXED_PORT" >&2
  tail -20 "$OUT/proxy.log" >&2
  exit 1
fi

fd_before=$(lsof -p "$PROXY_PID" 2>/dev/null | wc -l | tr -d ' ')
: > "$OUT/timings.txt"
t0=$(now_ms)
seq 1 100 | xargs -P 100 -I{} curl -s -o /dev/null -w '%{time_total}\n' \
  -x "http://127.0.0.1:$MIXED_PORT" "http://127.0.0.1:$ORIGIN_PORT/" >> "$OUT/timings.txt"
t1=$(now_ms)
fd_after=$(lsof -p "$PROXY_PID" 2>/dev/null | wc -l | tr -d ' ')

p50=$(sort -n "$OUT/timings.txt" | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
p95=$(sort -n "$OUT/timings.txt" | awk '{a[NR]=$1} END {print a[int(NR*0.95)]}')
printf '%-24s %10s\n' "100 请求总耗时ms" "$((t1 - t0))"
printf '%-24s %10ss\n' "p50" "$p50"
printf '%-24s %10ss\n' "p95" "$p95"
printf '%-24s %10s\n' "FD（前/后）" "$fd_before/$fd_after"

# DNS：默认监听 5354 常被用户自己的 DNS 占用，基准用独立端口 + 独立实例。
DNS_PORT=${TF_BENCH_DNS_PORT:-15354}
DNS_MIXED=${TF_BENCH_DNS_MIXED_PORT:-17899}
if nc -z 127.0.0.1 "$DNS_PORT" 2>/dev/null; then
  note "DNS：端口 $DNS_PORT 已被占用，跳过"
elif ! have dig; then
  note "DNS：缺少 dig，跳过"
else
  note "DNS：冷/热查询（UDP 端口 ${DNS_PORT} / 独立实例端口 ${DNS_MIXED}）"
  cat > "$OUT/profiles/dns.yaml" <<EOF
mixed-port: $DNS_MIXED
mode: rule
dns:
  enable: true
  listen: 127.0.0.1:$DNS_PORT
  nameserver:
    - 223.5.5.5
rules:
  - MATCH,DIRECT
EOF
  "$TFCTL" run --profile "$OUT/profiles/dns.yaml" >"$OUT/dns-proxy.log" 2>&1 &
  DNS_PID=$!
  dns_ready=0
  for _ in $(seq 1 50); do
    if nc -zu -w1 127.0.0.1 "$DNS_PORT" 2>/dev/null; then dns_ready=1; break; fi
    sleep 0.2
  done
  if [ "$dns_ready" != 1 ]; then
    echo "DNS 实例未在 10s 内监听 ${DNS_PORT}（见 ${OUT}/dns-proxy.log）"
  else
    domain="example.com"
    s=$(now_ms); first_ans=$(dig +time=2 +tries=1 @127.0.0.1 -p "$DNS_PORT" "$domain" A +short 2>/dev/null | sort || true); e=$(now_ms)
    printf '%-24s %10s\n' "首次查询ms" "$((e - s))"
    s=$(now_ms); second_ans=$(dig +time=2 +tries=1 @127.0.0.1 -p "$DNS_PORT" "$domain" A +short 2>/dev/null | sort || true); e=$(now_ms)
    printf '%-24s %10s\n' "缓存命中ms" "$((e - s))"
    if [ -z "$first_ans" ]; then
      printf '%-24s %10s\n' "缓存一致性" "no-answer(upstream?)"
    elif [ "$first_ans" = "$second_ans" ]; then
      printf '%-24s %10s\n' "缓存一致性" "same"
    else
      printf '%-24s %10s\n' "缓存一致性" "differs"
    fi
    kill -INT "$DNS_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$DNS_PID" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$DNS_PID" 2>/dev/null || true
    DNS_PID=""
  fi
fi

# ---------- 5. 停止 ----------
note "停止：SIGINT 后端口释放"
kill -INT "$PROXY_PID" 2>/dev/null || true
stopped=0
for _ in $(seq 1 50); do
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then stopped=1; break; fi
  sleep 0.2
done
if [ "$stopped" = 1 ]; then
  printf '%-24s %10s\n' "进程退出" "ok"
else
  printf '%-24s %10s\n' "进程退出" "TIMEOUT(>10s)"
  kill -9 "$PROXY_PID" 2>/dev/null || true
fi
PROXY_PID=""
if nc -z 127.0.0.1 "$MIXED_PORT" 2>/dev/null; then
  printf '%-24s %10s\n' "端口释放" "NO"
else
  printf '%-24s %10s\n' "端口释放" "yes"
fi

note "原始数据：${OUT}（profiles/ timings.txt proxy.log origin.log）"
