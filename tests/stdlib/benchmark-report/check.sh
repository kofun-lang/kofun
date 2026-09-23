#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/stdlib/benchmark-report"
WORK=${KOFUN_BENCHMARK_REPORT_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}benchmark-report"}
CC=${CC:-cc}
SANITIZER_CC=${SANITIZER_CC:-clang}
ASSERT_CONTEXT='benchmark report certification'
. "$ROOT/tests/assertions/assert.sh"

case $WORK in
    */benchmark-report|*/benchmark-report.*) ;;
    *) assert_fail "work directory must end in benchmark-report[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK"
node "$CASES/oracle.mjs" >"$WORK/expected.stdout"
cat "$ROOT/tests/stdlib/benchmark-report-model/model.kofun" \
    "$ROOT/tests/stdlib/benchmark-report-codec/codec.kofun" \
    "$ROOT/tests/stdlib/benchmark-report-model/compare.kofun" \
    "$CASES/corpus.kofun" >"$WORK/program.kofun"
assert_not_grep 'production report path has an ambient input or publisher' -Eq -- \
    '(^import |stage2_bytes_read_file|read_text|write_text|clock_gettime|socket|random)' "$WORK/program.kofun"
"$ROOT/bin/kofun" build "$WORK/program.kofun" -o "$WORK/program" \
    --emit-c "$WORK/program.c" >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    assert_fail "production report path did not build: $(cat "$WORK/build.stderr")"

check_program() {
    binary=$1
    "$binary" >"$binary.stdout" 2>"$binary.stderr" || assert_fail "execution failed: $binary"
    assert_file_empty 'production report path emitted a diagnostic' "$binary.stderr"
    cmp "$WORK/expected.stdout" "$binary.stdout" || assert_fail "report path disagrees with independent oracle: $binary"
    "$binary" >"$binary.repeat.stdout" 2>"$binary.repeat.stderr" || assert_fail "repeat failed: $binary"
    assert_file_empty 'repeated report path emitted a diagnostic' "$binary.repeat.stderr"
    cmp "$binary.stdout" "$binary.repeat.stdout" || assert_fail "report path changed on repeat: $binary"
}
check_program "$WORK/program"
# The pair emits the complete private Bytes helper family. Its three helpers
# unused by this source need explicit references in a strict Clang client.
# This entry wrapper delegates all behavior to the unchanged Kofun program.
cat >"$WORK/entry.c" <<'C'
#define main certification_source_main
#include "program.c"
#undef main
int main(void) {
    (void)kofun_bytes_take;
    (void)stage2_bytes_append_self;
    (void)stage2_bytes_read_file;
    return certification_source_main();
}
C
for level in 0 2
do
    "$CC" -std=c11 "-O$level" -Wall -Wextra -Werror -pedantic \
        "$WORK/entry.c" -o "$WORK/program.O$level"
    check_program "$WORK/program.O$level"
    "$SANITIZER_CC" -std=c11 "-O$level" -g -Wall -Wextra -Werror -pedantic \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        "$WORK/entry.c" -o "$WORK/program.san.O$level"
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
        check_program "$WORK/program.san.O$level"
done
printf '%s\n' \
    'PASS: production model -> canonical Bytes -> decode -> comparison, all 49 fields and 64+36 samples' \
    'PASS: both complete wires exceed 4 KiB; unavailable differs from available zero; identity is not normalized' \
    'PASS: neutral errors and cancellation preserve complete prior bytes or an empty destination' \
    'PASS: independent contract oracle agrees at O0/O2, on repeat, and under ASan/UBSan'
