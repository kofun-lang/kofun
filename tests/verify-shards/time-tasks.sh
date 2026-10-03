#!/bin/sh
# Per-task wall time for `task verify` (#1684).
#
# The shard partition must be justified by a measurement rather than by task
# name, and go-task's `--parallel` gives no per-task timing. This runs the same
# tasks through the same `task` entry point under a bounded concurrency the
# caller chooses, and writes one `task<TAB>nanoseconds` row per task.
#
# It is reached by `bootstrap/stage2/verify-runner.sh` when
# `KOFUN_VERIFY_TASK_TIMES` names an output file, and it is the only reader of
# that seam. It is deliberately not part of `task verify`: measuring the whole
# lane is the multi-hour work `tests/pair-coverage/undefended.tsv` already
# records, and nothing in a normal run should pay for it.
#
# Usage: sh time-tasks.sh OUT_FILE JOBS TASK...
#
# JOBS is the same worker count the lane would use (`VERIFY_JOBS`). The rows are
# written sorted by task, so a re-run is a diff rather than a silent append.
set -eu

test "$#" -ge 3 || {
    printf '%s\n' 'usage: time-tasks.sh OUT_FILE JOBS TASK...' >&2
    exit 2
}

tt_out=$1
tt_jobs=$2
shift 2

case $tt_jobs in
    *[!0-9]*|'')
        printf 'time-tasks: JOBS must be a positive integer, got `%s`\n' "$tt_jobs" >&2
        exit 2
        ;;
esac

tt_work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-verify-times.XXXXXX")
trap 'rm -rf "$tt_work"' 0 1 2 15
: >"$tt_work/times"
: >"$tt_work/failed"

TASK_TIMES_OUT=$tt_out
TASK_TIMES_WORK=$tt_work
export TASK_TIMES_OUT TASK_TIMES_WORK

# `xargs -n1` hands one task name per invocation to the helper below. The
# recorded time is the child `task` process's wall time, and a failure is
# recorded rather than aborting the others: the partitions still need weights
# from the tasks that did run, and the seam is a measurement, not a gate.
printf '%s\n' "$@" |
    xargs -P "$tt_jobs" -n1 sh -c '
        tt_task=$1
        tt_start=$(date +%s%N)
        if ! task "$tt_task" >/dev/null 2>&1; then
            printf "%s\n" "$tt_task" >>"$TASK_TIMES_WORK/failed"
        fi
        tt_end=$(date +%s%N)
        printf "%s\t%s\n" "$tt_task" "$((tt_end - tt_start))" \
            >"$TASK_TIMES_WORK/$tt_task.time"
    ' sh

sort "$tt_work"/*.time >"$tt_out"

if test -s "$tt_work/failed"; then
    printf 'FAIL: time-tasks: these tasks did not finish cleanly; timings are partial:\n' >&2
    sed 's/^/  /' "$tt_work/failed" >&2
    exit 1
fi

printf 'PASS: recorded %s task timings to %s\n' "$(wc -l <"$tt_out" | tr -d ' ')" "$tt_out"
