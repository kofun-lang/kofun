#!/bin/sh
set -eu

# The lasting gate for SHA-256 in Kofun (#1352, RFC-0013 step 2).
#
# The repository's own digests — `bootstrap/stage2/SHA256SUMS`,
# `bootstrap/manifest.json`, the release evidence, and every compiler identity —
# are SHA-256 preimages computed by C, because until RFC-0013 the language had
# no way to spell a bit operation. This gate is what makes the Kofun version
# trustworthy enough to be worth having:
#
#   * the four vectors FIPS 180-4 publishes are asserted **verbatim**, so the
#     anchor is the standard rather than agreement between two implementations
#     that live in the same repository;
#   * every corpus message is digested by `bootstrap/stage2/sha256.c` through
#     `bin/kofun-digest` and required to match byte for byte, which is the
#     differential the issue asks for and keeps the C implementation as oracle;
#   * both sides of every padding boundary run — 55, 56, 63, 64, and 65 — and
#     65 is the length that cannot fit one `List[Int]`, so it exercises the
#     two-list message path rather than only the padding arithmetic; and
#   * a moved round constant, a moved rotation amount, and a moved padding
#     length field must each fail, because a digest that is wrong is stable,
#     self-consistent, and completely useless.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/stdlib/kofun-digest-model"
ASSERT_CONTEXT='kofun digest model'
. "$ROOT/tests/assertions/assert.sh"

WORK=${KOFUN_DIGEST_MODEL_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}kofun-digest-model"}
case $WORK in
    */kofun-digest-model|*/kofun-digest-model.*) ;;
    *) assert_fail "work directory must end in kofun-digest-model[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/messages"

command -v node >/dev/null 2>&1 || assert_fail 'node is required to read the corpus'
command -v cmp >/dev/null 2>&1 || assert_fail 'cmp is required'

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    assert_fail 'a C11 compiler is required'
fi

model="$CASES/sha256.kofun"
corpus="$CASES/corpus.mjs"
assert_regular_file 'Kofun SHA-256' "$model"
assert_regular_file 'corpus reader' "$corpus"
assert_regular_file 'corpus' "$CASES/corpus.json"

# ------------------------------------------------------------------ hygiene

find "$CASES" -type f \( -name '*.py' -o -name '*.kf' \) >"$WORK/forbidden"
assert_file_empty 'forbidden Python or .kf source in the corpus' "$WORK/forbidden"

assert_not_grep 'model imports an ambient dependency' -q -- '^import ' "$model"
assert_not_grep 'model names host time, file, network, or randomness' \
    -qE -- 'clock_gettime|nanosleep|fopen|open\(|socket\(|connect\(|random|rand\(' \
    "$model"

# The model must compute the digest, not look one up. A hexadecimal digest in
# the source would mean the answer is stored rather than derived.
grep -vE '^[[:space:]]*#' "$model" >"$WORK/model.code"
assert_not_grep 'model carries a precomputed digest' \
    -qE -- '[0-9a-f]{32}' "$WORK/model.code"

# ------------------------------------------------------------- corpus joins

messages=$(node "$corpus" literals)
assert_num 'every corpus message has matching Kofun literals' "$messages" -eq 9

node "$corpus" files "$WORK/messages" >"$WORK/names"
assert_file_nonempty 'corpus message list' "$WORK/names"

# ------------------------------------------------------------------- build

"$ROOT/bin/kofun" check "$model" >"$WORK/check.stdout" 2>"$WORK/check.stderr" ||
    assert_fail "the model did not check: $(cat "$WORK/check.stderr")"
assert_grep 'the model is accepted by the checker' -Fq -- 'ok:' "$WORK/check.stdout"

"$ROOT/bin/kofun" build "$model" -o "$WORK/sha256" --emit-c "$WORK/sha256.c" \
    >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    assert_fail "the model did not build: $(cat "$WORK/build.stderr")"

for level in -O0 -O2
do
    "$compiler" -std=c11 "$level" -Wall -Wextra -Werror -pedantic \
        "$WORK/sha256.c" -o "$WORK/sha256.$level.bin"
    "$WORK/sha256.$level.bin" >"$WORK/digests$level.stdout"
    cmp "$WORK/digests-O0.stdout" "$WORK/digests$level.stdout" ||
        assert_fail "the model differs between -O0 and $level"
