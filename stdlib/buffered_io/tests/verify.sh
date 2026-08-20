#!/bin/sh
set -eu

# #1510. A bounded buffered line reader over the Linux file adapter.
#
# Three instruments, for the reason stdlib/entropy states and this file
# re-measures rather than inherits: neither half compiles. `bin/kofun check` on
# any file in stdlib/linux_x86_64 stops at its first `import`, and
# `trusted intrinsic` is refused at top level in both pipelines, so `raw_read`
# is unreachable from any compilable program.
#
#   1. source properties on both halves, including the one that makes "portable"
#      a measurement rather than a claim;
#   2. an executable Int-Core projection of the state machine over twelve
#      scripted sources, against a golden;
#   3. an independent C11 oracle over the same scripts, compared byte for byte.

buffered_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$buffered_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-buffered-io-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'buffered io: FAIL: %s\n' "$*" >&2
    exit 1
}

portable="$buffered_dir/buffered_io.kofun"
adapter="$buffered_dir/linux_x86_64.kofun"
test -f "$portable" || fail 'the portable half is missing'
test -f "$adapter" || fail 'the adapter half is missing'

# --------------------------------------------- the portable half is portable
#
# `stdlib/capabilities.tsv` puts this row in the `portable` tier, and the
# charter defines that tier as including "the portable half of any capability
# whose other half is a platform adapter". The half here may name exactly one
# module from the platform directory -- `bytes`, because the byte surface lives
# there -- and that module must itself reach no syscall. Both are measured, so
# the day either stops being true this says so instead of the tier quietly
# becoming a label.

# Comments are stripped first. The first version of this check failed on the
# portable half's own comment, which quotes the command being run -- a checker
# that reads prose is measuring the wrong file.
code_without_comments() {
    grep -vE '^[[:space:]]*#' "$1"
}

[ "$(code_without_comments "$portable" | grep -cE 'raw_|syscall')" -eq 0 ] ||
    fail 'the portable half names a syscall'

for imported in $(grep '^import stdlib.linux_x86_64' "$portable" || true)
do
    case $imported in
        import|stdlib.linux_x86_64.bytes) ;;
        *) fail "the portable half imports a platform module other than bytes: $imported" ;;
    esac
done

[ "$(code_without_comments "$repo_dir/stdlib/linux_x86_64/bytes.kofun" |
    grep -cE 'raw_|syscall')" -eq 0 ] ||
    fail 'stdlib/linux_x86_64/bytes.kofun grew a syscall; the portable half is no longer portable'

grep -Fq 'let BUFFERED_LINE_FEED = 10' "$portable" ||
    fail 'the reader does not split on LF'

printf 'buffered io portable half reaches no syscall: PASS\n'

# ------------------------------------------------- the adapter half's contract

grep -Fq 'fn buffered_read_line(' "$adapter" ||
    fail 'the reader entry point is missing'
grep -Fq 'read file: File' "$adapter" ||
    fail 'the reader does not borrow the file; an affine File must stay with its caller'
grep -Fq 'Err(error) if error.errno == EINTR' "$adapter" ||
    fail 'the refill step does not retry EINTR'
[ "$(grep -c 'file_read(' "$adapter")" -eq 1 ] ||
    fail 'the adapter does not read at exactly one point'
grep -Fq 'return Err(BufferedLineTooLong(buffered_capacity(reader)))' "$adapter" ||
    fail 'a line the buffer cannot hold does not report the capacity'
grep -Fq 'buffered_slice(reader, reader.filled)' "$adapter" ||
    fail 'a final line with no line feed is not returned'
grep -Fq 'if buffered_pending(reader) == 0' "$adapter" ||
    fail 'end of input is not answered from state'

printf 'buffered io adapter contract: PASS\n'

# --------------------------------------------------------------- the projection

"$repo_dir/bin/kofun" run "$buffered_dir/tests/checkpoint.kofun" \
    >"$work/checkpoint.stdout"
