#!/bin/sh
set -eu

logging_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$logging_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-logging-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'logging checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$logging_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$logging_dir/logging.kofun"
for declaration in \
    'let LOG_TEXT_FORMAT_VERSION = 1' \
    'type LogLevel =' \
    'type LogValue =' \
    'type LogField = {' \
    'type LogRecord = {' \
    'type LogError =' \
    'fn log_level_rank(' \
    'fn log_level_name(' \
    'fn log_enabled(' \
    'fn log_text_field(' \
    'fn log_int_field(' \
    'fn log_bool_field(' \
    'fn log_validate_fields(' \
    'fn log_record(' \
    'fn log_escape_text(' \
    'fn log_render(' \
    'fn log_render_at('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for behavior in \
    'return Err(InvalidFieldKey(index, fields[index].key))' \
    'return Err(DuplicateFieldKey(' \
    'result = result + "\\\\"' \
    'result = result + "\\\""' \
    'result = result + "\\n"' \
    'result = result + "\\r"' \
    'result = result + "\\t"' \
    'return null'
do
    grep -Fq "$behavior" "$source_file" ||
        fail "missing canonical behavior: $behavior"
done

# Construction and rendering are deterministic value operations. Sinks,
# clocks, randomness, environment reads, and process-global configuration are
# intentionally outside this checkpoint.
if grep -Eq '(^|[^a-z_])(print|clock|random|environment|global)\(' \
    "$source_file"
then
    fail 'canonical logging API contains an ambient effect'
fi

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical record/ADT source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S32]: record `LogField` has a field type outside the Stage 2 Int/Bool/Text slice' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

for fixture in levels fields escaping
do
    checkpoint="$logging_dir/tests/$fixture.kofun"
    expected="$logging_dir/tests/$fixture.stdout"

    "$repo_dir/bin/kofun" build "$checkpoint" \
        -o "$work/$fixture-c11" \
        --emit-c "$work/$fixture.c" >/dev/null
    "$work/$fixture-c11" >"$work/$fixture-c11.stdout"
    cmp "$expected" "$work/$fixture-c11.stdout" ||
        fail "$fixture C11 output differs"

    "$repo_dir/bin/kofun" build "$checkpoint" \
        --target x86_64-linux \
        -o "$work/$fixture-native" >/dev/null
    "$work/$fixture-native" >"$work/$fixture-native.stdout"
    cmp "$expected" "$work/$fixture-native.stdout" ||
        fail "$fixture direct x86-64 output differs"
    cmp "$work/$fixture-c11.stdout" "$work/$fixture-native.stdout" ||
        fail "$fixture C11 and direct x86-64 results differ"
done

[ "$(sed -n '11,15p' "$work/levels-c11.stdout" | tr '\n' ' ')" = \
    '5 4 3 2 1 ' ] || fail 'level threshold matrix differs'
[ "$(sed -n '6p' "$work/fields-c11.stdout")" -eq 0 ] &&
[ "$(sed -n '7p' "$work/fields-c11.stdout")" -eq 212 ] &&
[ "$(sed -n '10p' "$work/fields-c11.stdout")" -eq 101 ] ||
    fail 'field validation order differs'
[ "$(sed -n '7p' "$work/escaping-c11.stdout")" -eq 51670 ] &&
[ "$(sed -n '8p' "$work/escaping-c11.stdout")" -eq 7 ] ||
    fail 'escape mapping differs'
[ "$(sed -n '16,18p' "$work/levels-c11.stdout" | tr '\n' ' ')" = \
    '37 0 37 ' ] || fail 'filtered render outcomes differ'

printf 'logging level and threshold contract: PASS\n'
printf 'logging field validation and escaping: PASS\n'
printf 'logging deterministic C11/x86-64 differential: PASS\n'
