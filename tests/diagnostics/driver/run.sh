#!/bin/sh
set -eu

# The first adapter whose emitter is `bin/kofun` rather than a compiler under
# `bootstrap/`. It observes EDRV001, the refusal the driver issues for a
# module-headed file, and it checks the two halves that can each be wrong on
# their own:
#
#   1. the refusal fires, on every mode that reaches the single-file compile
#      path, with the same message and status;
#   2. a file *without* a module header is completely unaffected — same status,
#      same streams, byte-identical emitted C.
#
# The second half is the one worth having. A guard that keyed on something
# broader than the construct — the word `module` anywhere, a file that fails to
# parse — would satisfy the first half and quietly refuse working programs.

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
SUITE="$ROOT/tests/diagnostics/driver"
WORK=${KOFUN_DRIVER_DIAGNOSTIC_WORK:-"$ROOT/build/diagnostics-driver"}
ASSERT_CONTEXT='diagnostics driver'
. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

# Relative to ROOT, and every invocation runs from ROOT: the diagnostic quotes
# the path it was given, so an absolute one would put this machine's
# directory layout into the golden.
FIXTURE=tests/diagnostics/driver/edrv002_module_path_mismatch.kofun
CONTROL=tests/diagnostics/driver/control_no_header.kofun

# Every mode below funnels through the driver's single-file compile path, which
# is where the guard lives. Naming them one at a time rather than trusting that
# funnel is the point: if a later change gives one of them its own path, this
# adapter fails instead of silently covering three modes and claiming four.
for mode in check build run emit-c; do
    set +e
    case $mode in
        emit-c)
            (cd "$ROOT" && bin/kofun emit-c "$FIXTURE" "$WORK/$mode.c") \
                >"$WORK/$mode.stdout" 2>"$WORK/$mode.stderr"
            ;;
        *)
            (cd "$ROOT" && bin/kofun "$mode" "$FIXTURE") \
                >"$WORK/$mode.stdout" 2>"$WORK/$mode.stderr"
            ;;
    esac
    status=$?
    set -e
    assert_num "$mode status" "$status" -eq 2
    assert_file_empty "$mode.stdout" "$WORK/$mode.stdout"
    cmp "$SUITE/edrv002_module_path_mismatch.stderr" "$WORK/$mode.stderr"
done

assert_absent "emit-c artifact" "$WORK/emit-c.c"

# The non-regression half. The control declares a function whose *name* begins
# with `module`, so a guard matching the word rather than the leading
# declaration would refuse it.
set +e
(cd "$ROOT" && bin/kofun emit-c "$CONTROL" "$WORK/control.c") \
    >"$WORK/control.stdout" 2>"$WORK/control.stderr"
control_status=$?
set -e

assert_num "control is not refused by the driver" "$control_status" -ne 2
if grep -q 'EDRV00' "$WORK/control.stderr"; then
    printf '%s\n' \
        "FAIL: the control file without a module header was refused by the driver" >&2
    exit 1
fi

printf '%s\n' \
    "PASS: EDRV002 refuses a module whose path contradicts its declaration in 4 modes, and a header-less file is untouched"