cmp "$buffered_dir/tests/checkpoint.stdout" "$work/checkpoint.stdout" ||
    fail 'the projected state machine differs from its golden'

# Named cases, so a golden that changes shape is not silently re-blessed. The
# line numbers are positions in the golden; each comment is the property.
[ "$(sed -n '13p' "$work/checkpoint.stdout")" -eq 3 ] ||
    fail 'a final line with no line feed was not returned whole'
[ "$(sed -n '17p' "$work/checkpoint.stdout")" -eq 1 ] ||
    fail 'an empty source did not cost exactly one read'
[ "$(sed -n '18p' "$work/checkpoint.stdout")" -eq 1 ] ||
    fail 'an empty source did not end in the state that answers Eof without reading'
[ "$(sed -n '24p' "$work/checkpoint.stdout")" -eq 0 ] ||
    fail 'an empty line was not preserved'
[ "$(sed -n '26p' "$work/checkpoint.stdout")" -eq 1 ] ||
    fail 'a line longer than the buffer was not refused'
[ "$(sed -n '32p' "$work/checkpoint.stdout")" -eq 1 ] &&
[ "$(sed -n '35p' "$work/checkpoint.stdout")" -eq 7 ] ||
    fail 'a line of exactly capacity-minus-terminator did not fit'
[ "$(sed -n '37p' "$work/checkpoint.stdout")" -eq 1 ] ||
    fail 'one byte over capacity was not refused'
[ "$(sed -n '44p' "$work/checkpoint.stdout")" -eq 7 ] &&
[ "$(sed -n '46p' "$work/checkpoint.stdout")" -eq 2 ] &&
[ "$(sed -n '47p' "$work/checkpoint.stdout")" -eq 2 ] ||
    fail 'one byte per read did not produce the same lines'
[ "$(sed -n '49p' "$work/checkpoint.stdout")" -eq 0 ] &&
[ "$(sed -n '51p' "$work/checkpoint.stdout")" -eq 3 ] ||
    fail 'an EINTR was surfaced instead of retried'
[ "$(sed -n '59p' "$work/checkpoint.stdout")" -eq 7 ] ||
    fail 'a line spanning two refills was not joined'
[ "$(sed -n '65p' "$work/checkpoint.stdout")" -eq 3 ] ||
    fail 'a NUL inside a line was not preserved'
[ "$(sed -n '67p' "$work/checkpoint.stdout")" -eq 2 ] &&
[ "$(sed -n '68p' "$work/checkpoint.stdout")" -eq 1 ] ||
    fail 'a read error after a line lost the line or the error'

printf 'buffered io state machine against its golden: PASS\n'

# --------------------------------------------------------------- the C11 oracle

cc=${CC:-cc}
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$buffered_dir/tests/buffered_io_reference.c" -o "$work/buffered-io-reference"
"$work/buffered-io-reference" >"$work/reference.stdout"
cmp "$buffered_dir/tests/checkpoint.stdout" "$work/reference.stdout" ||
    fail 'the independent C11 oracle differs'

printf 'buffered io C11 differential oracle: PASS\n'

# ------------------------------------------------------------- the oracle bound

binding="$buffered_dir/tests/oracle-binding.json"
for pair in "portable_sha256 $portable" "adapter_sha256 $adapter" \
    "oracle_sha256 $buffered_dir/tests/buffered_io_reference.c"
do
    key=${pair%% *}
    path=${pair#* }
    hash=$("$repo_dir/bin/kofun-digest" "$path" | awk '{ print $1 }')
    grep -Fq "\"$key\": \"$hash\"" "$binding" ||
        fail "the oracle binding does not name the current $key"
done
grep -Fq '"file_read_executed": false' "$binding" ||
    fail 'the oracle binding does not disclaim reading a real file'

printf 'buffered io oracle bound to the source it mirrors: PASS\n'
