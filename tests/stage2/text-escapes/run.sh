#!/bin/sh
set -eu

# #1357. The closed `Text` escape set, and what happens outside it.
#
# The accepted case is checked by `len` and by the printed bytes rather than by
# `cc` agreeing to compile the result: before this, every escape meant whatever
# the host C compiler decided, and a golden that only proved the program built
# would have passed on a host whose `cc` implemented a different set.
#
# The emitted C is also read directly. The point of the change is that the
# compiler re-encodes what it decoded, so an escape the source never contained
# must not appear in the artifact -- which a stdout golden cannot see.

root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
fixtures="$root/tests/stage2/text-escapes"
work=${TMPDIR:-/tmp}/kofun-stage2-text-escapes.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"
ASSERT_CONTEXT='stage2 text escapes'
. "$root/tests/assertions/assert.sh"

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    echo "text-escapes: a C11 compiler is required" >&2
    exit 1
fi

. "$root/bootstrap/stage2/build.sh"
kofun_stage2_build "$root" "$work/kofun-stage2"

"$work/kofun-stage2" "$fixtures/accepted.kofun" \
    "$work/accepted.c" "$work/accepted.ir" "$work/accepted.tokens" \
    >"$work/accepted.compile" 2>"$work/accepted.compile.stderr" ||
    assert_fail "accepted did not compile: $(cat "$work/accepted.compile.stderr")"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I "$root/unicode" "$work/accepted.c" -o "$work/accepted.bin" ||
    assert_fail 'the accepted escapes emitted C that a strict C11 compiler rejects'
"$work/accepted.bin" >"$work/accepted.stdout"
cmp "$fixtures/accepted.stdout" "$work/accepted.stdout" ||
    assert_fail 'the accepted escapes decoded to different bytes than the golden'

# The emitted C carries only escapes this compiler wrote. `\x`, `\u`, `\0`, and
# octal are what a pass-through emitter would have leaked from a source that
# contained them; none of them can reach the artifact now, and the assertion is
# on the artifact rather than on the source it came from.
assert_not_grep 'the emitted C carries no hex or universal escape' \
    -Eq -- '\\[xu]' "$work/accepted.c"
assert_grep 'the emitted C carries the canonical tab escape' \
    -Fq -- '\t' "$work/accepted.c"

# Each refusal names the escape, at the escape's own byte, and leaves nothing
# behind. They are separate fixtures because they are separate wordings: the
# NUL is refused on the carrier's ground, the others on the set's.
refuses() {
    stem=$1
    expected=$2
    rm -f "$work/$stem.c" "$work/$stem.ir" "$work/$stem.tokens"
    set +e
    "$work/kofun-stage2" "$fixtures/$stem.kofun" \
        "$work/$stem.c" "$work/$stem.ir" "$work/$stem.tokens" \
        >"$work/$stem.stdout" 2>"$work/$stem.stderr"
    status=$?
    set -e
    test "$status" -ne 0 ||
        assert_fail "$stem was accepted"
    assert_absent "$stem.c" "$work/$stem.c"
    printf '%s\n' "$expected" >"$work/$stem.expected"
    grep -Fq "$expected" "$work/$stem.stdout" "$work/$stem.stderr" ||
        assert_fail "$stem diagnostic was: $(cat "$work/$stem.stdout" "$work/$stem.stderr")"
}

refuses reject_hex \
    'error[E2S12]: `\x` is not a Kofun Text escape; the set is \n \t \r \b \f \\ \"'
refuses reject_unknown \
    'error[E2S12]: `\q` is not a Kofun Text escape; the set is \n \t \r \b \f \\ \"'
refuses reject_unicode \
    'error[E2S12]: `\u` is not a Kofun Text escape; the set is \n \t \r \b \f \\ \"'
refuses reject_nul \
    'error[E2S12]: `\0` is not a Kofun Text escape; Text cannot carry an embedded NUL'

# The offset is the escape, not the literal and not the statement. A reader
# sent to the opening quote has to count the escapes themselves to find which
# one is wrong.
offset=$(sed -n 's/.*at byte \([0-9][0-9]*\).*/\1/p' \
    "$work/reject_hex.stdout" "$work/reject_hex.stderr" | sed -n 1p)
test -n "$offset" ||
    assert_fail 'the refusal carried no byte offset'
dd if="$fixtures/reject_hex.kofun" bs=1 skip="$offset" count=2 2>/dev/null \
    >"$work/reject_hex.at-offset"
assert_grep 'the offset lands on the backslash of the escape' \
    -Fx -- '\x' "$work/reject_hex.at-offset"

# The documented set is one fact, not three. A change to the compiler that
# leaves either document behind is what this catches.
for document in "$root/docs/SEMANTICS.md" "$root/spec/grammar.ebnf"; do
    assert_grep "$(basename "$document") states the escape set" \
        -Fq -- '\b' "$document"
    assert_grep "$(basename "$document") refuses the embedded NUL" \
        -Fq -- 'NUL' "$document"
done

printf '%s\n' \
    'PASS: the closed Text escape set decodes to its own bytes, re-encodes canonically, and every escape outside it is refused at its own offset with no artifact'
