#!/bin/sh
set -eu

# The scoped parallelism runtime (#1164): RFC-0003 implementation step 5, the
# bounded scheduler and scope-exit drain for the C11 Stage 2 host target,
# before any compiler emits a call to it. `par` is still refused with E2S154;
# #1166 owns the lowering.
#
# What this proves, and how:
#
#   - driver.c runs each fixture many times on 1, 2 and 4 workers and requires
#     one observation from all of them. expected.stdout pins that observation,
#     so a fixture that silently stopped running is as visible as one that
#     failed.
#   - check-model.mjs runs the accepted bounded model on the same programs and
#     requires the same scope outcome, primary failure and per-task joins.
#   - The driver runs again under ThreadSanitizer and must report no race. A
#     canary race through the runtime's own threads must be reported, so a
#     clean run means the sanitizer was watching.
#   - A mutant runtime whose primary panic is not the earliest spawned one must
#     fail the 1,000-run precedence section, so that section is not vacuous.
#   - The header declares exactly the five RFC-0003 anchors, and the runtime
#     has one place that emits them.

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/concurrency/runtime"
RUNTIME="$ROOT/bootstrap/stage2"
CC=${CC:-cc}
ASSERT_CONTEXT='concurrency runtime'
. "$ROOT/tests/assertions/assert.sh"

command -v "$CC" >/dev/null 2>&1 ||
    assert_fail "a C11 compiler is required"
command -v node >/dev/null 2>&1 ||
    assert_fail "node is required to run the accepted model"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-concurrency-runtime.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

# --- The trace vocabulary -------------------------------------------------

anchors=$(awk '
    /^typedef enum \{$/ { block = ""; inside = 1; next }
    inside && /^\} KofunParAnchor;$/ { print block; exit }
    inside && /^    KOFUN_PAR_[A-Z_]+ = [0-9]+,?$/ {
        sub(/^    /, ""); sub(/ = .*/, ""); block = block $0 " "
    }
' "$RUNTIME/scoped_parallel_v1.h")
assert_eq "anchors the header declares" "$anchors" \
    "KOFUN_PAR_SCOPE_ENTER KOFUN_PAR_TASK_SPAWN KOFUN_PAR_TASK_JOIN_EXPLICIT KOFUN_PAR_TASK_JOIN_SCOPE_EXIT KOFUN_PAR_SCOPE_EXIT "
emitters=$(grep -c -- '->trace(' "$RUNTIME/scoped_parallel_v1.c" || true)
assert_num "places in the runtime that call the trace callback" "$emitters" -eq 1
printf '%s\n' 'PASS: the runtime declares the five RFC-0003 anchors and emits them in one place'

# --- Builds ---------------------------------------------------------------

build() {
    name=$1
    runtime_dir=$2
    shift 2
    "$CC" -std=c11 -Wall -Wextra -Werror -pedantic "$@" \
        -I"$runtime_dir" \
        "$runtime_dir/scoped_parallel_v1.c" \
        "$CASES/driver.c" \
        -pthread \
        -o "$WORK/$name"
}

# Runs a build and keeps its exit status. Some kernels map memory where
# ThreadSanitizer cannot shadow it ("unexpected memory mapping"); that is the
# host refusing the sanitizer, not the runtime racing, so it is retried once
# with address randomization off. Anything else stands.
run_driver() {
    name=$1
    shift
    run_status=0
    "$WORK/$name" "$@" >"$WORK/$name.stdout" 2>"$WORK/$name.stderr" ||
        run_status=$?
    if grep -q 'unexpected memory mapping' "$WORK/$name.stderr" &&
        command -v setarch >/dev/null 2>&1; then
        run_status=0
        setarch "$(uname -m)" -R "$WORK/$name" "$@" \
            >"$WORK/$name.stdout" 2>"$WORK/$name.stderr" || run_status=$?
    fi
}

check_clean_run() {
    name=$1
    if test "$run_status" -ne 0; then
        sed 's/^/  /' "$WORK/$name.stderr" >&2
        assert_fail "$name build exited $run_status"
    fi
    assert_file_empty "$name stderr" "$WORK/$name.stderr"
    if ! cmp -s "$CASES/expected.stdout" "$WORK/$name.stdout"; then
        diff "$CASES/expected.stdout" "$WORK/$name.stdout" >&2 || true
        assert_fail "$name observation differs from expected.stdout"
    fi
    printf '%s\n' "PASS: $name build matches expected.stdout"
}

build strict "$RUNTIME" -O2
run_driver strict
check_clean_run strict

node "$CASES/check-model.mjs" <"$WORK/strict.stdout"

# --- ThreadSanitizer ------------------------------------------------------

build tsan "$RUNTIME" -O1 -g -fno-omit-frame-pointer -fsanitize=thread
TSAN_OPTIONS='halt_on_error=1 exitcode=66'
export TSAN_OPTIONS

run_driver tsan --race-canary
assert_num "ThreadSanitizer exit status on the canary race" "$run_status" -eq 66
assert_grep "ThreadSanitizer report on the canary race" \
    -F 'WARNING: ThreadSanitizer: data race' "$WORK/tsan.stderr"
printf '%s\n' 'PASS: ThreadSanitizer reports a race through the runtime threads'

run_driver tsan
check_clean_run tsan
printf '%s\n' 'PASS: no data race on any accepted fixture under ThreadSanitizer'

# --- The precedence section is not vacuous --------------------------------

mkdir "$WORK/mutant-runtime"
cp "$RUNTIME/scoped_parallel_v1.h" "$WORK/mutant-runtime/"
sed 's|if (report->primary == KOFUN_PAR_NO_TASK) { /\* primary: earliest \*/|if (true) { /* mutant: the last panic in spawn order */|' \
    "$RUNTIME/scoped_parallel_v1.c" >"$WORK/mutant-runtime/scoped_parallel_v1.c"
if cmp -s "$RUNTIME/scoped_parallel_v1.c" "$WORK/mutant-runtime/scoped_parallel_v1.c"; then
    assert_fail "the precedence mutation no longer applies; update it with the runtime"
fi
build mutant "$WORK/mutant-runtime" -O2
run_driver mutant
assert_num "mutant exit status" "$run_status" -eq 1
assert_grep "mutant failure section" \
    -F 'FAIL [panic-precedence]' "$WORK/mutant.stderr"
printf '%s\n' 'PASS: a runtime that names a later panic primary fails the precedence section'

printf '%s\n' \
    'PASS: scoped parallelism runtime joins, drains, applies panic-over-cancellation precedence, and agrees with the accepted model'
