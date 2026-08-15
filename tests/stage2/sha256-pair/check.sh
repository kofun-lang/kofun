#!/usr/bin/env sh
set -eu

# The Stage 2 pair computes the same SHA-256 as the C oracle (#1382).
#
# Every identity this compiler assigns — ModuleId, FileId, SymbolId — is a
# SHA-256 preimage, and until RFC-0013 step 4 the digest was computed by
# `bootstrap/stage2/sha256.c`, so a compiler specified to assign its own
# identities could not reach the operation that defines them.
#
# The digest now exists in three places and this gate is what stops them
# drifting:
#
#   1. `bootstrap/stage2/compiler.kofun`  nineteen `sha256_*` functions
#   2. `bootstrap/stage2/compiler.c`      `#include "sha256.c"`
#   3. `bootstrap/stage2/sha256.c`        the oracle, reached via bin/kofun-digest
#
# Three copies are safe only while something compares them, which is why this
# gate compares all three rather than any two.
#
# The Kofun half is extracted from `compiler.kofun` between its own markers and
# built as a standalone program, rather than copied into this directory. A copy
# would be a fourth place to drift; an extraction fails loudly when the block
# moves or its boundary changes.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WORK=${KOFUN_SHA256_PAIR_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}sha256-pair"}

. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || assert_fail 'a C11 compiler is required'

PAIR_KOFUN="$ROOT/bootstrap/stage2/compiler.kofun"
PAIR_C="$ROOT/bootstrap/stage2/compiler.c"

# ------------------------------------------------------------ the C half

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic "$PAIR_C" -o "$WORK/pair-c"
"$WORK/pair-c" --sha256-selftest >"$WORK/c.digests"
assert_num 'the C half printed one line per vector' "$(grep -c . "$WORK/c.digests")" -eq 4

# --------------------------------------------------------- the Kofun half
#
# Extracted between the marker comment and `fn main`, so the block cannot be
# quietly renamed or moved without this failing.

start=$(grep -n '^# ---* SHA-256$' "$PAIR_KOFUN" | cut -d: -f1)
assert_nonempty 'compiler.kofun carries the SHA-256 marker' "$start"
end=$(grep -n '^fn main() -> Int {' "$PAIR_KOFUN" | cut -d: -f1)
assert_nonempty 'compiler.kofun carries a main' "$end"

awk -v a="$start" -v b="$((end - 1))" 'NR>=a && NR<=b' "$PAIR_KOFUN" >"$WORK/block.kofun"
printf '\nfn main() -> Int {\n    return sha256_selftest()\n}\n' >>"$WORK/block.kofun"

functions=$(grep -c '^fn sha256' "$WORK/block.kofun")
assert_num 'the extracted block carries every sha256 function' "$functions" -eq 21

"$ROOT/bin/kofun" build "$WORK/block.kofun" -o "$WORK/pair-kofun" \
    --emit-c "$WORK/block.c" >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    assert_fail "the Kofun half did not build: $(cat "$WORK/build.stderr")"

"$WORK/pair-kofun" >"$WORK/kofun.digests"

# ---------------------------------------------------- the three-way compare

assert_eq 'the two halves of the pair agree' \
    "$(cat "$WORK/kofun.digests")" "$(cat "$WORK/c.digests")"

# The same bytes, materialised for the oracle. Spelled here a third time on
# purpose: if this gate built them from either half it would be comparing a
# half against itself.
printf '' >"$WORK/empty.bin"
printf 'abc' >"$WORK/abc.bin"
printf 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' >"$WORK/nist448.bin"
printf '%s%s' \
    'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn' \
    'hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu' >"$WORK/nist896.bin"

compared=0
for name in empty abc nist448 nist896
do
    oracle=$("$ROOT/bin/kofun-digest" "$WORK/$name.bin" | cut -d' ' -f1)
    pair=$(grep "^$name " "$WORK/kofun.digests" | cut -d' ' -f2)
    assert_nonempty "the oracle digested $name" "$oracle"
    assert_nonempty "the pair digested $name" "$pair"
    assert_eq "the pair and bootstrap/stage2/sha256.c agree on $name" "$pair" "$oracle"
    compared=$((compared + 1))
done
assert_num 'every vector was compared with the oracle' "$compared" -eq 4

# ------------------------------------------------------- the mutation proof
#
# Three agreeing implementations prove nothing if the comparison cannot fail.
# One round constant is flipped in a copy of the extracted block, and the
# rebuilt program must disagree with the oracle — otherwise this gate would
# pass on a broken digest.

sed 's/1116352408/1116352409/' "$WORK/block.kofun" >"$WORK/mutant.kofun"
assert_not_grep 'the mutation changed the block' -Fq -- '1116352408' "$WORK/mutant.kofun"

"$ROOT/bin/kofun" build "$WORK/mutant.kofun" -o "$WORK/mutant" \
    >"$WORK/mutant.stdout" 2>"$WORK/mutant.stderr" ||
    assert_fail "the mutant did not build: $(cat "$WORK/mutant.stderr")"
"$WORK/mutant" >"$WORK/mutant.digests"

mutant_abc=$(grep '^abc ' "$WORK/mutant.digests" | cut -d' ' -f2)
oracle_abc=$("$ROOT/bin/kofun-digest" "$WORK/abc.bin" | cut -d' ' -f1)
assert_nonempty 'the mutant produced a digest' "$mutant_abc"
assert_ne 'a flipped round constant does not reproduce the oracle digest' \
    "$mutant_abc" "$oracle_abc"

printf 'PASS: the Stage 2 pair and bootstrap/stage2/sha256.c agree on four NIST vectors\n'
printf 'PASS: both halves of the pair print identical digests, and a flipped round constant does not\n'
