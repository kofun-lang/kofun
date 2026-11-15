#!/usr/bin/env sh
set -eu

# RFC-0020 child 1 (#1754): `pure` on a callable parameter.
#
# The parenthesised and bare spellings parse in both halves of the Stage 2
# pair, the one-bit requirement reaches the scope HIR as `Fn[pure]` beside the
# unannotated `Fn`, the one subsumption rule (`pure (A) -> R` where `(A) -> R`
# is expected) accepts, and `pure` stays an ordinary identifier everywhere else
# (x30, x14, x15, x31). A call that supplies an argument to a `pure` parameter
# refuses with the one registered "specified but not implemented" code until
# #1756 supplies the argument rule, so an impure callable cannot pass
# unchecked in between.
#
# Positives build under strict C11 and ASan/UBSan, and both halves must agree
# on outcome, emitted C, tokens, and scope HIR. Refusals exit 1, write no C,
# and match their golden.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/callable-purity"
CC=${CC:-cc}
WORK=${KOFUN_CALLABLE_PURITY_WORK:-"$ROOT/build/callable-purity"}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */callable-purity|*/callable-purity.*) ;;
    *) fail "work directory must end in callable-purity[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

COMPILER="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$COMPILER"

for source in "$CASES"/*.kofun; do
    stem=$(basename "${source%.kofun}")
    golden="$CASES/$stem.stderr"
    test -f "$golden" || continue
    output="$WORK/$stem.c"
    set +e
    "$COMPILER" --compile-outcome "$source" "$output" \
        "$WORK/$stem.ir" "$WORK/$stem.tokens" >"$WORK/$stem.actual" 2>"$WORK/$stem.internal"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$stem exited $status instead of 1"
    test ! -s "$WORK/$stem.internal" || fail "$stem wrote internal stderr"
    test ! -e "$output" || fail "$stem emitted C"
    cmp "$golden" "$WORK/$stem.actual" || fail "$stem diagnostic differs from its golden"
    printf '%s\n' "PASS: refusal $stem"
done

for source in "$CASES"/*.kofun; do
    stem=$(basename "${source%.kofun}")
    test -f "$CASES/$stem.stderr" && continue
    test -f "$CASES/$stem.ir" ||
        fail "$stem has neither a refusal golden nor an IR golden"
    test -f "$CASES/$stem.stdout" ||
        fail "$stem has no observation golden"
    "$COMPILER" --compile-outcome "$source" "$WORK/$stem.c" \
        "$WORK/$stem.ir" "$WORK/$stem.tokens" >"$WORK/$stem.actual"
    test -s "$WORK/$stem.c" || fail "the positive $stem emitted no C"
    cmp "$CASES/$stem.ir" "$WORK/$stem.ir" ||
        fail "$stem scope HIR differs from its golden"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" "$WORK/$stem.c" -o "$WORK/$stem"
    "$WORK/$stem" >"$WORK/$stem.stdout"
    cmp "$CASES/$stem.stdout" "$WORK/$stem.stdout" ||
        fail "the positive $stem observation changed"
    printf '%s\n' "PASS: positive $stem (strict C11)"
    "$CC" -std=c11 -O1 -g -fno-omit-frame-pointer \
        -fsanitize=address,undefined -fno-sanitize-recover=all \
        -I"$ROOT/bootstrap/stage2" "$WORK/$stem.c" -o "$WORK/$stem.sanitized"
    ASAN_OPTIONS=detect_leaks=1 "$WORK/$stem.sanitized" \
        >"$WORK/$stem.sanitized.stdout"
    cmp "$CASES/$stem.stdout" "$WORK/$stem.sanitized.stdout" ||
        fail "the sanitized positive $stem observation changed"
    printf '%s\n' "PASS: positive $stem (ASan/UBSan, no leaks)"
done

node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" "$CASES"/*.kofun

printf '%s\n' 'PASS: pure callable type parsing, identity, subsumption, and the not-yet refusal'