done

"$WORK/sha256" >"$WORK/digests.stdout"
"$WORK/sha256" >"$WORK/digests.second"
cmp "$WORK/digests.stdout" "$WORK/digests.second" ||
    assert_fail 'two executions of the model differ'
cmp "$WORK/digests.stdout" "$WORK/digests-O0.stdout" ||
    assert_fail 'the model differs between the toolchain binary and strict C11'

"$ROOT/bin/kofun" run "$model" >"$WORK/digests.reference" 2>&1 ||
    assert_fail 'the model did not run under the reference executor'
cmp "$WORK/digests.stdout" "$WORK/digests.reference" ||
    assert_fail 'the reference executor disagrees with the C11 backend'

assert_not_grep 'emitted C reaches host time, file, network, or randomness' \
    -qE -- 'time\.h|clock_gettime|gettimeofday|nanosleep|fopen|socket|connect|rand\(' \
    "$WORK/sha256.c"

# ------------------------------------------------------- published vectors

node "$corpus" published >"$WORK/published"
while read -r name digest
do
    assert_grep "the published $name vector matches byte for byte" \
        -Fq -- "$name $digest" "$WORK/digests.stdout"
done <"$WORK/published"

# --------------------------------------------- differential against the C

: >"$WORK/differential"
while read -r name
do
    c_digest=$("$ROOT/bin/kofun-digest" "$WORK/messages/$name.bin" | cut -d' ' -f1)
    kofun_digest=$(grep "^$name " "$WORK/digests.stdout" | cut -d' ' -f2)
    assert_nonempty "the C oracle digested $name" "$c_digest"
    assert_nonempty "the model digested $name" "$kofun_digest"
    assert_eq "Kofun and bootstrap/stage2/sha256.c agree on $name" \
        "$kofun_digest" "$c_digest"
    printf '%s %s\n' "$name" "$c_digest" >>"$WORK/differential"
done <"$WORK/names"

lines=$(wc -l <"$WORK/differential" | tr -d ' ')
assert_num 'every corpus message was compared with the C oracle' "$lines" -eq 9

# ---------------------------------------------------------------- mutations
#
# A wrong digest is stable and self-consistent, so the only evidence that this
# gate can tell right from wrong is that a wrong implementation fails it.

mutation() {
    name=$1
    expression=$2
    sed "$expression" "$model" >"$WORK/mutant-$name.kofun"
    cmp -s "$model" "$WORK/mutant-$name.kofun" &&
        assert_fail "mutation $name changed nothing; its pattern no longer matches"
    if "$ROOT/bin/kofun" run "$WORK/mutant-$name.kofun" \
        >"$WORK/mutant-$name.stdout" 2>"$WORK/mutant-$name.stderr"
    then
        if cmp -s "$WORK/digests.stdout" "$WORK/mutant-$name.stdout"
        then
            assert_fail "mutation $name produced the same digests; the gate does not bite"
        fi
    fi
}

# One round constant, one bit. K[0] is 0x428a2f98.
mutation round-constant 's/^        1116352408, /        1116352409, /'

# One rotation amount in Sigma-1. FIPS 180-4 fixes it at 6.
mutation rotation-amount 's/word\.rotr(6, 32)/word.rotr(7, 32)/'

# The length field is in bits, not bytes. Dropping the shift is the classic
# padding defect and it changes only messages whose length is nonzero.
mutation length-field 's/return length\.shl(3)\.shr(place \* 8)\.and(255)/return length.shr(place * 8).and(255)/'

printf '%s\n' \
    'PASS: the four published FIPS 180-4 vectors match byte for byte' \
    'PASS: nine corpus messages agree with bootstrap/stage2/sha256.c, the C oracle' \
    'PASS: lengths 55, 56, 63, 64, and 65 exercise both sides of every padding boundary' \
    'PASS: -O0, -O2, the reference executor, and a repeat execution agree' \
    'PASS: a moved round constant, rotation amount, and length field each fail'
