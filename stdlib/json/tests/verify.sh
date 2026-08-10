#!/bin/sh
set -eu

json_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$json_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-json-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'json checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$json_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$json_dir/json.kofun"
for declaration in \
    'let JSON_PROFILE_VERSION = 1' \
    'let JSON_MAX_NESTING = 64' \
    'type JsonMember = {' \
    'type JsonValue =' \
    'type JsonError =' \
    'fn json_number(' \
    'fn json_parse(' \
    'fn json_render('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for variant in \
    JsonNull JsonBoolean JsonNumber JsonText JsonArray JsonObject
do
    grep -Fq "| $variant" "$source_file" ||
        fail "missing JSON value variant: $variant"
done

for error in \
    InvalidLiteral InvalidNumber InvalidEscape UnsupportedUnicodeEscape \
    UnescapedControl ExpectedColon ExpectedCommaOrEnd DuplicateKey \
    TrailingData NestingLimitExceeded InvalidRenderedNumber \
    DuplicateRenderedKey UnrenderableControl
do
    grep -Fq "| $error" "$source_file" ||
        fail "missing typed JSON error: $error"
done

grep -Fq 'if symbols[offset] == "0"' "$source_file" ||
    fail 'leading-zero number check is missing'
grep -Fq 'json_members_have_key(members, key)' "$source_file" ||
    fail 'parsed duplicate-name check is missing'
grep -Fq 'if depth >= JSON_MAX_NESTING' "$source_file" ||
    fail 'nesting resource limit is missing'
grep -Fq 'UnsupportedUnicodeEscape(offset)' "$source_file" ||
    fail 'Unicode escape boundary is not explicit'

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical recursive ADT source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S32]: record `JsonMember` has a field type outside the Stage 2 Int/Bool/Text/List[Int] slice' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

checkpoint="$json_dir/tests/checkpoint.kofun"
expected="$json_dir/tests/checkpoint.stdout"
"$repo_dir/bin/kofun" run "$checkpoint" >"$work/checkpoint.stdout"
cmp "$expected" "$work/checkpoint.stdout" ||
    fail 'JSON Int-Core projection vectors differ'

[ "$(sed -n '6,10p' "$work/checkpoint.stdout" | tr '\n' ' ')" = \
    '-3 -2 -5 -1 -4 ' ] ||
    fail 'structural failures are not distinct'
[ "$(sed -n '16,19p' "$work/checkpoint.stdout" | tr '\n' ' ')" = \
    '0 0 0 0 ' ] ||
    fail 'malformed number shapes were accepted'
[ "$(sed -n '23,26p' "$work/checkpoint.stdout" | tr '\n' ' ')" = \
    '-3 -2 -4 -1 ' ] ||
    fail 'string boundaries are not distinct'

printf 'json containers, whitespace, and separator vectors: PASS\n'
printf 'json number grammar and string escape boundaries: PASS\n'
printf 'json typed errors and bounded nesting contract: PASS\n'
