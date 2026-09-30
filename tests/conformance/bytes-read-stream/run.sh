#!/usr/bin/env sh
# #1667. A program the C11 Stage 2 backend compiles digests any-length input in
# bounded chunks, from a regular file named by path or from standard input.
#
# The decision is `spec/c11-command-io-v1.md` (#1665): a new bounded operation
# reads at most 65,536 bytes from one open stream, reports the bytes read and a
# zero-byte end-of-input chunk, and reports a failure as the `Int` status a
# program continues past. The source surface is
#
#   stage2_bytes_stream_open(path: Text)  -> Int   (0 opened, 1 refused)
#   stage2_bytes_stream_stdin()           -> Int   (always 0)
#   stage2_bytes_stream_read(carrier)     -> Int   (count, 0 at end, negative failure)
#
# Four things are proved here, and each one the issue named:
#
#   1. a compiled program reads a named file in chunks, absorbs every block
#      with the pair's own `sha256_absorb`, and prints the same digest as
#      `bin/kofun-digest`. The SHA-256 block is extracted from
#      `compiler.kofun` exactly as `tests/stage2/sha256-pair/check.sh` extracts
#      it, so this digests with the shipped functions, not a copy of them;
#   2. the same program reading standard input -- piped, not `/dev/stdin` by
#      path -- matches at the same sizes;
#   3. no read places more than 65,536 bytes in the carrier, asserted on the
#      carrier length after every read, and a mutant that stops after the first
#      chunk fails at 65,537 bytes while the real program passes;
#   4. a missing path, an unreadable path, and a spent allocator are each a
#      status the program observes and keeps running past.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/bytes-read-stream"
WORK=${KOFUN_BYTES_READ_STREAM_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}bytes-read-stream"}
KOFUN=${KOFUN_BYTES_READ_STREAM_KOFUN:-"$ROOT/bin/kofun"}
CC=${CC:-cc}
PAIR_KOFUN="$ROOT/bootstrap/stage2/compiler.kofun"
PAIR_C="$ROOT/bootstrap/stage2/compiler.c"
. "$ROOT/bootstrap/stage2/build.sh"

fail() {
    printf '%s\n' "FAIL: bytes read stream: $1" >&2
    exit 1
}

command -v "$CC" >/dev/null 2>&1 || fail 'a C11 compiler is required'
command -v node >/dev/null 2>&1 || fail 'node is required for the pair check'
case $WORK in
    */bytes-read-stream|*/bytes-read-stream.*) ;;
    *) fail "work directory must end in bytes-read-stream[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/inputs"

COMPILER="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$COMPILER"

# Compile one source to C with the C half, then link it. `--compile-outcome`
# writes the C only on success, so a positive program that refused fails here
# rather than at the run.
emit_c() {
    program=$1
    source=$2
    "$COMPILER" --compile-outcome \
        "$source" "$program.c" "$program.ir" "$program.tokens" \
        >"$program.build.stdout" 2>"$program.build.stderr" ||
        fail "$(basename "$source") did not compile: $(head -n 1 "$program.build.stdout")"
    test ! -s "$program.build.stderr" ||
        fail "$(basename "$source") wrote internal stderr"
}

link_c() {
    out=$1
    cfile=$2
    shift 2
    "$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic "$@" \
        "$cfile" -o "$out" 2>"$out.cc" ||
        fail "$(basename "$cfile") emitted C that does not compile: $(head -n 1 "$out.cc")"
}

build() {
    emit_c "$1" "$2"
    link_c "$1" "$1.c"
}

