#!/usr/bin/env sh
set -eu

# Decimal slice 2 (#721): the runtime representation, its canonical form, and
# the versioned resource profile. Slice 4 (#723) adds the exact operations and
# checked exact division below, plus the Float contrast that keeps the two
# types from being conflated. Slice 5 (#724) adds the explicit rounding and
# formatting boundaries; no command below acquires a default scale or mode.
#
# What this gate is for, beyond "the code runs". Four of #710's frozen
# decisions are only checkable by observation, and each has a section below:
#
#   1. the significand is arbitrary precision, and small storage is an
#      *unobservable* optimization;
#   6. plain Decimal canonicalizes display scale away, so `1.0` and `1` are one
#      value;
#   8. resource limits are versioned, fail explicitly, and never clamp or
#      change representation;
#   and `docs/DECIMAL.md`'s rule that no conversion goes through a host
#   `double`.

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/decimal"
CC=${CC:-cc}

command -v "$CC" >/dev/null 2>&1 || {
    printf '%s\n' "decimal: a C11 compiler is required" >&2
    exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-decimal.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

"$CC" -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$ROOT/bootstrap/stage2/decimal_v1.c" \
    "$CASES/decimal_v1_test.c" \
    -o "$WORK/decimal-test"

golden() {
    name=$1
    shift
    "$WORK/decimal-test" "$@" >"$WORK/$name.observed" 2>&1
    cmp "$CASES/$name.golden" "$WORK/$name.observed" ||
        fail "$name observation changed"
    printf '%s\n' "PASS: $name"
}

# Construction. The digits are preserved exactly, including significands well
# past Int64 — 2^127 and a 60-digit value are here so that "arbitrary
# precision" is measured rather than asserted.
golden construct construct \
    1.5 1.50 1.500 1 1.0 1.00 1000 1e3 1e+3 0.1 0.10 6.02e23 1e-9 \
    1_000.000_1 0 0.0 0.000 \
    9223372036854775807 9223372036854775808 \
    170141183460469231731687303715884105728 \
    123456789012345678901234567890.123456789012345678901234567890

# Canonicalization (frozen decision 6). Distinct spellings of one value must be
# *structurally* equal after construction, not merely compare equal — so the
# golden records both, and a canonicalizer that only fixed `compare` would fail
# on the `equal=` column.
golden canonical equal \
    1.0 1 \
    1.00 1.0 \
    1.000 1.00 \
    1000 1e3 \
    0.1e1 1 \
    10e-1 1 \
    0 0.0 \
    0.1 0.2 \
    2 10 \
    1e3 1e4 \
    0.000001 1e-6

# Small-storage invisibility (frozen decision 1). Each line carries the path
# taken *and* every public observation, and the pairs straddle the boundary:
# 18446744073709551615 is the last inline value and ...616 the first promoted
# one. If the threshold ever leaked into equality, scale or rendering, the
# adjacent pair is where it would show.
golden storage storage \
    1.5 1 0.1 \
    18446744073709551615 18446744073709551616 \
    99999999999999999999999999999999999999.5

# The versioned profile (frozen decision 8). `docs/DECIMAL.md` deferred the
# first concrete thresholds but required them to be "versioned together when
# introduced", so the version and every limit and message are one golden: a
# limit cannot move without the version moving in the same diff.
golden profile profile

golden malformed construct 1..2 1e 1.5.5 abc ''

# Each limit at its exact boundary and one past it. Exceeding a limit is a
# stable code, never a clamped value — so the `-at` line must show a
# constructed value and the `-over` line a bare code.
{
    "$WORK/decimal-test" limit digits-at
    "$WORK/decimal-test" limit digits-over
    "$WORK/decimal-test" limit scale-at
    "$WORK/decimal-test" limit scale-over
} >"$WORK/limits.observed" 2>&1
cmp "$CASES/limits.golden" "$WORK/limits.observed" ||
    fail "resource limit observations changed"
grep -q '^digits-over -> D001$' "$WORK/limits.observed" ||
    fail "one digit past the limit did not report D001"
grep -q '^scale-over -> D002$' "$WORK/limits.observed" ||
    fail "one step past the scale limit did not report D002"
printf '%s\n' "PASS: limits"

# Binary64, as raw bits rather than a decimal rendering, so no printf of the
# host's own can hide a difference. The list covers the subnormal cliff
# (5e-324, 2.47e-324), the smallest normal, and two exact ties
# (9007199254740993, 1e23).
golden float float \
    0.1 0.2 0.3 1.5 1 2 0.5 1e-9 6.02e23 1e308 1e-308 \
    5e-324 2.4703282292062328e-324 2.2250738585072014e-308 \
    9007199254740993 1e22 1e23 3.141592653589793 0 0.0

# `docs/DECIMAL.md` forbids converting a literal through a host `double`. That
# is a property of the source, so it is checked there: the module must not
# reach for the host's decimal parser or its floating-point math library.
# The pattern requires the opening parenthesis of a call. Matching the bare
# name instead flags the module's own comment explaining that it does not use
# `strtod`, which is how this check first failed.
for forbidden in strtod strtof strtold atof sscanf scanf; do
    if grep -nE "(^|[^_[:alnum:]])$forbidden[[:space:]]*\\(" \
        "$ROOT/bootstrap/stage2/decimal_v1.c" >/dev/null 2>&1
    then
        fail "decimal_v1.c calls $forbidden; conversion must stay exact"
    fi
done
if grep -n '#include <math.h>' "$ROOT/bootstrap/stage2/decimal_v1.c" \
    >/dev/null 2>&1
then
    fail "decimal_v1.c includes math.h; conversion must stay exact"
fi
printf '%s\n' "PASS: no host decimal parser on the conversion path"

# `//` and `%` on Decimal are deliberately absent. #710 defers their signed
# convention to a separate issue and #723 requires that it "must not be settled
# implicitly here" — but an omission cannot be observed, so it is asserted.
#
# This guard exists because the natural way to settle the convention by
# accident is to add the operation quietly alongside the four exact ones, where
# it reads as completeness rather than as a decision. `docs/DECIMAL.md` requires
# positive and negative examples to be landed before either operator becomes
# available, so adding one must fail here until they are.
for undecided in floor_div floordiv modulo remainder truncate_div; do
    if grep -nE "kofun_decimal_$undecided" \
        "$ROOT/bootstrap/stage2/decimal_v1.h" \
        "$ROOT/bootstrap/stage2/decimal_v1.c" >/dev/null 2>&1
    then
        fail "decimal_v1 defines $undecided; #710 defers the signed convention"
    fi
done
printf '%s\n' "PASS: Decimal // and % remain undecided and unimplemented"

# #916 now makes a literal const argument part of a nominal type's identity:
# the shipped CLI refuses `Fixed[3]` where `Fixed[2]` is required. That is the
# type-system foundation for #725 Part B, not a Decimal-backed `Fixed` value.
# Native Decimal still takes destination and display scales as runtime Int
# arguments, so #725 Part A's `runtime-scale/v1` name remains the truthful
# profile for the operations this gate executes.
#
# Three parts are asserted, because any one can drift on its own:
#
#   1. the type checker must retain const-generic scale identity;
#   2. the documents must carry the name and the disclaimer, so a reader is
#      told what the guarantee is rather than left to infer it;
#   3. native Decimal must still match that description, so the sentence
#      cannot go on being printed after it stops being true.
#
# Reuse the product-path erasure sentinel instead of inventing a second
# mismatch fixture. `task const-generics` owns its full corpus; this focused
# observation ties that established type identity to Decimal's scale profile.
PROFILE='runtime-scale/v1'
SCALE_MISMATCH="$ROOT/tests/conformance/const-generics/product/scale_mismatch"

set +e
"$ROOT/bin/kofun" check "$SCALE_MISMATCH.kofun" \
    >"$WORK/scale-mismatch.stdout" 2>"$WORK/scale-mismatch.stderr"
scale_mismatch_status=$?
set -e
test "$scale_mismatch_status" -eq 1 ||
    fail "Fixed[3] to Fixed[2] mismatch exited $scale_mismatch_status instead of 1"
test ! -s "$WORK/scale-mismatch.stdout" ||
    fail "Fixed scale mismatch wrote stdout"
cmp "$SCALE_MISMATCH.stdout" "$WORK/scale-mismatch.stderr" ||
    fail "Fixed scale mismatch diagnostic differs from E2S151 product evidence"

for doc in docs/DECIMAL.md stdlib/decimal/README.md; do
    grep -qF "$PROFILE" "$ROOT/$doc" ||
        fail "$doc does not name the interim scale profile $PROFILE"
    grep -qF 'Literal integer const generics already distinguish Fixed[2] from Fixed[3]' \
        "$ROOT/$doc" ||
        fail "$doc stopped stating the shipped literal const-generic identity"
    grep -qF 'not a Decimal-backed Fixed[scale] implementation' "$ROOT/$doc" ||
        fail "$doc confuses const-generic identity with Decimal-backed Fixed semantics"
done
grep -qF 'no static scale safety' "$ROOT/docs/DECIMAL.md" ||
    fail "docs/DECIMAL.md stopped stating that runtime Decimal has no static scale safety"

for stale in \
    'const-generic integer parameters are not implemented' \
    'Fixed[2] and Fixed[3] cannot yet be expressed as different types at all'
do
    for doc in docs/DECIMAL.md stdlib/decimal/README.md; do
        if grep -qF "$stale" "$ROOT/$doc"; then
            fail "$doc retains stale pre-#916 premise: $stale"
        fi
    done
done

# The implementation side. Slice 5 exposes scale only as an explicit runtime
# argument. It must not publish either a fake Fixed[scale] guarantee or the old
# Int64-significand placeholder beside the compiler-native Decimal type.
if grep -nE '^[[:space:]]*((pub|internal|private)[[:space:]]+)?type[[:space:]]+(Decimal|Fixed)(\[[^]]+\])?[[:space:]]*=' \
    "$ROOT/stdlib/decimal/decimal.kofun" >/dev/null 2>&1
then
    fail "stdlib Decimal source redeclares Decimal or implements a Fixed value"
fi
if grep -nF 'significand: Int' "$ROOT/stdlib/decimal/decimal.kofun" \
    >/dev/null 2>&1
then
    fail "stdlib Decimal source retains the retired Int64 significand"
fi
grep -qF 'destination_scale' "$ROOT/stdlib/decimal/decimal.kofun" ||
    fail "stdlib Decimal source does not expose explicit runtime scale"
printf '%s\n' "PASS: scale guarantees are stated as $PROFILE and still true"
printf '%s\n' \
    "PASS: const-generic scale identity exists; Decimal-backed Fixed semantics do not"

# --- exact arithmetic (slice 4 of #710, issue #723) ------------------------

# The headline acceptance criterion of #710, and the reason this type exists.
# Each line prints the decimal answer beside the binary64 one, so the golden
# carries its own counterexample: `0.30000000000000004` next to `true` is the
# evidence that the decimal path is not going through a double.
golden identity identity \
    0.1 0.2 0.3 \
    0.1 0.7 0.8 \
    1.005 0.005 1.01 \
    2.675 0.001 2.676 \
    100000000000000000000 1 100000000000000000001

# Exactness of + - *, on operands chosen so binary64 gives a different answer.
# 9007199254740993 is 2^53+1, the first integer a double cannot represent, so
# an implementation that routed through one loses the low digit here.
# Every operand is unsigned: the profile's literal grammar has no sign, so a
# negative value arrives through the operator. `sub` below is what produces
# one, and its golden is where the sign handling is actually observed.
golden arith_add add \
    0.1 0.2 \
    1.5 2.5 \
    9007199254740993 1 \
    123456789012345678901234567890 0.000000000000000000000000000001
golden arith_sub sub \
    0.3 0.1 \
    1 1 \
    0.1 0.2 \
    9007199254740993 9007199254740992 \
    1000000 0.000001
golden arith_mul mul \
    1.5 2 \
    0.1 0.1 \
    1.1 1.1 \
    9007199254740993 2 \
    0 12345

# Division has exactly three outcomes and no fourth. The exact cases include a
# multi-limb divisor whose non-2-non-5 residue divides the dividend, which is
# the path that decides exactness by dividing rather than by inspecting the
# denominator's small factors.
golden arith_div div \
    1.0 4.0 \
    1.0 3.0 \
    1.0 0.0 \
    0.0 5 \
    10 4 \
    1 3333333333333333333333333333333 \
    9999999999999999999999999999999 3333333333333333333333333333333 \
    7 70 \
    1 6

# Every named rounding mode is pinned on both sides of zero. The carry cases
# show that rounding is arbitrary precision and canonicalizes only after the
# explicit destination scale has done its work.
golden round round \
    2.5 0 HalfUp -2.5 0 HalfUp \
    2.5 0 HalfEven -2.5 0 HalfEven \
    2.5 0 TowardZero -2.5 0 TowardZero \
    2.5 0 Floor -2.5 0 Floor \
    2.5 0 Ceiling -2.5 0 Ceiling \
    1.999 2 HalfUp -1.999 2 HalfUp \
    999999999999999999999999999999.5 0 HalfEven

# Rounded division has no ambient policy: each group supplies scale and mode,
# including exact inputs. Division by zero remains a stable failure.
golden rounded_divide rounded-divide \
    1 8 2 HalfUp -1 8 2 HalfUp \
    1 8 2 HalfEven -1 8 2 HalfEven \
    1 3 2 Floor -1 3 2 Floor \
    1 3 2 Ceiling -1 3 2 Ceiling \
    2 4 2 HalfEven 1 0 2 HalfEven

# Formatting retains the requested display scale but may not discard digits.
# Parsing every successful result back to the native type must recover the
# same canonical value, including negative and exponent-normalized inputs.
golden format_parse format-parse \
    1.2 2 -1.2 2 1000 2 0.001 4 12.34 1 0 3

# Decimal and Float side by side, which is what makes keeping two types
# worthwhile. A backend that implemented one by delegating to the other would
# produce two identical columns; every line here except the exactly
# representable `1.0 / 4.0` must differ, and that one is kept precisely so the
# corpus is not just "the columns always disagree".
#
# The last two lines differ in *kind* rather than in digits: division by zero
# is a checked outcome with no value on one side and an infinity on the other,
# and 2^53+1 is a value binary64 cannot hold at all.
golden contrast contrast \
    add 0.1 0.2 \
    add 1.005 0.005 \
    mul 1.1 1.1 \
    mul 0.1 0.1 \
    sub 0.3 0.1 \
    div 1.0 4.0 \
    div 1.0 3.0 \
    div 1.0 0.0 \
    add 9007199254740993 1

# --- the emission contract for generated code (issue #723) -----------------
#
# Slice 4 requires Decimal to work *on a backend*, which means the runtime has
# to reach generated programs. The decision (2026-07-26) is that stage2 splices
# `decimal_v1.h` and `decimal_v1.c` at compile time rather than embedding a
# copy: one source of truth, so the emitted runtime cannot drift from the one
# these goldens test.
#
# That decision only holds if the splice actually compiles standalone, under
# the same flags the c11 backend adapter uses and with no extra sources. This
# builds it exactly as the adapter would and runs #710's headline expression
# through the value shim, in the exact shape the lowering will emit.
#
# It is here rather than in the lowering because it constrains `decimal_v1.c`,
# not the compiler: adding an include, a non-static helper that collides, or
# anything needing a separate translation unit breaks emission, and this is
# where that shows up.
{
    grep -v '^#include "decimal_v1.h"' "$ROOT/bootstrap/stage2/decimal_v1.h" |
        grep -v '^#ifndef KOFUN_STAGE2_DECIMAL_V1_H' |
        grep -v '^#define KOFUN_STAGE2_DECIMAL_V1_H' |
        grep -v '^#endif'
    grep -v '^#include "decimal_v1.h"' "$ROOT/bootstrap/stage2/decimal_v1.c"
    cat <<'PROGRAM'

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 1) decimal_fatal(KOFUN_DECIMAL_DIGIT_LIMIT);
    printf("%s\n",
        kofun_decimal_equal(
            kofun_decimal_value_add(
                kofun_decimal_value_literal("0.1", 3),
                kofun_decimal_value_literal("0.2", 3)),
            kofun_decimal_value_literal("0.3", 3)) ? "true" : "false");
    kofun_decimal_arena_release();
    return 0;
}
PROGRAM
} >"$WORK/spliced.c"
# The adapter's exact flags: `tests/conformance/backends/c11-stage1.sh` builds
# emitted C with these and nothing else. Adding -pedantic here would test a
# stricter contract than the backend actually applies.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror "$WORK/spliced.c" -o "$WORK/spliced"
printf 'true\n' >"$WORK/spliced.expected"
"$WORK/spliced" >"$WORK/spliced.observed" 2>&1
cmp "$WORK/spliced.expected" "$WORK/spliced.observed" ||
    fail "0.1 + 0.2 == 0.3 did not hold in a spliced standalone program"
