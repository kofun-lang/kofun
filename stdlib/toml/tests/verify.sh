#!/bin/sh
set -eu

toml_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$toml_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-toml-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'toml checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$toml_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$toml_dir/toml.kofun"
for declaration in \
    'let TOML_FLAT_PROFILE_VERSION = 1' \
    'type TomlValue =' \
    'type TomlEntry = {' \
    'type TomlDocument = {' \
    'type TomlError =' \
    'fn toml_parse(' \
    'fn toml_render('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for error in \
    ExpectedKey ExpectedEquals ExpectedValue InvalidBareKey \
    UnsupportedKeySyntax InvalidEscape UnsupportedEscape ForbiddenControl \
    UnterminatedQuotedText InvalidInteger IntegerOutOfRange UnsupportedValue \
    TrailingValueData BareCarriageReturn DuplicateKey DuplicateRenderedKey \
    UnrenderableControl
do
    grep -Fq "| $error" "$source_file" ||
        fail "missing typed TOML error: $error"
done

grep -Fq 'symbols[offset + 1] != "\n"' "$source_file" ||
    fail 'bare CR rejection is missing'
grep -Fq 'toml_document_has_key(entries, entry.key)' "$source_file" ||
    fail 'duplicate-key rejection is missing'
grep -Fq 'chars("9223372036854775808")' "$source_file" ||
    fail 'signed Int minimum boundary is missing'
grep -Fq 'symbols[start] == "[" || symbols[start] == "{"' "$source_file" ||
    fail 'unsupported compound values are not explicit'
grep -Fq 'output = output + "\\n"' "$source_file" ||
    fail 'canonical string newline escaping is missing'

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical record/ADT source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S32]: record `TomlEntry` has a field type outside the Stage 2 Int/Bool/Text slice' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

"$repo_dir/bin/kofun" run "$toml_dir/tests/checkpoint.kofun" \
    >"$work/checkpoint.stdout"
cmp "$toml_dir/tests/checkpoint.stdout" "$work/checkpoint.stdout" ||
    fail 'Kofun TOML deterministic vectors differ'

[ "$(sed -n '3p' "$work/checkpoint.stdout")" -eq 20011 ] &&
[ "$(sed -n '4p' "$work/checkpoint.stdout")" -eq 21100 ] ||
    fail 'flat document scalar-kind vectors differ'
[ "$(sed -n '5p' "$work/checkpoint.stdout")" -eq 1000000 ] &&
[ "$(sed -n '6p' "$work/checkpoint.stdout")" -eq 2000000 ] &&
[ "$(sed -n '7p' "$work/checkpoint.stdout")" -eq 3000000 ] &&
[ "$(sed -n '8p' "$work/checkpoint.stdout")" -eq 4000000 ] &&
[ "$(sed -n '9p' "$work/checkpoint.stdout")" -eq 5000000 ] ||
    fail 'structural TOML errors are not distinct'
[ "$(sed -n '12p' "$work/checkpoint.stdout")" -eq 6000000 ] &&
[ "$(sed -n '13p' "$work/checkpoint.stdout")" -eq 7000000 ] &&
[ "$(sed -n '14p' "$work/checkpoint.stdout")" -eq 8000000 ] &&
[ "$(sed -n '15p' "$work/checkpoint.stdout")" -eq 9000000 ] ||
    fail 'basic-string boundary errors are not distinct'
[ "$(sed -n '23p' "$work/checkpoint.stdout")" -eq 1 ] &&
[ "$(sed -n '24p' "$work/checkpoint.stdout")" -eq 0 ] &&
[ "$(sed -n '25p' "$work/checkpoint.stdout")" -eq 1 ] &&
[ "$(sed -n '26p' "$work/checkpoint.stdout")" -eq 0 ] &&
[ "$(sed -n '27p' "$work/checkpoint.stdout")" -eq 1 ] ||
    fail 'signed Int range decisions differ'
[ "$(sed -n '28p' "$work/checkpoint.stdout")" -eq 1 ] &&
[ "$(sed -n '29p' "$work/checkpoint.stdout")" -eq 2 ] &&
[ "$(sed -n '30p' "$work/checkpoint.stdout")" -eq 11000000 ] ||
    fail 'LF/CRLF/bare-CR decisions differ'

printf 'toml flat document and scalar vectors: PASS\n'
printf 'toml deterministic errors and Int boundaries: PASS\n'
