#!/bin/bash
# Unit tests for CI, in a form a hang cannot hide in.
#
# The suite once ate the job's whole 15 minutes and produced a log that named no
# test at all: `swift test 2>&1 | tail -40` keeps every line in tail's buffer
# until the process exits, and the runner then killed the job at its own
# timeout. Two guards here, both about making the next hang cheap to explain:
#
#   1. every line is streamed as it arrives, so the log always ends on the test
#      that is running right now;
#   2. if the log stops growing, a stack sample of the stuck xctest process is
#      printed before the run is killed, so the cause is in the log instead of
#      in a second round trip.
#
# Knobs, all optional (they also let this script be exercised without the suite):
#   CI_TEST_COMMAND          what to run, default "swift test"
#   CI_TEST_LOG              log path, default $TMPDIR/leapin-ci-test.log
#   CI_TEST_QUIET_SECONDS    no output for this long counts as hung, default 150
#   CI_TEST_DEADLINE_SECONDS hard stop, default 720 (job timeout is 15 min)
set -uo pipefail
cd "$(dirname "$0")/.."

cmd="${CI_TEST_COMMAND:-swift test}"
# Kept out of the repository: the log only exists so this script can tell
# "still working" from "stopped writing", and CI already has every line on stdout.
tmp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
log="${CI_TEST_LOG:-${tmp_root%/}/leapin-ci-test.log}"
quiet="${CI_TEST_QUIET_SECONDS:-150}"
deadline="${CI_TEST_DEADLINE_SECONDS:-720}"
interval=5

mkdir -p "$(dirname "${log}")"
: > "${log}"

started=${SECONDS}
# Job control gives the run its own process group, so stopping it takes the
# whole tree (`swift test` plus the xctest processes it spawned) instead of
# leaving orphans behind the log.
set -m
bash -c "${cmd}" > >(tee -a "${log}") 2>&1 &
pid=$!
set +m
echo "ci-test: ${cmd} (pid ${pid})"
echo "ci-test: log ${log}, quiet limit ${quiet}s, deadline ${deadline}s"

# The cases run in xctest processes that `swift test` spawns, so the driver's own
# pid is not enough: it is usually just waiting on a child.
descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        echo "${child}"
        descendants "${child}"
    done
}

sample_pids() {
    # Deepest work usually sits in a child (`swift test` only waits), so take the
    # descendants first and keep the driver as a last resort. Three is enough:
    # past that the samples are all the same shape and only make the log longer.
    local p count=0 command
    for p in $(descendants "${pid}"); do
        command=$(ps -o command= -p "${p}" 2>/dev/null)
        # The log writer and this script are not part of the suite: sampling them
        # spends a second each and pushes the interesting stack out of the log.
        case "${command}" in
            "tee "*) continue ;;
            *ci-test.sh*) continue ;;
        esac
        echo "${p}"
        count=$((count + 1))
        [ "${count}" -ge 3 ] && return 0
    done
    [ -n "${pid}" ] && echo "${pid}"
}

report_hang() {
    local size=$1 p sample_file
    echo "::error::no output for $((SECONDS - last_growth))s — the suite is hung, not slow"
    echo "---- ci-test: last test lines (log is ${size} bytes) ----"
    tail -15 "${log}" 2>/dev/null || true
    echo "---- ci-test: processes ----"
    ps -axo pid,ppid,etime,%cpu,state,command | awk -v p="${pid}" '$1==p || $2==p' || true
    sample_file="${log}.sample.$$"
    for p in $(sample_pids); do
        echo "---- ci-test: stack sample of pid ${p} ($(ps -o command= -p "${p}" 2>/dev/null | cut -c1-120)) ----"
        sample "${p}" 1 -file "${sample_file}" >/dev/null 2>&1 || continue
        sed -n '1,120p' "${sample_file}"
    done
    rm -f "${sample_file}"
}

test_pids() {
    local p
    descendants "${pid}"
    [ -n "${pid}" ] && echo "${pid}"
}

stop_run() {
    # The group kill is the broad stroke, but xctest can outlive SIGTERM (it
    # installs handlers of its own) and a survivor keeps the runner's log open,
    # so the pids are also named individually and escalated to SIGKILL.
    local p tree
    tree=$(test_pids)
    kill -TERM -"${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
    for p in ${tree}; do kill -TERM "${p}" 2>/dev/null || true; done
    sleep 3
    kill -KILL -"${pid}" 2>/dev/null || true
    for p in ${tree}; do kill -KILL "${p}" 2>/dev/null || true; done
    # Anything spawned in the last few seconds is caught here.
    for p in $(test_pids); do kill -KILL "${p}" 2>/dev/null || true; done
    wait "${pid}" 2>/dev/null || true
}

last_size=-1
last_growth=${SECONDS}
outcome=""

while :; do
    if ! kill -0 "${pid}" 2>/dev/null; then
        wait "${pid}"
        outcome=$?
        break
    fi
    size=$(wc -c < "${log}" | tr -d ' ')
    now=${SECONDS}
    if [ "${size}" -gt "${last_size}" ]; then
        last_size=${size}
        last_growth=${now}
    elif [ $((now - last_growth)) -ge "${quiet}" ]; then
        report_hang "${size}"
        outcome=124
        break
    fi
    if [ $((now - started)) -ge "${deadline}" ]; then
        echo "::error::suite still running after ${deadline}s — stopping it"
        report_hang "${size}"
        outcome=124
        break
    fi
    sleep "${interval}"
done

if [ "${outcome}" -eq 124 ]; then
    stop_run
    echo "ci-test: killed the hung run after $((SECONDS - started))s"
else
    echo "ci-test: exited ${outcome} after $((SECONDS - started))s, $(wc -l < "${log}" | tr -d ' ') log lines"
fi
exit "${outcome}"
