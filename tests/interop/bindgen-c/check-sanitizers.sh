#!/bin/sh
set -eu

# bindgen-c sanitizer gate (#900).
#
# The stage-1 gate builds the generated boundary and runs it. It does not
# compile either side with a sanitizer, so a use-after-free in the fixture
# library or an out-of-bounds write reached through a generated declaration
# would run to completion and print the right numbers. This gate closes that:
#
#   * libkbfix.so and the generated-boundary driver are BOTH built with
#     AddressSanitizer and UndefinedBehaviorSanitizer, so a fault on either
#     side of the boundary is attributed to the frame that caused it rather
#     than lost in an uninstrumented library. The gate asserts both binaries
#     really carry the instrumentation before trusting a green run;
#
#   * the driver must still reproduce driver.stdout byte for byte, with an
#     empty stderr and a zero exit. Any sanitizer diagnostic at all is a hard
#     failure — `halt_on_error=1` and `-fno-sanitize-recover=all` mean a
#     report is also a nonzero exit, and the gate checks both;
#
#   * detect_leaks is ON, deliberately. The fixture's contract is
#     client-owned handles: kbfix_counter_new must be paired with
#     kbfix_counter_free. A leaked handle is the exact ownership defect this
#     boundary cannot check statically, so LeakSanitizer is where it gets
#     caught. A runner that cannot run LeakSanitizer fails loudly here rather
#     than passing quietly;
#
#   * the paths the checked C ABI profile cannot express from Kofun — a
#     writable buffer and a function pointer — are exercised against the same
#     sanitized library by fixture/kbfix_probe.c, whose entry points must all
#     be bound symbols in the audit report;
#
#   * three arm-specific negative fixtures MUST fail: kbfix_negative.c with an
#     AddressSanitizer report naming kbfix.c, kbfix_leak.c with a
#     LeakSanitizer report, and kbfix_undefined.c with a library-side
#     UndefinedBehaviorSanitizer report. Without those probes, a green run
#     could survive with one or more configured sanitizer arms switched off.
#
# Offline: one committed header, one committed library source, clang.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/interop/bindgen-c"
ASSERT_CONTEXT="bindgen-c sanitizers"
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-bindgen-san.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

for required in clang node readelf; do
    command -v "$required" >/dev/null 2>&1 ||
        assert_fail "required tool unavailable: $required"
done

assert_regular_file 'pinned fixture header' "$CASES/fixture/kbfix.h"
assert_regular_file 'pinned fixture implementation' "$CASES/fixture/kbfix.c"
assert_regular_file 'sanitizer probe source' "$CASES/fixture/kbfix_probe.c"
assert_regular_file 'sanitizer probe golden' "$CASES/fixture/kbfix_probe.stdout"
assert_regular_file 'sanitizer negative fixture' "$CASES/fixture/kbfix_negative.c"
assert_regular_file 'LeakSanitizer negative fixture' "$CASES/fixture/kbfix_leak.c"
assert_regular_file 'UndefinedBehaviorSanitizer negative fixture' "$CASES/fixture/kbfix_undefined.c"
assert_regular_file 'driver golden' "$CASES/driver.stdout"

SANITIZE='-fsanitize=address,undefined -fno-sanitize-recover=all'
HARDEN='-fno-omit-frame-pointer -g'
WARN='-std=c11 -O1 -Wall -Wextra -Werror'

ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:detect_stack_use_after_return=1:strict_string_checks=1
UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1
export ASAN_OPTIONS UBSAN_OPTIONS

# ------------------------------------------------ pick a sanitizing compiler
#
# #900 names Clang, and clang is tried first. Clang can only link the
# sanitizer runtimes when compiler-rt is installed beside it, which is a
# packaging choice of the host rather than a property of the source, so the
# gate probes for a compiler that can actually link `-fsanitize=address` and
# names the one it used. An environment where *no* compiler can is a failure,
# not a skip — the same rule bootstrap/c_abi/check.sh applies to rustc.
printf 'int main(void) { return 0; }\n' >"$WORK/link-probe.c"
SAN_CC=
for candidate in ${KOFUN_SANITIZER_CC:-} clang gcc cc; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2086
    if "$candidate" $WARN $SANITIZE "$WORK/link-probe.c" -o "$WORK/link-probe" \
        >"$WORK/link-probe.log" 2>&1
    then
        SAN_CC=$candidate
        break
    fi
done
if test -z "$SAN_CC"; then
    assert_fail "no available C compiler can link -fsanitize=address,undefined; last attempt said: $(cat "$WORK/link-probe.log")"
fi

# --------------------------------------------------- sanitized fixture library

library="$WORK/libkbfix.so"
# shellcheck disable=SC2086
"$SAN_CC" $WARN $SANITIZE $HARDEN -shared -fPIC -DKBFIX_EXTRA=1 \
    "$CASES/fixture/kbfix.c" -o "$library" 2>"$WORK/library.err" ||
    assert_fail "sanitized fixture library did not compile: $(cat "$WORK/library.err")"
