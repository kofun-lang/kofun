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

# Each positive and the function its allocation-refusal driver calls (#1755).
# One positive per ownership transfer: `?` and `return Ok(owner)`
# (first_program), `Ok(owner)` into a local released at scope end
# (ok_transfer), a matched `Err(error)` re-wrapped (err_rewrap), a `?` early
# return with another owner live (two_owners), and an exit from an `Ok` arm
# with its payload live (ok_arm_return). Every `.stdout` golden is a positive
# and must be listed, so none can skip the seam.
POSITIVES='first_program:cents ok_transfer:cents err_rewrap:again two_owners:cents ok_arm_return:again'
for golden in "$CASES"/*.stdout; do
    stem=$(basename "${golden%.stdout}")
    case " $POSITIVES " in
        *" $stem:"*) ;;
        *) fail "$stem has a .stdout golden but no allocation-refusal entry" ;;
    esac
done

# The Err path. The driver owns allocation, so every construction can be
# refused at each attempt N; each refusal is D004 with nothing left live, and
# an accepted construction releases its owner too. N walks every attempt the
# entry makes: the first run that refuses nothing ends the walk. The live count
# catches a leak, and the sanitized build turns a second release into a double
# free, so each owner is released exactly once on every path.
cat >"$WORK/seam.template" <<'SEAM'
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
#include "@STEM@.c"
#undef main

int main(void) {
    bool saw_refusal = false;
    for (unsigned long n = 1; n <= 4096; ++n) {
        seam_attempts = 0;
        seam_refused = 0;
        seam_live = 0;
        seam_refuse_at = n;
        KofunFixedResult__2 result = kofun_fn_@ENTRY@();
        seam_refuse_at = 0;
        if (!result.ok) {
            if (result.code != (int32_t)KOFUN_DECIMAL_MEMORY) return 2;
            if (seam_refused == 0) return 5;
            saw_refusal = true;
        }
        kofun_fixed_drop(&result.value);
        if (seam_live != 0) return 3;
        if (seam_refused == 0) {
            if (!saw_refusal) return 4;
            printf("PASS\n");
            return 0;
        }
    }
    return 6;
}
SEAM

for positive in $POSITIVES; do
    stem=${positive%%:*}
    entry=${positive#*:}
    test -f "$CASES/$stem.stdout" || fail "$stem is listed but has no .stdout golden"
    "$COMPILER" --compile-outcome "$CASES/$stem.kofun" \
        "$WORK/$stem.c" "$WORK/$stem.ir" "$WORK/$stem.tokens" >/dev/null
    test -s "$WORK/$stem.c" || fail "the positive $stem emitted no C"

    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" "$WORK/$stem.c" \
        -o "$WORK/$stem"
    "$WORK/$stem" >"$WORK/$stem.stdout"
    cmp "$CASES/$stem.stdout" "$WORK/$stem.stdout" ||
        fail "the positive $stem observation changed"
    printf '%s\n' "PASS: positive $stem (strict C11)"

    "$CC" -std=c11 -O1 -g -fno-omit-frame-pointer \
        -fsanitize=address,undefined -fno-sanitize-recover=all \
        -I"$ROOT/bootstrap/stage2" "$WORK/$stem.c" \
        -o "$WORK/$stem.sanitized"
    ASAN_OPTIONS=detect_leaks=1 "$WORK/$stem.sanitized" \
        >"$WORK/$stem.sanitized.stdout"
    cmp "$CASES/$stem.stdout" "$WORK/$stem.sanitized.stdout" ||
        fail "the sanitized positive $stem observation changed"
    printf '%s\n' "PASS: positive $stem (ASan/UBSan, no leaks)"

    sed -e "s/@STEM@/$stem/" -e "s/@ENTRY@/$entry/" \
        "$WORK/seam.template" >"$WORK/$stem.seam.c"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" -I"$WORK" "$WORK/$stem.seam.c" \
        -o "$WORK/$stem.seam"
    "$WORK/$stem.seam" >"$WORK/$stem.seam.stdout" ||
        fail "the allocation-refusal seam driver for $stem failed"
    grep -F 'PASS' "$WORK/$stem.seam.stdout" >/dev/null ||
        fail "the seam driver for $stem did not report PASS"
    "$CC" -std=c11 -O1 -g -fno-omit-frame-pointer \
        -fsanitize=address,undefined -fno-sanitize-recover=all \
        -I"$ROOT/bootstrap/stage2" -I"$WORK" "$WORK/$stem.seam.c" \
        -o "$WORK/$stem.seam.sanitized"
    ASAN_OPTIONS=detect_leaks=1 "$WORK/$stem.seam.sanitized" >/dev/null ||
        fail "the sanitized allocation-refusal seam driver for $stem failed"
    printf '%s\n' "PASS: $stem allocation refusal is D004, each owner released once"
done

node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" "$CASES"/*.kofun

printf '%s\n' \
    'PASS: Fixed[S] carrier, Result boundary, positive ?, and match take'
