#!/usr/bin/env sh
# #1322. The Text bridge over #1315's Managed Bytes carrier: a Text into a
# carrier as its exact UTF-8 bytes, and a checked byte range back out as Text.
#
# The shape is #1499's, and the reason is `spec/bytes-bounded-v1.md` §7: a
# status is private to the emitted C, because a compiler-owned type has no
# declaration site for Stage 2 to resolve. So `stage2_bytes_assign_text` is a
# discarded statement like the mutations it sits beside, and
# `stage2_bytes_text` returns the Text a program asked for -- with a runtime
# diagnostic and an empty result when the range, the 255-byte Text limit, an
# embedded NUL, or ill-formed UTF-8 refuses it, in that precedence. The exact
# tag/detail contract the issue specifies lives in the emitted
# `stage2_bytes_text_check`, and is proved here by a driver compiled against a
# prelude extracted from a program the compiler just emitted -- the shipped
# bytes, not a copy of them kept in step by hand.
#
# Four things are proved:
#
#   1. the source surface: a fixture that assigns, converts, and prints, at
#      both optimisation levels under the sanitizers, against its golden;
#   2. the four runtime refusals (R029..R032) are each exact stderr, exit 1,
#      and nothing printed after them; and the private-status operation is
#      refused as a value (E2S179) with no artifact;
#   3. the runtime: the three bridge functions are defined exactly once, after
#      the mutation family, and are the only place tags 6..8 are produced;
#      both pair halves and the runtime name the same two operations;
#   4. the contract: every range rule, the limit and its precedence over a
#      later NUL or ill-formed byte, every UTF-8 family with the exact
#      absolute detail, earliest-wins, and a refused allocation that leaves
#      the carrier exactly as it found it.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/bytes-text"
WORK=${KOFUN_BYTES_TEXT_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}bytes-text"}
KOFUN=${KOFUN_BYTES_TEXT_KOFUN:-"$ROOT/bin/kofun"}
CC=${CC:-cc}

