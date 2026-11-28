#!/usr/bin/env sh
set -eu

# The first executable `Fixed[S]` program (#1250, RFC-0015): the owned
# `KofunDecimal` carrier, `Fixed.from_decimal` in its three expected-type
# contexts, the bounded `Result[Fixed[S], DecimalError]`, positive `?` with its
# early-return cleanup, and the consuming `match take`.
#
# Positives run under strict C11 and ASan/UBSan, and so do failing programs,
# which must exit 1 with only their golden diagnostic. The Err path is
# exercised by compiling the emitted C into a driver that owns allocation, so
# a refused allocation is a D004 status with no leak rather than an abort.
# Refusals exit 1, write no C, and match their golden. Both halves of the pair
# must agree on outcome, emitted C, checkpoints and scope HIR.

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
    case $stem in
        enum_fixed|fixed_qualified) test ! -e "$WORK/$stem.ir" && test ! -e "$WORK/$stem.tokens" ;;
        *) test -s "$WORK/$stem.ir" && test -s "$WORK/$stem.tokens" ;;
    esac || fail "$stem changed which checkpoints survive refusal"
    cmp "$golden" "$WORK/$stem.actual" || fail "$stem diagnostic differs from its golden"
    printf '%s\n' "PASS: refusal $stem"
done

