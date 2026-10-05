#!/bin/sh
set -eu

# #1244, the E355 slice. A direct `return` of a `read` or `edit` authority
# parameter escapes a frame-bounded borrow as an owned value, and is refused
# E355 before carrier lowering. The controls keep the neighbouring behaviour:
# a borrow used inside an expression is not a direct return, and returning a
# whole `take` parameter is an allowed transfer that reaches the carrier
# refusal it always did.
#
# Every fixture is a whole program driven through the same `bin/kofun build`
# a user runs. A refusal exits with its fixed status, prints exactly one line,
# matches its golden, and publishes no C artifact.

root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cases="$root/tests/conformance/authority-affine-state"
work=${TMPDIR:-/tmp}/kofun-authority-affine-state.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"
ASSERT_CONTEXT='authority affine state'
. "$root/tests/assertions/assert.sh"

KOFUN="$root/bin/kofun"

refusals='
read_return
edit_return
expression_use
take_return
'

for stem in $refusals; do
    expected_exit=1
    test "$stem" = take_return && expected_exit=3
    set +e
    "$KOFUN" build "$cases/$stem.kofun" -o "$work/$stem.bin" \
        --emit-c "$work/$stem.c" >"$work/$stem.actual" 2>&1
    status=$?
    set -e
    test "$status" -eq "$expected_exit" ||
        fail "$stem exited $status instead of $expected_exit"
    test "$(wc -l <"$work/$stem.actual" | tr -d ' ')" -eq 1 ||
        fail "$stem printed more than one line"
    cmp "$cases/$stem.stderr" "$work/$stem.actual" ||
        fail "$stem diagnostic differs from its golden"
    test ! -e "$work/$stem.c" ||
        fail "$stem committed a C artifact"
done

printf '%s\n' \
    'PASS: a direct return of a read/edit authority parameter refuses E355 before carrier lowering, and the expression and take controls are unchanged'
