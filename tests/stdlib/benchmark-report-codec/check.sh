#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/stdlib/benchmark-report-codec"
WORK=${KOFUN_BENCHMARK_REPORT_CODEC_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}benchmark-report-codec"}
CC=${CC:-cc}
SANITIZER_CC=${SANITIZER_CC:-clang}
ASSERT_CONTEXT='benchmark report codec'
. "$ROOT/tests/assertions/assert.sh"

case $WORK in
    */benchmark-report-codec|*/benchmark-report-codec.*) ;;
    *) assert_fail "work directory must end in benchmark-report-codec[.suffix]: $WORK" ;;
esac
command -v node >/dev/null 2>&1 || assert_fail 'node is required for the independent oracle'
command -v "$CC" >/dev/null 2>&1 || assert_fail 'a C11 compiler is required'
command -v "$SANITIZER_CC" >/dev/null 2>&1 || assert_fail 'clang (or SANITIZER_CC) is required for strict sanitizer builds'
rm -rf "$WORK"
mkdir -p "$WORK"

# The harness reads fixtures. The production library only borrows Bytes.
grep -vE '^[[:space:]]*#' "$CASES/codec.kofun" >"$WORK/codec.code"
assert_not_grep 'production codec has an ambient dependency' -Eq -- \
    '(^import |read_file|write_file|fopen|socket|random|clock_gettime|JSON)' "$WORK/codec.code"
assert_not_grep 'production codec declares a standalone program' -Eq -- '^fn main' "$WORK/codec.code"

node "$CASES/fixtures.mjs" prepare "$WORK"
cat "$ROOT/tests/stdlib/benchmark-report-model/model.kofun" \
    "$CASES/codec.kofun" "$WORK/main.kofun" >"$WORK/program.kofun"
"$ROOT/bin/kofun" build "$WORK/program.kofun" -o "$WORK/program" \
    --emit-c "$WORK/codec.c" >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    assert_fail "Kofun codec did not build: $(cat "$WORK/build.stderr")"
printf '0\n0\n1210\n1\n' >"$WORK/expected.stdout"
"$WORK/program" >"$WORK/program.stdout" || assert_fail 'source codec did not execute'
"$WORK/program" >"$WORK/program.repeat.stdout" || assert_fail 'source codec repeat did not execute'
cmp "$WORK/expected.stdout" "$WORK/program.stdout" || assert_fail 'source caller differs from the canonical fixture'
cmp "$WORK/program.stdout" "$WORK/program.repeat.stdout" || assert_fail 'source caller repeat differs'

for level in 0 2
do
    "$CC" -std=c11 "-O$level" -Wall -Wextra -Werror -pedantic \
        -I "$WORK" "$CASES/driver.c" -o "$WORK/driver.O$level" ||
        assert_fail "strict C11 driver did not build at O$level"
    node "$CASES/fixtures.mjs" check "$WORK" "$WORK/driver.O$level" faults \
        >"$WORK/driver.O$level.stdout" || assert_fail "O$level codec matrix failed"
    "$SANITIZER_CC" -std=c11 "-O$level" -g -Wall -Wextra -Werror -pedantic \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        -I "$WORK" "$CASES/driver.c" -o "$WORK/driver.san.O$level" ||
        assert_fail "sanitized driver did not build at O$level"
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
        node "$CASES/fixtures.mjs" check "$WORK" "$WORK/driver.san.O$level" faults \
        >"$WORK/driver.san.O$level.stdout" || assert_fail "sanitized O$level codec matrix failed"
    cmp "$WORK/driver.O0.stdout" "$WORK/driver.O$level.stdout" || assert_fail 'optimization changed outcomes'
    cmp "$WORK/driver.O0.stdout" "$WORK/driver.san.O$level.stdout" || assert_fail 'sanitizers changed outcomes'
done
cat "$WORK/driver.O0.stdout"
printf '%s\n' 'PASS: production codec agrees at O0/O2, on repeat, and under ASan/UBSan'