# Each positive and the function its allocation-refusal driver calls (#1755).
# One positive per ownership transfer: `?` and `return Ok(owner)`
# (first_program), `Ok(owner)` into a local released at scope end
# (ok_transfer), a matched `Err(error)` re-wrapped (err_rewrap), a `?` early
# return with another owner live (two_owners), an exit from an `Ok` arm
# with its payload live (ok_arm_return), and the matched `Ok` payload itself
# returned as `Ok(amount)` (ok_arm_payload, #1761). Three more declare owners
# in an `if`/`else` branch, a `while` body and an `Ok` arm, and run off the
# body's `}` with them live, one moved into a local and one not
# (if_owner_fallthrough, while_owner_fallthrough, arm_owner_fallthrough,
# #1763). Every `.stdout` golden is a positive and must be listed, so none can
# skip the seam.
POSITIVES='grouped_propagation:cents propagate_call_and_local:cents construction_contexts:cents first_program:cents ok_transfer:cents err_rewrap:again two_owners:cents ok_arm_return:again ok_arm_payload:again if_owner_fallthrough:cents while_owner_fallthrough:cents arm_owner_fallthrough:again'
# #1766. Programs whose entry fails a statement through `kofun_failed`, an R010
# overflow, with Fixed owners live: after a `let` in the function body, in an
# `if` branch, on a `while` body's second pass and in an `Ok` arm with its
# payload live. Each must exit 1 with nothing on stdout and its `.failure`
# golden as the whole of stderr. ASan and LeakSanitizer also report on stderr,
# so that comparison is the leak and double-free check. Every `.failure` golden
# must be listed.
FAILURES='failed_function_body:cents failed_if_branch:cents failed_while_body:cents failed_ok_arm:again'
for golden in "$CASES"/*.stdout; do
    stem=$(basename "${golden%.stdout}")
    case " $POSITIVES " in
        *" $stem:"*) ;;
        *) fail "$stem has a .stdout golden but no allocation-refusal entry" ;;
    esac
done
for golden in "$CASES"/*.failure; do
    stem=$(basename "${golden%.failure}")
    case " $FAILURES " in
        *" $stem:"*) ;;
        *) fail "$stem has a .failure golden but no allocation-refusal entry" ;;
    esac
done

# A failing program's run: exit 1, empty stdout, stderr exactly its golden.
expect_failure() {
    set +e
    ASAN_OPTIONS=detect_leaks=1 "$2" >"$2.stdout" 2>"$2.stderr"
    failure_status=$?
    set -e
    test "$failure_status" -eq 1 || fail "$3 exited $failure_status instead of 1"
    test ! -s "$2.stdout" || fail "$3 wrote to stdout"
    cmp "$CASES/$1.failure" "$2.stderr" || {
        cat "$2.stderr" >&2
        fail "$3 stderr differs from its .failure golden"
    }
}

# A seam driver's stderr. A positive's is empty. A failing program prints its
# golden diagnostic once for each run that fails, and nothing else.
seam_stderr_ok() {
    if $fails; then
        seam_actual=$(sort -u "$1")
        seam_expected=$(sort -u "$CASES/$stem.failure")
    else
        seam_actual=$(wc -c <"$1" | tr -d ' ')
        seam_expected=0
    fi
    test "$seam_actual" = "$seam_expected"
}

# The Err path. The driver owns allocation, so every construction can be
# refused at each attempt N; each refusal is D004 with nothing left live, and
# an accepted construction releases its owner too. N walks every attempt the
# entry makes: the first run that refuses nothing ends the walk. The live count
# catches a leak, and the sanitized build turns a second release into a double
# free, so each owner is released exactly once on every path. For a failing
# program (@FAILS@ true, #1766), that last run must fail with `Err` and leave
# nothing live. A refused run may fail too, when the refused construction
# initializes a Result no `?` checks. A positive's runs never fail.
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
        kofun_failed = false;
        KofunFixedResult__2 result = kofun_fn_@ENTRY@();
        seam_refuse_at = 0;
        bool failed = kofun_failed;
        if (failed && (!@FAILS@ || result.ok)) return 7;
        if (seam_refused == 0 && failed != @FAILS@) return 7;
        if (!result.ok) {
            if (result.code != (int32_t)KOFUN_DECIMAL_MEMORY) return 2;
            if (seam_refused == 0 && !failed) return 5;
            if (seam_refused != 0) saw_refusal = true;
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

for program in $POSITIVES $FAILURES; do
    stem=${program%%:*}
    entry=${program#*:}
    case " $FAILURES " in
        *" $program "*)
            fails=true
            kind='failing program'
            ;;
        *)
            fails=false
            kind=positive
            ;;
    esac
    if $fails; then
        test -f "$CASES/$stem.failure" || fail "$stem is listed but has no .failure golden"
    else
        test -f "$CASES/$stem.stdout" || fail "$stem is listed but has no .stdout golden"
    fi
    "$COMPILER" --compile-outcome "$CASES/$stem.kofun" \
        "$WORK/$stem.c" "$WORK/$stem.ir" "$WORK/$stem.tokens" >/dev/null
    test -s "$WORK/$stem.c" || fail "the $kind $stem emitted no C"

    if grep -Eq '(^|[^[:alnum:]_])(decimal_fatal|kofun_decimal_value_round)[[:space:]]*\(' "$WORK/$stem.c"; then
        fail "$stem emitted a fatal Decimal operation for Fixed"
    fi
    if test "$stem" = construction_contexts; then
        sed -n 's/^typedef struct { KofunDecimal value; } \(KofunFixed__[0-9]*\);$/\1/p' "$WORK/$stem.c" |
            sort >"$WORK/fixed-names"
        printf '%s\n' KofunFixed__2 KofunFixed__3 | cmp - "$WORK/fixed-names" ||
            fail 'Fixed[02], Fixed[2] and Fixed[3] did not lower to exactly two built-in types'
        grep -Fqx '} KofunRecord_Fixed__2;' "$WORK/$stem.c" ||
            fail 'the user record lost its separate C type'
    fi
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" "$WORK/$stem.c" \
        -o "$WORK/$stem"
    if $fails; then
        expect_failure "$stem" "$WORK/$stem" "the failing program $stem"
    else
        "$WORK/$stem" >"$WORK/$stem.stdout"
        cmp "$CASES/$stem.stdout" "$WORK/$stem.stdout" ||
            fail "the positive $stem observation changed"
    fi
    printf '%s\n' "PASS: $kind $stem (strict C11)"

    "$CC" -std=c11 -O1 -g -fno-omit-frame-pointer \
        -fsanitize=address,undefined -fno-sanitize-recover=all \
        -I"$ROOT/bootstrap/stage2" "$WORK/$stem.c" \
        -o "$WORK/$stem.sanitized"
    if $fails; then
        expect_failure "$stem" "$WORK/$stem.sanitized" \
            "the sanitized failing program $stem"
    else
        ASAN_OPTIONS=detect_leaks=1 "$WORK/$stem.sanitized" \
            >"$WORK/$stem.sanitized.stdout"
        cmp "$CASES/$stem.stdout" "$WORK/$stem.sanitized.stdout" ||
            fail "the sanitized positive $stem observation changed"
    fi
    printf '%s\n' "PASS: $kind $stem (ASan/UBSan, no leaks)"

    sed -e "s/@STEM@/$stem/" -e "s/@ENTRY@/$entry/" -e "s/@FAILS@/$fails/" \
        "$WORK/seam.template" >"$WORK/$stem.seam.c"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I"$ROOT/bootstrap/stage2" -I"$WORK" "$WORK/$stem.seam.c" \
        -o "$WORK/$stem.seam"
    "$WORK/$stem.seam" >"$WORK/$stem.seam.stdout" 2>"$WORK/$stem.seam.stderr" ||
        fail "the allocation-refusal seam driver for $stem failed"
    grep -F 'PASS' "$WORK/$stem.seam.stdout" >/dev/null ||
        fail "the seam driver for $stem did not report PASS"
    seam_stderr_ok "$WORK/$stem.seam.stderr" || {
        cat "$WORK/$stem.seam.stderr" >&2
        fail "the seam driver for $stem wrote unexpected stderr"
    }
    "$CC" -std=c11 -O1 -g -fno-omit-frame-pointer \
        -fsanitize=address,undefined -fno-sanitize-recover=all \
        -I"$ROOT/bootstrap/stage2" -I"$WORK" "$WORK/$stem.seam.c" \
        -o "$WORK/$stem.seam.sanitized"
    ASAN_OPTIONS=detect_leaks=1 "$WORK/$stem.seam.sanitized" >/dev/null \
        2>"$WORK/$stem.seam.sanitized.stderr" || {
        cat "$WORK/$stem.seam.sanitized.stderr" >&2
        fail "the sanitized allocation-refusal seam driver for $stem failed"
    }
    seam_stderr_ok "$WORK/$stem.seam.sanitized.stderr" || {
        cat "$WORK/$stem.seam.sanitized.stderr" >&2
        fail "the sanitized seam driver for $stem wrote unexpected stderr"
    }
    printf '%s\n' "PASS: $stem allocation refusal is D004, each owner released once"
done

node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" "$CASES"/*.kofun

printf '%s\n' \
    'PASS: Fixed[S] carrier, Result boundary, positive ?, and match take'