printf '%s\n' "PASS: the runtime splices into a standalone program and 0.1 + 0.2 == 0.3"

# The generated-code shim exits on an unrepresentable result. Pin the complete
# diagnostic so its stable code is not accidentally prefixed twice or replaced
# with an allocation-dependent message.
set +e
"$WORK/spliced" force-resource-failure \
    >"$WORK/spliced-fatal.stdout" 2>"$WORK/spliced-fatal.observed"
spliced_fatal_status=$?
set -e
if test "$spliced_fatal_status" -ne 1; then
    fail "generated Decimal resource failure exited $spliced_fatal_status instead of 1"
fi
printf '%s\n' \
    "error[D001]: Decimal significand exceeds the profile's digit limit" \
    >"$WORK/spliced-fatal.expected"
cmp "$WORK/spliced-fatal.expected" "$WORK/spliced-fatal.observed" ||
    fail "generated Decimal resource failure diagnostic changed"
test ! -s "$WORK/spliced-fatal.stdout" ||
    fail "generated Decimal resource failure wrote stdout"
printf '%s\n' "PASS: generated Decimal resource failures preserve one canonical diagnostic"

# Sanitizers, matching what the other Stage 2 module gates do. An
# arbitrary-precision buffer that grows by doubling is exactly the shape where
# an off-by-one survives a golden comparison.
if "$CC" -std=c11 -x c -fsanitize=address,undefined \
        -o "$WORK/probe" - >/dev/null 2>&1 <<'EOF'
