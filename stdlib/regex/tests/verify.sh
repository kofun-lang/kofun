#!/bin/sh
set -eu

regex_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$regex_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-regex-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'regex checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$regex_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$regex_dir/regex.kofun"
for declaration in \
    'type RegexError =' \
    'type RegexAtom =' \
    'type RegexPiece = {' \
    'type Regex = {' \
    'type RegexMatch = {' \
    'fn regex_compile(' \
    'fn regex_find_from(' \
    'fn regex_find(' \
    'fn regex_is_match('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for error in NothingToRepeat RepeatedQuantifier MisplacedStartAnchor \
    MisplacedEndAnchor DanglingEscape UnsupportedOperator
do
    grep -Fq "| $error" "$source_file" ||
        fail "missing typed Regex error: $error"
done

grep -Fq 'if consumed != null' "$source_file" ||
    fail 'greedy repetition branch is missing'
grep -Fq 'if regex.anchored_start && start != 0' "$source_file" ||
    fail 'start-anchor contract is missing'
grep -Fq 'if regex.anchored_end && input_index != len(input)' "$source_file" ||
    fail 'end-anchor contract is missing'

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical record/ADT source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S32]: record `RegexPiece` has a field type outside the Stage 2 Int/Bool/Text slice' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

checkpoint="$regex_dir/tests/checkpoint.kofun"
expected="$regex_dir/tests/checkpoint.stdout"

"$repo_dir/bin/kofun" build "$checkpoint" \
    -o "$work/checkpoint-c11" \
    --emit-c "$work/checkpoint.c" >/dev/null
"$work/checkpoint-c11" >"$work/checkpoint-c11.stdout"
cmp "$expected" "$work/checkpoint-c11.stdout" ||
    fail 'Regex C11 vectors differ'

native_core="$regex_dir/tests/native_core.kofun"
native_expected="$regex_dir/tests/native_core.stdout"
"$repo_dir/bin/kofun" build "$native_core" \
    -o "$work/native-core-c11" \
    --emit-c "$work/native-core.c" >/dev/null
"$work/native-core-c11" >"$work/native-core-c11.stdout"
cmp "$native_expected" "$work/native-core-c11.stdout" ||
    fail 'compact Regex C11 vectors differ'

"$repo_dir/bin/kofun" build "$native_core" \
    --target x86_64-linux \
    -o "$work/native-core-x86" >/dev/null
"$work/native-core-x86" >"$work/native-core-x86.stdout"
cmp "$native_expected" "$work/native-core-x86.stdout" ||
    fail 'compact Regex direct x86-64 vectors differ'
cmp "$work/native-core-c11.stdout" "$work/native-core-x86.stdout" ||
    fail 'compact Regex C11 and direct x86-64 results differ'

[ "$(sed -n '11p' "$work/checkpoint-c11.stdout")" -eq 2004 ] &&
[ "$(sed -n '12p' "$work/checkpoint-c11.stdout")" -eq 1004 ] ||
    fail 'leftmost or greedy span contract differs'
[ "$(sed -n '13,16p' "$work/checkpoint-c11.stdout" | tr '\n' ' ')" = \
    '-1 -2 -3 -4 ' ] || fail 'validation errors are not distinct'

printf 'regex literal, wildcard, repetition, and anchor vectors: PASS\n'
printf 'regex validation and compact C11/x86-64 differential: PASS\n'
