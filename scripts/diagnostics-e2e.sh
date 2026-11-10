#!/bin/bash
# P3 diagnostics end-to-end test.
#
# Drives the real CLI over a real profile plus on-disk rule-set files, so every
# verdict the editor shows is also provable from a terminal:
#   * a live rule-set decides traffic through its members
#   * an empty rule-set and an unavailable source are reported as never-match
#   * a suffix rule shadowed by an earlier suffix is reported with its source
#   * a profile with no dead rules prints the all-clear line
#
# Usage: scripts/diagnostics-e2e.sh   (needs .build/debug/leapin; LEAPIN_BIN= to override)
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=${LEAPIN_BIN:-.build/debug/leapin}
[ -x "$BIN" ] || { echo "build first: swift build --product leapin"; exit 1; }

WORK=$(mktemp -d -t leapin-diag.XXXXXX)
export LEAPIN_PROFILE_ROOT="$WORK/store"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }
has() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

mkdir -p "$WORK/rules"
printf 'DOMAIN-SUFFIX,ads.example,REJECT\n' > "$WORK/rules/live.list"
: > "$WORK/rules/empty.list"

cat > "$WORK/mixed.surge" <<EOF
[General]
loglevel = warning

[Rule]
RULE-SET,$WORK/rules/live.list,PROXY
RULE-SET,$WORK/rules/empty.list,REJECT
RULE-SET,$WORK/rules/missing.list,REJECT
DOMAIN-SUFFIX,example.com,DIRECT
DOMAIN-SUFFIX,api.example.com,PROXY
FINAL,DIRECT
EOF

echo "---- explain + diagnose"
OUT=$("$BIN" rules ads.example --profile "$WORK/mixed.surge" --diagnose 2>&1)
RC=$?
[ $RC -eq 0 ] && ok "rules --diagnose exits 0" || bad "rules --diagnose exited $RC"
if has "$OUT" "策略：PROXY"; then ok "live rule-set decides through its member"; else bad "live rule-set did not decide"; fi
if has "$OUT" "命中规则：RULE-SET," && has "$OUT" "live.list"; then ok "matched rule names the rule-set"; else bad "matched rule lost the rule-set name"; fi
if has "$OUT" "永不命中规则：3 条"; then ok "three dead rules reported"; else bad "expected 3 dead rules"; fi

empty=$(printf '%s\n' "$OUT" | grep -c "没有可命中的成员规则")
[ "$empty" -eq 2 ] && ok "empty and unavailable sets flagged" || bad "expected 2 empty-set findings, got $empty"
if has "$OUT" "被第 4 条"; then ok "shadowed suffix names its source"; else bad "shadowed suffix not explained"; fi
if has "$OUT" "missing.list"; then ok "unavailable source is visible"; else bad "unavailable source vanished"; fi

echo "---- clean profile"
cat > "$WORK/clean.surge" <<EOF
[General]
loglevel = warning

[Rule]
RULE-SET,$WORK/rules/live.list,PROXY
DOMAIN-SUFFIX,example.com,DIRECT
FINAL,DIRECT
EOF
OUT2=$("$BIN" rules example.com --profile "$WORK/clean.surge" --diagnose 2>&1)
if has "$OUT2" "没有永不命中的规则"; then ok "clean profile reports no dead rules"; else bad "clean profile produced a false alarm"; fi
if has "$OUT2" "命中规则：DOMAIN-SUFFIX,example.com,DIRECT"; then ok "clean profile routes as written"; else bad "clean profile routing changed"; fi

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