int main(void) { return 0; }
EOF
then
    "$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
        -fno-omit-frame-pointer -fsanitize=address,undefined \
        -I"$ROOT/bootstrap/stage2" \
        "$ROOT/bootstrap/stage2/decimal_v1.c" \
        "$CASES/decimal_v1_test.c" \
        -o "$WORK/decimal-test-sanitized"
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" construct \
        1.5 1000 0.1 170141183460469231731687303715884105728 0 \
        >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" equal 1.0 1 1000 1e3 0.1 0.2 \
        >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" float 0.1 5e-324 1e308 1e23 \
        >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" limit digits-over >/dev/null
    # The arithmetic allocates far more than construction does: alignment
    # grows an operand by a power of ten, multiplication allocates the full
    # product, and the general division path normalizes both operands into
    # scratch buffers. Every one of those is swept here.
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" add 0.1 0.2 1e-6000 1e6000 \
        >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" mul \
        123456789012345678901234567890 987654321098765432109876543210 \
        >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" div \
        9999999999999999999999999999999 3333333333333333333333333333333 \
        1.0 3.0 1.0 0.0 \
        >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" identity 0.1 0.2 0.3 >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" contrast div 1.0 0.0 add 0.1 0.2 \
        >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" round \
        2.5 0 HalfUp -2.5 0 HalfEven 1.999 2 HalfUp >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" rounded-divide \
        1 8 2 HalfEven -1 3 2 Floor 1 0 2 HalfUp >/dev/null
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/decimal-test-sanitized" format-parse \
        1.2 2 -1.2 2 1000 2 0.001 4 12.34 1 >/dev/null
    # The arena is the one allocation the generated program never frees
    # explicitly, so leak detection on the spliced binary is what proves
    # `kofun_decimal_arena_release` actually reaches every value.
    "$CC" -std=c11 -O1 -g -fno-omit-frame-pointer \
        -fsanitize=address,undefined \
        -Wall -Wextra -Werror \
        "$WORK/spliced.c" -o "$WORK/spliced-sanitized"
    ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
    UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
        "$WORK/spliced-sanitized" >/dev/null
    printf '%s\n' "PASS: AddressSanitizer and UndefinedBehaviorSanitizer"
else
    printf '%s\n' "SKIP: sanitizers unavailable"
fi

printf '%s\n' \
    "PASS: Decimal slices 2, 4, and 5 — arbitrary-precision representation," \
    "  versioned resource profile v$( \
        "$WORK/decimal-test" profile | \
        sed -n 's/^profile-version=//p'), exact binary64," \
    "  exact +, -, * with checked exact division," \
    "  and explicit rounding, formatting, and parsing"