fail() {
    printf '%s\n' "FAIL: bytes text: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'

rm -rf "$WORK"
mkdir -p "$WORK"

# ------------------------------------------------------------ source surface
executes() {
    stem=$1
    label=$2
    "$KOFUN" build "$CASES/$stem.kofun" -o "$WORK/$stem.bin" \
        --emit-c "$WORK/$stem.c" >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr" ||
        fail "$label did not build: $(head -n 1 "$WORK/$stem.stderr")"
    for level in 0 2
    do
        "$CC" -std=c11 "-O$level" -g -fsanitize=address,undefined \
            -I "$ROOT/unicode" "$WORK/$stem.c" -o "$WORK/$stem.O$level" \
            2>"$WORK/$stem.cc.O$level" ||
            fail "$label emitted C that does not compile at -O$level"
        ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
            "$WORK/$stem.O$level" >"$WORK/$stem.out.O$level" 2>&1 ||
            fail "$label did not run clean under the sanitizers at -O$level"
        cmp "$CASES/$stem.stdout" "$WORK/$stem.out.O$level" ||
            fail "$label printed unexpected output at -O$level"
    done
}

executes bridge 'the Text bridge source fixture'

# The bridge lowers through the family's one emitter: a carrier by address,
# the Text and the Ints as ordinary expressions, and the read borrow in
# `measure` without a second address-of.
grep -q 'stage2_bytes_assign_text(&k_b' "$WORK/bridge.c" ||
    fail 'assign_text did not take the carrier by address'
grep -q 'stage2_bytes_text(&k_b' "$WORK/bridge.c" ||
    fail 'text did not take the carrier by address'
grep -q 'stage2_bytes_len(k_b' "$WORK/bridge.c" ||
    fail 'the read borrow gained a second address-of'

# ------------------------------------------------------------ the refusals
#
# Each runtime fixture is a whole program that converts, then prints. The
# print must never happen: a runtime refusal ends the program.
runtime_refusal() {
    stem=$1
    code=$2
    "$KOFUN" build "$CASES/$stem.kofun" -o "$WORK/$stem.unused" \
        --emit-c "$WORK/$stem.c" >"$WORK/$stem.build.stdout" \
        2>"$WORK/$stem.build.stderr" ||
        fail "$stem did not build: $(head -n 1 "$WORK/$stem.build.stderr")"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic -I "$ROOT/unicode" \
        "$WORK/$stem.c" -o "$WORK/$stem" 2>"$WORK/$stem.cc" ||
        fail "$stem emitted C that does not compile: $(head -n 1 "$WORK/$stem.cc")"
    for run in first second
    do
        set +e
        "$WORK/$stem" >"$WORK/$stem.$run.stdout" 2>"$WORK/$stem.$run.stderr"
        status=$?
        set -e
        test "$status" -eq 1 ||
            fail "$stem exited $status instead of 1 on its $run run"
        cmp "$CASES/$stem.stderr" "$WORK/$stem.$run.stderr" >/dev/null ||
            fail "$stem did not report its golden diagnostic on its $run run"
        grep -qF "error[$code]:" "$WORK/$stem.$run.stderr" ||
            fail "$stem did not name $code"
        test ! -s "$WORK/$stem.$run.stdout" ||
            fail "$stem printed after its refusal on its $run run"
    done
}

runtime_refusal text_out_of_range R029
runtime_refusal text_over_limit R030
runtime_refusal text_contains_nul R031
runtime_refusal text_not_utf8 R032

# The private-status operation as a value: refused at compile time, by the
# same rule as the mutation family (#1559), and no C is committed.
set +e
"$KOFUN" build "$CASES/assign_text_value.kofun" -o "$WORK/assign_text_value.bin" \
    --emit-c "$WORK/assign_text_value.c" >"$WORK/assign_text_value.stdout" \
    2>"$WORK/assign_text_value.stderr"
value_status=$?
set -e
test "$value_status" -ne 0 ||
    fail 'assign_text was accepted as a source value'
# `bin/kofun build` relays the compiler's refusal on stderr; the golden is the
# compiler's own line, compared exactly and held under the sidecar bound.
cmp "$CASES/assign_text_value.stdout" "$WORK/assign_text_value.stderr" ||
    fail 'assign_text as a value did not report its golden E2S179'
test "$(sed -n '1p' "$WORK/assign_text_value.stderr" | wc -c)" -lt 160 ||
    fail 'the E2S179 detail exceeds the typed-sidecar bound'
test ! -e "$WORK/assign_text_value.c" ||
    fail 'assign_text as a value committed C'
test ! -e "$WORK/assign_text_value.bin" ||
    fail 'assign_text as a value committed a binary'

# ------------------------------------------------------------ the runtime
#
# The prelude, extracted from the program the compiler just emitted, ending
# at the last bridge function. The mutation family's own gate extracts up to
# `read_file` and asserts none of tags 6..8 appear before that point; this
# one asserts they appear after it, in exactly the bridge.
bridge_start=$(
    awk '/^static inline KofunBytesStatus stage2_bytes_text_check\(/ {print NR; exit}' \
        "$WORK/bridge.c"
)
test -n "$bridge_start" ||
    fail 'the emitted C carries no stage2_bytes_text_check to extract'
prelude_end=$(
    awk '/^static inline const char \*stage2_bytes_text\(/ {found = 1}
         found && /^\}$/ {print NR; exit}' "$WORK/bridge.c"
)
test -n "$prelude_end" ||
    fail 'the emitted C carries no stage2_bytes_text to extract'
sed -n "1,${prelude_end}p" "$WORK/bridge.c" >"$WORK/prelude.h"

read_file_end=$(
    awk '/^static inline KofunBytesStatus stage2_bytes_read_file\(/ {found = 1}
         found && /^\}$/ {print NR; exit}' "$WORK/prelude.h"
)
test -n "$read_file_end" ||
    fail 'the prelude carries no stage2_bytes_read_file'
test "$read_file_end" -lt "$bridge_start" ||
    fail 'the bridge is emitted before the mutation family, not after it'

for operation in stage2_bytes_text_check stage2_bytes_assign_text stage2_bytes_text
do
    defined=$(grep -c "^static inline .*[ *]$operation(" "$WORK/prelude.h")
    test "$defined" -eq 1 ||
        fail "$operation is defined $defined times in the emitted runtime"
done

# Tags 6..8 are produced by the bridge and by nothing else in the runtime.
sed -n "1,${bridge_start}p" "$WORK/prelude.h" |
    sed -n "/^static inline .*stage2_bytes_len(/,\$p" >"$WORK/before-bridge.c"
if grep -qE 'KOFUN_BYTES_(INVALID_UTF8|TEXT_CONTAINS_NUL|TEXT_LIMIT_EXCEEDED)' \
    "$WORK/before-bridge.c"
then
    fail 'an operation before the bridge emits a Text-bridge tag'
fi
sed -n "${bridge_start},\$p" "$WORK/prelude.h" >"$WORK/bridge-only.c"
for tag in KOFUN_BYTES_INVALID_UTF8 KOFUN_BYTES_TEXT_CONTAINS_NUL KOFUN_BYTES_TEXT_LIMIT_EXCEEDED
do
    grep -q "$tag" "$WORK/bridge-only.c" ||
        fail "the bridge never produces $tag"
