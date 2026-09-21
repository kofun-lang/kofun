#!/usr/bin/env sh
# #1499. A program the C11 Stage 2 backend compiles can read a file's bytes.
#
# Before this gate a compiled program could reach nothing outside its own
# source: `read_text`, `args`, and `chars` are all `E2S10`, and the one
# carrier that could hold a file -- `Bytes[65536]` -- had no operation to fill
# it and none to get a byte back out. Two operations changed that:
# `stage2_bytes_read_file` fills a carrier from a path, and
# `stage2_bytes_byte_at` returns the byte as an `Int`.
#
# Three things are proved here, each one the issue named:
#
#   1. a compiled program reads a file and digests it with the pair's own
#      `sha256_*` functions, matching `bin/kofun-digest` on the same file.
#      The SHA-256 block is extracted from `compiler.kofun` exactly as
#      `tests/stage2/sha256-pair/check.sh` extracts it, so this digests with
#      the shipped functions, not a copy of them;
#   2. a file over the 65,536-byte bound fails with a named diagnostic rather
#      than truncating, proved by supplying one;
#   3. the four runtime refusals (R025..R028) are each exact stderr, exit 1,
#      and registered, so the bound is pinned rather than incidental.
#
# The path a program reads is a `Text` literal in its source -- `args` is
# still `E2S10` -- so every program here runs from the directory that holds
# its inputs and names them relatively.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/bytes-read-file"
WORK=${KOFUN_BYTES_READ_FILE_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}bytes-read-file"}
KOFUN=${KOFUN_BYTES_READ_FILE_KOFUN:-"$ROOT/bin/kofun"}
CC=${CC:-cc}
PAIR_KOFUN="$ROOT/bootstrap/stage2/compiler.kofun"