readelf --wide --dyn-syms "$library" >"$WORK/library.syms"
assert_grep 'the fixture library carries no AddressSanitizer instrumentation' \
    -q -- '__asan_' "$WORK/library.syms"

# ------------------------------------ sanitized generated-boundary driver

(
    CDPATH= cd -- "$CASES" &&
        "$ROOT/bin/kofun" bindgen-c fixture/kbfix.h \
            --out-dir "$WORK/gen" --module kbfix
) >"$WORK/gen.stdout" 2>"$WORK/gen.stderr" ||
    assert_fail "bindgen failed: $(cat "$WORK/gen.stderr")"
report="$WORK/gen/kbfix.bindgen.json"
assert_regular_file 'generated audit report' "$report"

# The single-file `--c-abi` profile has no modules and no visibility keywords,
# so the module framing #1217 added is removed before this build, exactly as
# `check.sh` does. This gate is about what happens at the boundary under ASan
# and UBSan; the framing is what `import-boundary/run.sh` builds and runs.
sed -e '/^module kbfix$/d' -e '/^trust raw-foreign$/d' \
    -e 's/^pub extern "C" fn /extern "C" fn /' "$WORK/gen/kbfix.raw.kofun" \
    >"$WORK/module-declarations.kofun"
cat "$WORK/module-declarations.kofun" "$CASES/driver.kofun" \
    >"$WORK/program.kofun"

# `kofun build` emits C and links it in one operation. The link is not
# optional, so it must use the same sanitizer runtime as the instrumented
# library even though the resulting executable is replaced below. A tiny CC
# wrapper keeps this gate on the public build surface without teaching the
# product CLI test-only sanitizer flags.
SAN_CC_WRAPPER="$WORK/sanitizer-cc"
printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'exec "$KOFUN_SANITIZER_REAL_CC" \' \
    '    -fsanitize=address,undefined -fno-sanitize-recover=all \' \
    '    -fno-omit-frame-pointer -g "$@"' \
    >"$SAN_CC_WRAPPER"
chmod 700 "$SAN_CC_WRAPPER"
sh -n "$SAN_CC_WRAPPER"

KOFUN_SANITIZER_REAL_CC="$SAN_CC" \
CC="$SAN_CC_WRAPPER" \
KOFUN_C_ABI_BUILD_DIR="$WORK/c-abi-build" \
    "$ROOT/bin/kofun" build "$WORK/program.kofun" --backend c --c-abi \
    --link-library "$library" --emit-c "$WORK/program.c" \
    -o "$WORK/program-profile" \
    >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    assert_fail "generated module did not build in the C ABI profile: $(cat "$WORK/build.stderr")"
assert_file_nonempty 'emitted C for the generated boundary' "$WORK/program.c"

# The emitted C is the generated boundary; it is recompiled here with the
# sanitizers rather than trusting the profile's own unsanitized build.
# shellcheck disable=SC2086
"$SAN_CC" $WARN $SANITIZE $HARDEN "$WORK/program.c" "$library" \
    -o "$WORK/driver" 2>"$WORK/driver.build.err" ||
    assert_fail "the generated boundary did not compile under sanitizers: $(cat "$WORK/driver.build.err")"
readelf --wide --dyn-syms "$WORK/driver" >"$WORK/driver.syms"
assert_grep 'the generated-boundary driver carries no AddressSanitizer instrumentation' \
    -q -- '__asan_' "$WORK/driver.syms"

status=0
"$WORK/driver" >"$WORK/driver.out" 2>"$WORK/driver.err" || status=$?
# The sanitizer report is the observation, so it goes in the failure text. A
# gate that said only "exited 1" would send the reader back to run it again.
if test "$status" -ne 0; then
    assert_fail "the sanitized generated boundary exited $status: $(head -c 2048 "$WORK/driver.err")"
fi
assert_file_empty 'the sanitized generated boundary produced a sanitizer diagnostic' \
    "$WORK/driver.err"
cmp "$CASES/driver.stdout" "$WORK/driver.out" ||
    assert_fail 'the sanitized driver decisions differ from the recorded golden'

# ------------------------------- pointer paths the Kofun driver cannot reach

node "$CASES/check-report.mjs" symbols "$report" >"$WORK/bound-symbols.txt"
for entry in kbfix_counter_new kbfix_counter_free kbfix_counter_add \
    kbfix_counter_value kbfix_counter_on_change kbfix_label_copy
do
    assert_grep "sanitizer probe calls $entry, which the report does not bind" \
        -Fqx -- "$entry" "$WORK/bound-symbols.txt"
    assert_grep "sanitizer probe no longer exercises $entry" \
        -Fq -- "$entry" "$CASES/fixture/kbfix_probe.c"
done

