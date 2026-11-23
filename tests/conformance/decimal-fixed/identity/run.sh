#!/usr/bin/env sh
set -eu

# The compiler-known `Fixed[S]` identity (#1250, RFC-0015). `S` is a literal
# scale in `0..6144`, normalizes by value (`Fixed[02]` is `Fixed[2]`), and two
# distinct scales are two distinct type identities. This is the first slice of
# the carrier. These fixtures deliberately initialize the type with an Int to
# observe the ordinary E2S15 mismatch after a valid scale, and use scope HIR
# to observe distinct identities.
#
# E408 owns a scale outside the profile or an argument that is not an integer
# literal. E2S150 keeps the argument-list shape (missing, surplus,
# unterminated). E2S152 keeps the Stage 2 instantiation budget of eight.
#
# The gate runs the C half, the Kofun half under the canonical interpreter, and
# compares outcome, emitted C, checkpoints and scope HIR for every source. A
# fixture that stopped being refused would fail the outcome comparison as well
# as its golden.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/decimal-fixed/identity"
CC=${CC:-cc}
WORK=${KOFUN_DECIMAL_FIXED_IDENTITY_WORK:-"$ROOT/build/decimal-fixed-identity"}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */decimal-fixed-identity|*/decimal-fixed-identity.*) ;;
    *) fail "work directory must end in decimal-fixed-identity[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"

COMPILER="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$COMPILER"

for source in "$CASES"/*.kofun; do
    stem=$(basename "${source%.kofun}")
    golden="$CASES/$stem.stderr"
    actual="$WORK/$stem.actual"
    output="$WORK/$stem.c"
    ir="$WORK/$stem.ir"
    tokens="$WORK/$stem.tokens"
    set +e
    "$COMPILER" --compile-outcome "$source" "$output" "$ir" "$tokens" \
        >"$actual" 2>"$WORK/$stem.internal"
    status=$?
    set -e
    test "$status" -eq 1 || fail "$stem exited $status instead of 1"
    test ! -s "$WORK/$stem.internal" || fail "$stem wrote internal stderr"
    test ! -e "$output" || fail "$stem emitted C"
    case $stem in
        normalize|scale_6144) test -s "$ir" && test -s "$tokens" ;;
        *) test ! -e "$ir" && test ! -e "$tokens" ;;
    esac || fail "$stem changed which checkpoints survive refusal"
    cmp "$golden" "$actual" || fail "$stem diagnostic differs from its golden"
    printf '%s\n' "PASS: $stem"
done

# The identity this slice exists for. The C half and the Kofun half agree on
# the scope HIR in pair.mjs below; these assertions make the normalization and
# the distinctness readable where a failure lands.
"$COMPILER" --emit-scope-hir "$CASES/normalize.kofun" "$WORK/normalize.hir"
grep -F '|pad|immutable|Fixed[2]|' "$WORK/normalize.hir" >/dev/null ||
    fail 'Fixed[02] did not normalize to Fixed[2]'
grep -F '|two|immutable|Fixed[2]|' "$WORK/normalize.hir" >/dev/null ||
    fail 'Fixed[2] did not keep its identity'
grep -F '|three|immutable|Fixed[3]|' "$WORK/normalize.hir" >/dev/null ||
    fail 'Fixed[3] did not keep its own identity'
grep -F 'Fixed[02]' "$WORK/normalize.hir" >/dev/null &&
    fail 'the unnormalized Fixed[02] spelling reached the scope HIR'
printf '%s\n' 'PASS: identity'

node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" "$CASES"/*.kofun

printf '%s\n' \
    'PASS: Fixed[S] scale identity, E408, argument-list refusals and the instantiation budget'
