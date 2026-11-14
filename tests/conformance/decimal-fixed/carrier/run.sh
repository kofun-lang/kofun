#!/usr/bin/env sh
set -eu

# The first executable `Fixed[S]` program (#1250, RFC-0015): the owned
# `KofunDecimal` carrier, `Fixed.from_decimal` in its three expected-type
# contexts, the bounded `Result[Fixed[S], DecimalError]`, positive `?` with its
# early-return cleanup, and the consuming `match take`.
#
# Positives run under strict C11 and ASan/UBSan. The Err path is exercised by
# compiling the emitted C into a driver that owns allocation, so a refused
# allocation is a D004 status with no leak rather than an abort. Refusals exit
# 1, write no C, and match their golden. Both halves of the pair must agree on
# outcome, emitted C, checkpoints and scope HIR.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
CASES="$ROOT/tests/conformance/decimal-fixed/carrier"
CC=${CC:-cc}
WORK=${KOFUN_DECIMAL_FIXED_CARRIER_WORK:-"$ROOT/build/decimal-fixed-carrier"}
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */decimal-fixed-carrier|*/decimal-fixed-carrier.*) ;;
    *) fail "work directory must end in decimal-fixed-carrier[.suffix]: $WORK" ;;
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

"$COMPILER" --compile-outcome "$CASES/first_program.kofun" \
    "$WORK/first_program.c" "$WORK/first_program.ir" "$WORK/first_program.tokens"
test -s "$WORK/first_program.c" || fail 'the positive program emitted no C'

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" "$WORK/first_program.c" \
    -o "$WORK/first_program"
"$WORK/first_program" >"$WORK/first_program.stdout"
cmp "$CASES/first_program.stdout" "$WORK/first_program.stdout" ||
    fail 'the positive program observation changed'
printf '%s\n' 'PASS: first program (strict C11)'

"$CC" -std=c11 -O1 -g -fno-omit-frame-pointer \
    -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I"$ROOT/bootstrap/stage2" "$WORK/first_program.c" \
    -o "$WORK/first_program.sanitized"
ASAN_OPTIONS=detect_leaks=1 "$WORK/first_program.sanitized" \
    >"$WORK/first_program.sanitized.stdout"
cmp "$CASES/first_program.stdout" "$WORK/first_program.sanitized.stdout" ||
    fail 'the sanitized positive program observation changed'
printf '%s\n' 'PASS: first program (ASan/UBSan, no leaks)'

# The Err path. The driver owns allocation, so every construction can be
# refused at each attempt N; each refusal is D004 with nothing left live, and
# an accepted construction releases its owner too.
cat >"$WORK/seam.c" <<'SEAM'
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long seam_attempts;
static unsigned long seam_refuse_at;
static unsigned long seam_refused;
static long seam_live;

static bool seam_refuses(void) {
    ++seam_attempts;
    if (seam_refuse_at != 0 && seam_attempts == seam_refuse_at) {
        ++seam_refused;
        return true;
    }
    return false;
}
static void *seam_malloc(size_t size) {
    if (seam_refuses()) return NULL;
    void *block = malloc(size);
    if (block != NULL) ++seam_live;
    return block;
}
static void *seam_realloc(void *old, size_t size) {
    if (seam_refuses()) return NULL;
    void *block = realloc(old, size);
    if (block != NULL && old == NULL) ++seam_live;
    return block;
}
static void seam_free(void *block) {
    if (block != NULL) --seam_live;
    free(block);
}

#define malloc(size) seam_malloc(size)
#define realloc(old, size) seam_realloc(old, size)
#define free(block) seam_free(block)
#define main kofun_generated_program_main
#include "first_program.c"
#undef main

int main(void) {
    bool saw_refusal = false;
    for (unsigned long n = 1; n <= 24; ++n) {
        seam_attempts = 0;
        seam_refused = 0;
        seam_live = 0;
        seam_refuse_at = n;
        KofunFixedResult__2 result = kofun_fn_cents();
        seam_refuse_at = 0;
        if (!result.ok) {
            if (result.code != (int32_t)KOFUN_DECIMAL_MEMORY) return 2;
            saw_refusal = true;
        }
        kofun_fixed_drop(&result.value);
        if (seam_live != 0) return 3;
    }
    if (!saw_refusal) return 4;
    printf("PASS\n");
    return 0;
}
SEAM
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" -I"$WORK" "$WORK/seam.c" -o "$WORK/seam"
"$WORK/seam" >"$WORK/seam.stdout" || fail 'the allocation-refusal seam driver failed'
grep -F 'PASS' "$WORK/seam.stdout" >/dev/null || fail 'the seam driver did not report PASS'
"$CC" -std=c11 -O1 -g -fno-omit-frame-pointer \
    -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I"$ROOT/bootstrap/stage2" -I"$WORK" "$WORK/seam.c" -o "$WORK/seam.sanitized"
ASAN_OPTIONS=detect_leaks=1 "$WORK/seam.sanitized" >/dev/null ||
    fail 'the sanitized allocation-refusal seam driver failed'
printf '%s\n' 'PASS: allocation refusal is D004 with no leak'

node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" "$CASES"/*.kofun

printf '%s\n' \
    'PASS: Fixed[S] carrier, Result boundary, positive ?, and match take'