# ------------------------------------------------------------ the inputs
#
# Sizes chosen at the edges the chunk is stated in. `over_bound.bin` and
# `two_chunks_plus.bin` are the two the chunked read must span; the two will
# not both be exercised by one count, so a `head` that came up short cannot
# turn a success into a false one.
INPUTS="$WORK/inputs"
head -c 65537 /dev/zero | tr '\0' 'a' >"$INPUTS/over_bound.bin"
head -c 65536 /dev/zero | tr '\0' 'b' >"$INPUTS/at_bound.bin"
head -c 65535 /dev/zero | tr '\0' 'u' >"$INPUTS/under_bound.bin"
head -c 131073 /dev/zero | tr '\0' 'c' >"$INPUTS/two_chunks_plus.bin"
head -c 200 "$PAIR_KOFUN" >"$INPUTS/four_blocks.bin"
printf 'The quick brown fox jumps over the lazy dog' >"$INPUTS/message.bin"
: >"$INPUTS/empty.bin"
cp "$INPUTS/two_chunks_plus.bin" "$INPUTS/large.bin"
mkdir -p "$INPUTS/unreadable.d"
rm -f "$INPUTS/missing.bin"
for check in over_bound.bin:65537 at_bound.bin:65536 under_bound.bin:65535 \
    two_chunks_plus.bin:131073 message.bin:43; do
    name=${check%%:*}
    want=${check##*:}
    test "$(wc -c <"$INPUTS/$name" | tr -d ' ')" -eq "$want" ||
        fail "$name is not $want bytes"
done

# ------------------------------------------------------- the SHA-256 block
#
# The block, extracted from `compiler.kofun` between its marker and `fn main`
# as `tests/stage2/sha256-pair/check.sh` extracts it. The template's only
# private knowledge is the padded byte, the partial block, and the open
# preamble; the block, the schedule, the compression, and the hex are the
# pair's.
start=$(grep -n '^# ---* SHA-256$' "$PAIR_KOFUN" | cut -d: -f1)
test -n "$start" || fail 'compiler.kofun no longer carries the SHA-256 marker'
end=$(grep -n '^fn main() -> Int {' "$PAIR_KOFUN" | cut -d: -f1)
test -n "$end" || fail 'compiler.kofun no longer carries a main'
awk -v a="$start" -v b="$((end - 1))" 'NR>=a && NR<=b' "$PAIR_KOFUN" \
    >"$WORK/sha256-block.kofun"
test "$(grep -c '^fn sha256' "$WORK/sha256-block.kofun")" -eq 21 ||
    fail 'the extracted block does not carry every sha256 function'

# Materialize a digest program: the block, then the template with `@@OPEN@@`
# replaced by the caller's open preamble, which may span several lines.
materialize() {
    open_block=$1
    out=$2
    {
        cat "$WORK/sha256-block.kofun"
        awk -v open="$open_block" \
            '{ if ($0 == "@@OPEN@@") print open; else print }' \
            "$CASES/digest_stream_main.kofun.in"
    } >"$out"
}

# ------------------------------------------------------------- file digests
#
# Each program opens its input by a literal path. The two compiler sources are
# opened by their real path in the tree at run time, so their digest follows
# the file rather than a pinned copy.
digest_file() {
    stem=$1
    path=$2
    materialize \
        "    let opened = stage2_bytes_stream_open(\"$path\")" \
        "$WORK/digest_$stem.kofun"
    build "$WORK/digest_$stem" "$WORK/digest_$stem.kofun"
    (cd "$INPUTS" && "$WORK/digest_$stem" >"$WORK/digest_$stem.out" \
        2>"$WORK/digest_$stem.err") ||
        fail "the file digest for $stem did not run: $(head -n 1 "$WORK/digest_$stem.err")"
    test ! -s "$WORK/digest_$stem.err" ||
        fail "the file digest for $stem wrote to stderr"
    expected=$("$ROOT/bin/kofun-digest" "$path" | cut -d' ' -f1)
    test "$(cat "$WORK/digest_$stem.out")" = "$expected" ||
        fail "the file digest for $stem printed $(cat "$WORK/digest_$stem.out"); kofun-digest says $expected"
}

digest_file empty "$INPUTS/empty.bin"
digest_file message "$INPUTS/message.bin"
digest_file four_blocks "$INPUTS/four_blocks.bin"
digest_file under_bound "$INPUTS/under_bound.bin"
digest_file at_bound "$INPUTS/at_bound.bin"
digest_file over_bound "$INPUTS/over_bound.bin"
digest_file two_chunks_plus "$INPUTS/two_chunks_plus.bin"
digest_file pair_kofun "$PAIR_KOFUN"
digest_file pair_c "$PAIR_C"

# ------------------------------------------------------------ stdin digests
materialize "    let opened = stage2_bytes_stream_stdin()" "$WORK/digest_stdin.kofun"
build "$WORK/digest_stdin" "$WORK/digest_stdin.kofun"

digest_stdin() {
    stem=$1
    path=$2
    cat "$path" | "$WORK/digest_stdin" >"$WORK/stdin_$stem.out" \
        2>"$WORK/stdin_$stem.err" ||
        fail "the stdin digest for $stem did not run: $(head -n 1 "$WORK/stdin_$stem.err")"
    test ! -s "$WORK/stdin_$stem.err" ||
        fail "the stdin digest for $stem wrote to stderr"
    expected=$("$ROOT/bin/kofun-digest" "$path" | cut -d' ' -f1)
    test "$(cat "$WORK/stdin_$stem.out")" = "$expected" ||
        fail "the stdin digest for $stem printed $(cat "$WORK/stdin_$stem.out"); kofun-digest says $expected"
}

digest_stdin empty "$INPUTS/empty.bin"
digest_stdin under_bound "$INPUTS/under_bound.bin"
digest_stdin at_bound "$INPUTS/at_bound.bin"
digest_stdin over_bound "$INPUTS/over_bound.bin"
digest_stdin two_chunks_plus "$INPUTS/two_chunks_plus.bin"
digest_stdin pair_kofun "$PAIR_KOFUN"
digest_stdin pair_c "$PAIR_C"

# --------------------------------------------------- a failed open, then a good
#
# The decision's observability: a missing path is a status, not a terminal
# diagnostic, so the program reads a present file afterwards and prints its
# digest. `missing.bin` is absent from `$INPUTS`.
materialize \
    "    let missing = stage2_bytes_stream_open(\"missing.bin\")
    print(missing)
    let opened = stage2_bytes_stream_open(\"$INPUTS/message.bin\")
    print(opened)" \
    "$WORK/digest_recover.kofun"
build "$WORK/digest_recover" "$WORK/digest_recover.kofun"
(cd "$INPUTS" && "$WORK/digest_recover" >"$WORK/recover.out" 2>"$WORK/recover.err") ||
    fail 'the recover program exited non-zero'
test ! -s "$WORK/recover.err" || fail 'the recover program wrote to stderr'
expected=$("$ROOT/bin/kofun-digest" "$INPUTS/message.bin" | cut -d' ' -f1)
{
    printf '%s\n' '1'
    printf '%s\n' '0'
    printf '%s\n' "$expected"
} >"$WORK/recover.expected"
cmp "$WORK/recover.expected" "$WORK/recover.out" >/dev/null ||
    fail 'a failed open was not a status the program continued past'

# ---------------------------------------------------- the carrier ceiling
#
# Every printed length is the carrier's own length after a read, not the
# returned count, so a read that over-filled the carrier would fail here even
# if its return value lied. The final line must be the zero-byte end chunk.
build "$WORK/carrier_lengths" "$CASES/stream_carrier_lengths.kofun"
(cd "$INPUTS" && "$WORK/carrier_lengths" >"$WORK/lengths.out" \
    2>"$WORK/lengths.err") ||
    fail "the carrier-length program did not run: $(head -n 1 "$WORK/lengths.err")"
test ! -s "$WORK/lengths.err" || fail 'the carrier-length program wrote to stderr'
test "$(wc -l <"$WORK/lengths.out" | tr -d ' ')" -eq 5 ||
    fail 'a 131,073-byte input was not read as three chunks and an end chunk'
awk 'NR == 1 { if ($1 != 0) exit 1; next }
     { if ($1 < 0 || $1 > 65536) exit 2; last = $1 }
     END { if (last != 0) exit 3 }' "$WORK/lengths.out" ||
    fail 'a read placed more than 65,536 bytes in the carrier, or did not end at a zero-byte chunk'

# ---------------------------------------------------- observable failures
#
# An unreadable path: on a platform where `fopen` refuses a directory the open
# status is 1; where it accepts one the read is the failure. Both are a status
# the program continues past.
build "$WORK/unreadable" "$CASES/stream_unreadable.kofun"
(cd "$INPUTS" && "$WORK/unreadable" >"$WORK/unreadable.out" \
    2>"$WORK/unreadable.err") ||
    fail 'the unreadable-path program exited non-zero'
test ! -s "$WORK/unreadable.err" || fail 'the unreadable-path program wrote to stderr'
opened=$(sed -n '1p' "$WORK/unreadable.out")
read_status=$(sed -n '2p' "$WORK/unreadable.out")
if test "$opened" -eq 1; then
    :
elif test "$opened" -eq 0 && test "$read_status" -eq -1; then
    :
else
    fail "an unreadable path reported opened=$opened read=$read_status"
fi

# A spent allocator: the same emitted C under the carrier's allocation seam.
emit_c "$WORK/alloc_observe" "$CASES/stream_alloc_observe.kofun"
link_c "$WORK/alloc_observe" "$WORK/alloc_observe.c"
(cd "$INPUTS" && "$WORK/alloc_observe" >"$WORK/alloc_observe.out" \
    2>"$WORK/alloc_observe.err") ||
    fail 'the allocator fixture did not run under the ordinary allocator'
test "$(sed -n '1p' "$WORK/alloc_observe.out")" = 0 ||
    fail 'the allocator fixture did not open its file'
test "$(sed -n '2p' "$WORK/alloc_observe.out")" = 43 ||
    fail 'the allocator fixture did not read its file under the ordinary allocator'
link_c "$WORK/alloc_observe_spent" "$WORK/alloc_observe.c" \
    -DKOFUN_BYTES_INJECT_ALLOC_BUDGET=0
(cd "$INPUTS" && "$WORK/alloc_observe_spent" >"$WORK/alloc_observe_spent.out" \
    2>"$WORK/alloc_observe_spent.err") ||
    fail 'the spent-allocator fixture exited non-zero instead of observing the status'
test ! -s "$WORK/alloc_observe_spent.err" ||
    fail 'the spent-allocator fixture ended on a diagnostic instead of a status'
test "$(sed -n '1p' "$WORK/alloc_observe_spent.out")" = 0 ||
    fail 'the spent-allocator fixture did not open its file'
test "$(sed -n '2p' "$WORK/alloc_observe_spent.out")" = -2 ||
    fail 'a spent allocator was not observable as the -2 read status'

# --------------------------------------------- the old-pass/new-fail mutant
#
# A copy of the 65,537-byte program whose stream read stops after its first
# call. It is a chunk reader that never reads the second chunk: the digest at
# 65,536 bytes is right (one chunk), and the digest at 65,537 bytes is wrong,
# while the unmutated program is right at both. That is the boundary the
# chunked read exists for.
mutant() {
    program=$1
    sed 's|^static inline int64_t stage2_bytes_stream_read(KofunBytesValue \*value) {$|static inline int64_t stage2_bytes_stream_read(KofunBytesValue *value) { static int kofun_mutant_reads; if (kofun_mutant_reads++) { value->length = 0; return 0; }|' \
        "$program.c" >"$WORK/mutant_$(basename "$program").c"
    grep -q 'kofun_mutant_reads' "$WORK/mutant_$(basename "$program").c" ||
        fail 'the mutant did not patch the stream read'
    link_c "$WORK/mutant_$(basename "$program")" \
        "$WORK/mutant_$(basename "$program").c"
}
mutant "$WORK/digest_over_bound"
mutant "$WORK/digest_at_bound"
(cd "$INPUTS" && "$WORK/mutant_digest_at_bound" >"$WORK/mutant_at_bound.out") ||
    fail 'the mutant did not run at 65,536 bytes'
expected=$("$ROOT/bin/kofun-digest" "$INPUTS/at_bound.bin" | cut -d' ' -f1)
test "$(cat "$WORK/mutant_at_bound.out")" = "$expected" ||
    fail 'the mutant stopped after the first chunk at 65,536 bytes, where one chunk is the whole input'
(cd "$INPUTS" && "$WORK/mutant_digest_over_bound" >"$WORK/mutant_over_bound.out") ||
    fail 'the mutant did not run at 65,537 bytes'
expected=$("$ROOT/bin/kofun-digest" "$INPUTS/over_bound.bin" | cut -d' ' -f1)
test "$(cat "$WORK/mutant_over_bound.out")" != "$expected" ||
    fail 'the mutant that stops after the first chunk passed at 65,537 bytes'

# ---------------------------------------------- neither surface is emitted
printf 'fn main() -> Int {\n    print(0)\n    return 0\n}\n' \
    >"$WORK/plain.kofun"
emit_c "$WORK/plain" "$WORK/plain.kofun"
grep -q 'int main(void) {' "$WORK/plain.c" ||
    fail 'a program without the stream surface changed its entrypoint'
! grep -q 'kofun_stream_\|KOFUN_STREAM\|stage2_bytes_stream_' "$WORK/plain.c" ||
    fail 'a program without the stream surface emitted the stream runtime'
printf 'fn main() -> Int {\n    let bytes = stage2_bytes_empty()\n    print(stage2_bytes_len(bytes))\n    return 0\n}\n' \
    >"$WORK/bytes_only.kofun"
emit_c "$WORK/bytes_only" "$WORK/bytes_only.kofun"
! grep -q 'kofun_stream_' "$WORK/bytes_only.c" ||
    fail 'a Bytes program that never opens a stream emitted the stream runtime'

# --------------------------------------------------------- the shipped CLI
#
# `bin/kofun build` is what a user runs, so one positive program goes through
# it. The C half is handed in so the build does not compile the seed again.
mkdir -p "$WORK/cli"
KOFUN_STAGE2_COMPILER="$COMPILER" \
KOFUN_BUILD_DIR="$WORK/cli/stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/cli/stage2" \
    "$KOFUN" build "$CASES/stream_probe.kofun" -o "$WORK/cli/probe" \
    --emit-c "$WORK/cli/probe.c" \
    >"$WORK/cli/probe.build.stdout" 2>"$WORK/cli/probe.build.stderr" ||
    fail "bin/kofun build did not build the stream program: $(head -n 1 "$WORK/cli/probe.build.stderr")"
(cd "$INPUTS" && "$WORK/cli/probe" >"$WORK/cli/probe.out" \
    2>"$WORK/cli/probe.err") ||
    fail 'the bin/kofun-built stream program exited non-zero'
test ! -s "$WORK/cli/probe.err" ||
    fail 'the bin/kofun-built stream program wrote to stderr'
printf '0\n%s\n%s\n%s\n' \
    "$(wc -c <"$INPUTS/message.bin" | tr -d ' ')" \
    "$(wc -c <"$INPUTS/message.bin" | tr -d ' ')" \
    "$(od -An -tu1 -N1 "$INPUTS/message.bin" | tr -d ' ')" \
    >"$WORK/cli/probe.expected"
cmp "$WORK/cli/probe.expected" "$WORK/cli/probe.out" >/dev/null ||
    fail 'the bin/kofun-built stream program did not print its statuses'

# ----------------------------------------------------------------- the pair
# Every ASCII fixture, through both halves, on outcome, emitted C, and scope
# HIR. The extracted SHA-256 block is not passed: it carries three non-ASCII
# comment bytes, and the host interpreter's Unicode validator hook is answered
# by the ASCII assumption this corpus is built on.
node "$CASES/pair.mjs" "$COMPILER" "$WORK/pair" "$CASES"/*.kofun

printf '%s\n' \
    "PASS: a compiled program reads a file in 65,536-byte chunks and digests it with the pair's sha256_* functions, matching bin/kofun-digest for 0, 65,535, 65,536, 65,537 and 131,073 bytes and for bootstrap/stage2/compiler.{kofun,c} read at run time" \
    'PASS: the same program reading piped standard input matches bin/kofun-digest at the same sizes, and no read places more than 65,536 bytes in the carrier' \
    'PASS: a mutant that stops after the first chunk is right at 65,536 bytes and wrong at 65,537, while the real program is right at both' \
    'PASS: a missing path, an unreadable path, and a spent allocator are each an Int status the program observes and keeps running past, and a program that opens no stream is unchanged'