# shellcheck disable=SC2086
"$SAN_CC" $WARN $SANITIZE $HARDEN -I "$CASES/fixture" \
    "$CASES/fixture/kbfix_probe.c" "$library" -o "$WORK/probe" \
    2>"$WORK/probe.build.err" ||
    assert_fail "the sanitizer probe did not compile: $(cat "$WORK/probe.build.err")"
status=0
"$WORK/probe" >"$WORK/probe.out" 2>"$WORK/probe.err" || status=$?
if test "$status" -ne 0; then
    assert_fail "the sanitizer probe exited $status: $(head -c 2048 "$WORK/probe.err")"
fi
assert_file_empty 'the sanitizer probe produced a sanitizer diagnostic' \
    "$WORK/probe.err"
cmp "$CASES/fixture/kbfix_probe.stdout" "$WORK/probe.out" ||
    assert_fail 'the buffer/length and callback decisions differ from the recorded golden'

# ------------------------------------------- the negative fixture must fail

# shellcheck disable=SC2086
"$SAN_CC" $WARN $SANITIZE $HARDEN -I "$CASES/fixture" \
    "$CASES/fixture/kbfix_negative.c" "$library" -o "$WORK/negative" \
    2>"$WORK/negative.build.err" ||
    assert_fail "the negative fixture did not compile: $(cat "$WORK/negative.build.err")"
status=0
"$WORK/negative" >"$WORK/negative.out" 2>"$WORK/negative.err" || status=$?
if test "$status" -eq 0; then
    assert_fail 'the negative fixture exited zero; the sanitizer gate is not armed and every green run above proves nothing'
fi
assert_grep 'the negative fixture failed without an AddressSanitizer report' \
    -Fq -- 'AddressSanitizer' "$WORK/negative.err"
assert_grep 'the negative fixture failed without attributing the fault to the fixture library' \
    -Fq -- 'kbfix.c' "$WORK/negative.err"
assert_grep 'the negative fixture is not the heap overflow it claims to be' \
    -Fq -- 'heap-buffer-overflow' "$WORK/negative.err"

# ------------------------------- every configured sanitizer arm must fail

# A clean run cannot distinguish an armed sanitizer from a missing one. Each
# remaining arm therefore gets one isolated fault built with the exact flags
# and fixture library used above. The leak crosses the library's documented
# client-owned handle boundary; the signed overflow occurs inside kbfix.c.
run_sanitizer_arm_probe() {
    probe_name=$1
    fixture_source=$2
    expected_diagnostic=$3

    # shellcheck disable=SC2086
    "$SAN_CC" $WARN $SANITIZE $HARDEN -I "$CASES/fixture" \
        "$fixture_source" "$library" -o "$WORK/$probe_name" \
        2>"$WORK/$probe_name.build.err" ||
        assert_fail "the $probe_name fixture did not compile: $(cat "$WORK/$probe_name.build.err")"
    status=0
    "$WORK/$probe_name" >"$WORK/$probe_name.out" \
        2>"$WORK/$probe_name.err" || status=$?
    if test "$status" -eq 0; then
        assert_fail "the $probe_name fixture exited zero; its sanitizer arm is not proven armed"
    fi
    assert_grep "$probe_name fixture failed without its arm-specific diagnostic" \
        -Fq -- "$expected_diagnostic" "$WORK/$probe_name.err"
}

run_sanitizer_arm_probe \
    leak "$CASES/fixture/kbfix_leak.c" \
    'LeakSanitizer: detected memory leaks'
run_sanitizer_arm_probe \
    undefined "$CASES/fixture/kbfix_undefined.c" \
    'runtime error: signed integer overflow'
assert_not_grep 'the leak fixture also triggered UndefinedBehaviorSanitizer' \
    -Fq -- 'runtime error:' "$WORK/leak.err"
assert_not_grep 'the leak fixture also triggered AddressSanitizer' \
    -Fq -- 'ERROR: AddressSanitizer' "$WORK/leak.err"
assert_not_grep 'the undefined-behavior fixture also triggered AddressSanitizer' \
    -Fq -- 'ERROR: AddressSanitizer' "$WORK/undefined.err"
assert_not_grep 'the undefined-behavior fixture also triggered LeakSanitizer' \
    -Fq -- 'LeakSanitizer:' "$WORK/undefined.err"
assert_grep 'the undefined-behavior fixture did not fault inside the fixture library' \
    -Fq -- 'kbfix.c' "$WORK/undefined.err"

printf 'bindgen-c: fixture library and generated boundary are both sanitizer-instrumented: PASS\n'
printf 'bindgen-c: the sanitized boundary reproduces its golden with no diagnostic (%s, detect_leaks=1): PASS\n' "$SAN_CC"
printf 'bindgen-c: buffer/length and callback paths run clean against the sanitized library: PASS\n'
printf 'bindgen-c: the negative fixture still faults inside the library, so the gate is armed: PASS\n'
printf 'bindgen-c: a leaked client-owned handle proves LeakSanitizer is armed: PASS\n'
printf 'bindgen-c: a library-side signed overflow proves UndefinedBehaviorSanitizer is armed: PASS\n'
