#!/bin/sh
set -eu

clock_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$clock_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-clock-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'clock checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$clock_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$clock_dir/clock.kofun"
for declaration in \
    'let CLOCK_NANOSECONDS_PER_SECOND = 1000000000' \
    'type Clock =' \
    '| MonotonicClock' \
    '| RealtimeClock' \
    'type Instant = {' \
    'type Duration = {' \
    'type ManualClock = {' \
    'type ClockError =' \
    'fn clock_instant(' \
    'fn clock_duration(' \
    'fn clock_compare(' \
    'fn clock_elapsed(' \
    'fn clock_add(' \
    'fn clock_deadline_reached(' \
    'fn clock_manual(' \
    'fn clock_manual_now(' \
    'fn clock_manual_advance('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for error in InvalidInstantNanoseconds InvalidDuration DifferentClocks \
    EndBeforeStart ClockArithmeticOverflow
do
    grep -Fq "| $error" "$source_file" ||
        fail "missing typed Clock error: $error"
done

grep -Fq 'if !clock_same(left.clock, right.clock)' "$source_file" ||
    fail 'cross-clock comparison rejection is missing'
grep -Fq 'end.nanoseconds < start.nanoseconds' "$source_file" ||
    fail 'elapsed-time borrow is missing'
grep -Fq 'instant.seconds > CLOCK_INT_MAX - duration.seconds' \
    "$source_file" || fail 'deadline addition overflow check is missing'
grep -Fq 'clock.current = current' "$source_file" ||
    fail 'manual clock does not advance explicit state'

adapter="$clock_dir/linux_x86_64.kofun"
for declaration in \
    'let LINUX_CLOCK_REALTIME = 0' \
    'let LINUX_CLOCK_MONOTONIC = 1' \
    'type ClockReadError =' \
    'fn clock_read('
do
    grep -Fq "$declaration" "$adapter" ||
        fail "missing Linux adapter declaration: $declaration"
done
grep -Fq 'clock_now(clock_linux_id(clock))' "$adapter" ||
    fail 'Linux adapter does not use the existing safe clock_gettime wrapper'
if grep -R --include='*.kofun' -q \
    'trusted intrinsic\|__linux_syscall' "$clock_dir"
then
    fail 'Clock module bypasses the standard Linux ABI boundary'
fi

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical record/ADT source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S32]: record `Instant` has a field type outside the Stage 2 Int/Bool/Text slice' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

checkpoint="$clock_dir/tests/checkpoint.kofun"
expected="$clock_dir/tests/checkpoint.stdout"
"$repo_dir/bin/kofun" build "$checkpoint" \
    -o "$work/checkpoint-c11" \
    --emit-c "$work/checkpoint.c" >/dev/null
"$work/checkpoint-c11" >"$work/checkpoint.stdout"
cmp "$expected" "$work/checkpoint.stdout" ||
    fail 'Clock deterministic vectors differ'

[ "$(sed -n '8,11p' "$work/checkpoint.stdout" | tr '\n' ' ')" = \
    '-1 0 1 -3 ' ] || fail 'same-clock ordering or domain rejection differs'
[ "$(sed -n '15,19p' "$work/checkpoint.stdout" | tr '\n' ' ')" = \
    '-4 -3 -1 -5 0 ' ] || fail 'elapsed-time error decisions differ'
[ "$(sed -n '21,26p' "$work/checkpoint.stdout" | tr '\n' ' ')" = \
    '0 13 100000000 -5 0 9223372036854775807 ' ] ||
    fail 'addition carry or overflow boundary differs'
[ "$(sed -n '27,30p' "$work/checkpoint.stdout" | tr '\n' ' ')" = \
    '0 1 1 -3 ' ] || fail 'deadline decisions differ'
[ "$(sed -n '31,34p' "$work/checkpoint.stdout" | tr '\n' ' ')" = \
    '20 750000000 22 250000000 ' ] ||
    fail 'manual clock explicit-state projection differs'

printf 'clock value API and typed errors: PASS\n'
printf 'clock elapsed, deadline, and overflow vectors: PASS\n'
printf 'clock deterministic manual projection: PASS\n'
