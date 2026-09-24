#!/usr/bin/env sh
set -eu

# The Fixed[S] runtime entry points (#1661): RFC-0015's construction, clone,
# move and drop over the canonical Decimal payload, before any compiler calls
# them.
#
# The driver decides pass or fail itself, because the properties that matter
# are about allocation rather than output: every refused allocation is D004
# with an empty output, an unchanged input and nothing left live. It prints
# one line per section, compared here against a golden so that a section that
# silently stopped running is as visible as one that failed.
#
# It runs twice. The strict -O2 build is the configuration generated programs
# use; the ASan/UBSan build is what catches a double free, a use after move,
# or undefined behavior the seam's own counters cannot see.

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/decimal-fixed/runtime"
CC=${CC:-cc}
ASSERT_CONTEXT='decimal fixed runtime'
. "$ROOT/tests/assertions/assert.sh"

command -v "$CC" >/dev/null 2>&1 ||
    assert_fail "a C11 compiler is required"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-decimal-fixed.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

run_build() {
    name=$1
    shift
    "$CC" -std=c11 -Wall -Wextra -Werror -pedantic "$@" \
        -I"$ROOT/bootstrap/stage2" \
        "$CASES/fixed_runtime_test.c" \
        -o "$WORK/$name"
    run_status=0
    "$WORK/$name" >"$WORK/$name.stdout" 2>"$WORK/$name.stderr" ||
        run_status=$?
    if test "$run_status" -ne 0; then
        sed 's/^/  /' "$WORK/$name.stderr" >&2
        assert_fail "$name build exited $run_status"
    fi
    assert_file_empty "$name stderr" "$WORK/$name.stderr"
    cmp "$CASES/expected.stdout" "$WORK/$name.stdout" ||
        assert_fail "$name observation differs from expected.stdout"
    printf '%s\n' "PASS: $name"
}

run_build strict -O2
run_build sanitized -O1 -g -fno-omit-frame-pointer \
    -fsanitize=address,undefined -fno-sanitize-recover=all

printf '%s\n' \
    'PASS: Fixed[S] construct, clone, move and drop fail by status, release every temporary, and match kofun_decimal_round'