fail() {
    printf '%s\n' "FAIL: bytes read file: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'

rm -rf "$WORK"
INPUTS="$WORK/inputs"
mkdir -p "$INPUTS"

# ------------------------------------------------------------ the inputs
#
# Sizes chosen at the edges the bound is stated in. `over_bound.bin` is the
# one that must fail, and both edge files are counted, so a `head` that came
# up short cannot turn a refusal proof into a success. The four-block file is
# the head of `compiler.kofun`: varied bytes, and not all one value.
head -c 65537 /dev/zero | tr '\0' 'a' >"$INPUTS/over_bound.bin"
head -c 65536 /dev/zero | tr '\0' 'b' >"$INPUTS/at_bound.bin"
head -c 200 "$PAIR_KOFUN" >"$INPUTS/four_blocks.bin"
printf 'The quick brown fox jumps over the lazy dog' >"$INPUTS/message.bin"
: >"$INPUTS/empty.bin"
rm -f "$INPUTS/missing.bin"
test "$(wc -c <"$INPUTS/over_bound.bin" | tr -d ' ')" -eq 65537 ||
    fail 'over_bound.bin is not 65537 bytes'
test "$(wc -c <"$INPUTS/at_bound.bin" | tr -d ' ')" -eq 65536 ||
    fail 'at_bound.bin is not 65536 bytes'
test "$(wc -c <"$INPUTS/message.bin" | tr -d ' ')" -eq 43 ||
    fail 'message.bin is not 43 bytes'

# ------------------------------------------------------------ the refusals
#
# Each fixture is a whole program that reads or indexes, then prints. The
# print must never happen: a runtime refusal ends the program, and one that
# went on would be digesting the carrier it started with as if it were the
# file. The emitted C is compiled here rather than by `bin/kofun build` so
# the allocation refusal can be reached: R028 needs the runtime's own fault
# seam, `KOFUN_BYTES_INJECT_ALLOC_BUDGET`, which is a compile-time definition.
runtime_refusal() {
    stem=$1
    code=$2
    shift 2
    "$KOFUN" build "$CASES/$stem.kofun" -o "$WORK/$stem.unused" \
        --emit-c "$WORK/$stem.c" >"$WORK/$stem.build.stdout" \
        2>"$WORK/$stem.build.stderr" ||
        fail "$stem did not build: $(head -n 1 "$WORK/$stem.build.stderr")"
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic "$@" \
        "$WORK/$stem.c" -o "$WORK/$stem" 2>"$WORK/$stem.cc" ||
        fail "$stem emitted C that does not compile: $(head -n 1 "$WORK/$stem.cc")"
    for run in first second
    do
        set +e
        (cd "$INPUTS" && "$WORK/$stem" >"$WORK/$stem.$run.stdout" \
            2>"$WORK/$stem.$run.stderr")
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

runtime_refusal byte_at_out_of_range R025
runtime_refusal read_missing_path R026
runtime_refusal read_over_bound R027
runtime_refusal read_cannot_allocate R028 -DKOFUN_BYTES_INJECT_ALLOC_BUDGET=0

# The allocation fixture is a positive program under the ordinary allocator:
# the same emitted C, without the seam, reads its 43-byte file. Without this
# the R028 proof could be met by a program that fails for any reason at all.
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$WORK/read_cannot_allocate.c" -o "$WORK/read_can_allocate" \
    2>"$WORK/read_can_allocate.cc" ||
    fail 'the allocation fixture did not compile without the seam'
(cd "$INPUTS" && "$WORK/read_can_allocate" >"$WORK/read_can_allocate.stdout" \
    2>"$WORK/read_can_allocate.stderr") ||
    fail 'the allocation fixture did not run under the ordinary allocator'
test "$(cat "$WORK/read_can_allocate.stdout")" = 43 ||
    fail 'the allocation fixture did not read its file under the ordinary allocator'

# ------------------------------------------------------------ the digest
#
# The SHA-256 block, extracted from `compiler.kofun` between its marker and
# `fn main` as `tests/stage2/sha256-pair/check.sh` extracts it, with a main
# appended from the template beside this script. The template's only private
# knowledge is the padded byte, written against `byte_at`; the block, the
# schedule, the compression, and the hex are the pair's.
start=$(grep -n '^# ---* SHA-256$' "$PAIR_KOFUN" | cut -d: -f1)
test -n "$start" || fail 'compiler.kofun no longer carries the SHA-256 marker'
end=$(grep -n '^fn main() -> Int {' "$PAIR_KOFUN" | cut -d: -f1)
test -n "$end" || fail 'compiler.kofun no longer carries a main'
awk -v a="$start" -v b="$((end - 1))" 'NR>=a && NR<=b' "$PAIR_KOFUN" \
    >"$WORK/sha256-block.kofun"
test "$(grep -c '^fn sha256' "$WORK/sha256-block.kofun")" -eq 21 ||
    fail 'the extracted block does not carry every sha256 function'

digests() {
    input=$1
    stem="digest-$input"
    {
        cat "$WORK/sha256-block.kofun"
        sed "s|@@PATH@@|$input|" "$CASES/digest_main.kofun.in"
    } >"$WORK/$stem.kofun"
    "$KOFUN" build "$WORK/$stem.kofun" -o "$WORK/$stem.bin" \
        --emit-c "$WORK/$stem.c" >"$WORK/$stem.build.stdout" \
        2>"$WORK/$stem.build.stderr" ||
        fail "the digest program for $input did not build: $(head -n 1 "$WORK/$stem.build.stderr")"
    (cd "$INPUTS" && "$WORK/$stem.bin" >"$WORK/$stem.stdout" \
        2>"$WORK/$stem.stderr") ||
        fail "the digest program for $input did not run: $(head -n 1 "$WORK/$stem.stderr")"
    test ! -s "$WORK/$stem.stderr" ||
        fail "the digest program for $input wrote to stderr"
    expected=$("$ROOT/bin/kofun-digest" "$INPUTS/$input" | cut -d' ' -f1)
    test "$(cat "$WORK/$stem.stdout")" = "$expected" ||
        fail "the digest program for $input printed $(cat "$WORK/$stem.stdout"); kofun-digest says $expected"
}

digests empty.bin
digests message.bin
digests four_blocks.bin
digests at_bound.bin

printf '%s\n' \
    "PASS: a compiled program reads a file into a Bytes[65536] carrier and digests it with the pair's sha256_* functions, matching bin/kofun-digest for an empty, a one-block, a four-block, and a 65536-byte file" \
    'PASS: a byte read outside the carrier, a missing path, a file over the 65536-byte bound, and a read under a spent allocator each end the program with exit 1 and exactly their registered runtime diagnostic (R025, R026, R027, R028), print nothing after it, and report identically on a second run' \
    'PASS: the allocation-refusal fixture reads its file under the ordinary allocator'