done

# The vocabulary, derived from each half of the pair and from the runtime.
sed -n '/^fn bytes_text_builtin/,/^}$/p' "$ROOT/bootstrap/stage2/compiler.kofun" |
    grep -o 'stage2_bytes_[a-z_]*' | sort -u >"$WORK/vocabulary.kofun"
sed -n '/^static const char \*const kofun_bytes_text_operations/,/^};$/p' \
    "$ROOT/bootstrap/stage2/compiler.c" |
    grep -o 'stage2_bytes_[a-z_]*' | sort -u >"$WORK/vocabulary.c"
grep -o '^static inline [A-Za-z0-9_ ]*\*\{0,1\}\(stage2_bytes_[a-z_]*\)(' \
    "$WORK/bridge-only.c" |
    grep -o 'stage2_bytes_[a-z_]*' |
    grep -v -e '^stage2_bytes_text_check$' |
    sort -u >"$WORK/vocabulary.runtime"
test -s "$WORK/vocabulary.kofun" ||
    fail 'no bridge vocabulary could be read from compiler.kofun'
cmp "$WORK/vocabulary.kofun" "$WORK/vocabulary.c" ||
    fail 'the two halves of the pair name different bridge operations'
cmp "$WORK/vocabulary.kofun" "$WORK/vocabulary.runtime" ||
    fail 'the operations the compiler admits and the runtime defines differ'

# ------------------------------------------------------------ the driver
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I "$WORK" -I "$ROOT/unicode" "$CASES/text_driver.c" \
    -o "$WORK/driver" 2>"$WORK/driver.cc" ||
    fail "the driver did not build: $(head -n 1 "$WORK/driver.cc")"
"$WORK/driver" >"$WORK/driver.out" 2>"$WORK/driver.stderr" ||
    fail "the bridge contract failed: $(head -n 1 "$WORK/driver.out")"
# The source-facing half raises exactly its three diagnostics, in the order
# the driver provokes them, and nothing else reaches stderr.
{
    printf 'error[R029]: bounded Bytes text range out of range\n'
    printf 'error[R031]: bounded Bytes text contains NUL\n'
    printf 'error[R032]: bounded Bytes text is not UTF-8\n'
} >"$WORK/driver.expected.stderr"
cmp "$WORK/driver.expected.stderr" "$WORK/driver.stderr" ||
    fail 'the source-facing conversions did not raise exactly their diagnostics'

"$CC" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I "$WORK" -I "$ROOT/unicode" "$CASES/text_driver.c" \
    -o "$WORK/driver.sanitized" 2>"$WORK/driver.sanitized.cc" ||
    fail 'the sanitized driver did not build'
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/driver.sanitized" >"$WORK/driver.sanitized.out" 2>"$WORK/driver.sanitized.stderr" ||
    fail "the sanitized driver failed: $(head -n 1 "$WORK/driver.sanitized.out")"
cmp "$WORK/driver.out" "$WORK/driver.sanitized.out" ||
    fail 'the sanitized driver observed something the plain one did not'

# A spent allocation budget: the first assignment into an empty carrier
# cannot get storage and must leave the carrier exactly as it found it.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_BYTES_INJECT_ALLOC_BUDGET=0 \
    -I "$WORK" -I "$ROOT/unicode" "$CASES/text_driver.c" \
    -o "$WORK/driver.oom" 2>"$WORK/driver.oom.cc" ||
    fail 'the allocation-failure driver did not build'
"$WORK/driver.oom" >"$WORK/driver.oom.out" 2>"$WORK/driver.oom.stderr" ||
    fail "the allocation-failure contract failed: $(head -n 1 "$WORK/driver.oom.out")"
test ! -s "$WORK/driver.oom.stderr" ||
    fail 'a refused assignment raised a runtime diagnostic; it is a private status'

printf '%s\n' \
    'PASS: a Text crosses into a Bytes carrier as its exact bytes and a checked range crosses back as Text, at both optimisation levels under the sanitizers' \
    'PASS: range, limit, NUL, and UTF-8 refusals are named runtime diagnostics (R029..R032) with nothing printed after them, and assign_text as a value is E2S179 with no artifact' \
    'PASS: the bridge is emitted once, after the mutation family, is the only producer of tags 6..8, and both pair halves and the runtime name the same two operations' \
    'PASS: every range rule, the limit and its precedence, every UTF-8 family with its absolute detail, earliest-wins, and a refused allocation hold in the emitted C'
