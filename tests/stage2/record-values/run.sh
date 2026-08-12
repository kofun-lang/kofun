#!/bin/sh
set -eu

# #1356. A `let` binding with no annotation whose initializer is a call
# returning a nominal record.
#
# The gate asserts three things, and the third is the one a golden alone would
# miss. Running the program proves the field values; compiling its C with the
# same strict flags the toolchain uses proves the program is buildable at all —
# which is exactly what failed before, since the compiler exited 0 and left
# `cc` to report `int64_t k_b1 = kofun_fn_origin();`. The emitted carrier is
# then read directly, because a future lowering could produce a correct program
# by some other route and this gate is about *which* carrier the binding gets.

root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
fixtures="$root/tests/stage2/record-values"
work=${TMPDIR:-/tmp}/kofun-stage2-record-values.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"
ASSERT_CONTEXT='stage2 record values'
. "$root/tests/assertions/assert.sh"

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    echo "record-values: a C11 compiler is required" >&2
    exit 1
fi

. "$root/bootstrap/stage2/build.sh"
kofun_stage2_build "$root" "$work/kofun-stage2"

executes() {
    stem=$1
    "$work/kofun-stage2" "$fixtures/$stem.kofun" \
        "$work/$stem.c" "$work/$stem.ir" "$work/$stem.tokens" \
        >"$work/$stem.compile" 2>"$work/$stem.compile.stderr" ||
        assert_fail "$stem did not compile: $(cat "$work/$stem.compile.stderr")"
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I "$root/unicode" "$work/$stem.c" -o "$work/$stem.bin" ||
        assert_fail "$stem emitted C that a strict C11 compiler rejects"
    "$work/$stem.bin" >"$work/$stem.stdout"
    cmp "$fixtures/$stem.stdout" "$work/$stem.stdout" ||
        assert_fail "$stem differs from its golden"
}

executes inferred_binding
executes annotated_binding

# The carrier itself. Both bindings hold a record, so neither may be declared
# as a scalar; a `KofunRecord_Point` here is the whole of the fix.
assert_grep 'the inferred binding declares a record carrier' \
    -Eq -- 'KofunRecord_Point k_b[0-9]+ = kofun_fn_origin\(\);' \
    "$work/inferred_binding.c"
assert_grep 'the second inferred binding declares its own record carrier' \
    -Eq -- 'KofunRecord_Point k_b[0-9]+ = kofun_fn_shifted\(' \
    "$work/inferred_binding.c"
assert_not_grep 'no inferred record binding is declared as a scalar' \
    -Eq -- 'int64_t k_b[0-9]+ = kofun_fn_(origin|shifted)\(' \
    "$work/inferred_binding.c"

# The annotated spelling emits the same carrier. The two paths derive it from
# the same helper, and this is what says so rather than assuming it.
assert_grep 'the annotated binding declares the same carrier' \
    -Eq -- 'KofunRecord_Point k_b[0-9]+ = kofun_fn_origin\(\);' \
    "$work/annotated_binding.c"

printf '%s\n' \
    'PASS: an inferred binding from a record-returning call declares its record carrier, builds under strict C11, and agrees with the annotated spelling'
