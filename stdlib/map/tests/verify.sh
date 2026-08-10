#!/bin/sh
set -eu

map_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$map_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-map-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'map checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$map_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$map_dir/map.kofun"
for declaration in \
    'type IntMapEntry = {' \
    'type IntMap = {' \
    'type MapError =' \
    '| MapKeyMissing(Int)' \
    'fn map_int_entry(' \
    'fn map_int_empty(' \
    'fn map_int_length(' \
    'fn map_int_is_empty(' \
    'fn map_int_contains_key(' \
    'fn map_int_get(' \
    'fn map_int_insert(' \
    'fn map_int_remove(' \
    'fn map_int_from_entries(' \
    'fn map_int_to_entries(' \
    'fn map_int_keys(' \
    'fn map_int_values(' \
    'fn map_int_map_values(' \
    'fn map_int_filter(' \
    'fn map_int_fold('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for behavior in \
    'if map.entries[index].key > key { return false }' \
    'return Err(MapKeyMissing(key))' \
    'if !inserted && key < current.key' \
    'if current.key == key {' \
    'result = map_int_insert(' \
    'map_int_entry(map.entries[index].key, map.entries[index].value)' \
    'map_int_entry(entry.key, transform(entry.key, entry.value))' \
    'if predicate(entry.key, entry.value)' \
    'result = combine('
do
    grep -Fq "$behavior" "$source_file" ||
        fail "missing canonical behavior: $behavior"
done

if grep -Eq 'trusted|(^|[^a-z_])(print|clock|random|exit)\(' "$source_file"
then
    fail 'canonical Map API contains a trusted or nondeterministic effect'
fi

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical record source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S32]: record `IntMap` has a field type outside the Stage 2 Int/Bool/Text slice' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

projection="$map_dir/tests/projection.kofun"
expected="$map_dir/tests/projection.stdout"
for operation in \
    'map_projection_contains(' \
    'map_projection_get_outcome(' \
    'map_projection_get_value(' \
    'map_projection_insert_contains(' \
    'map_projection_insert_value(' \
    'map_projection_remove_contains(' \
    'map_projection_length_after_insert(' \
    'map_projection_length_after_remove(' \
    'map_projection_filter_fold_min4(' \
    'map_projection_increment_fold(' \
    'map_projection_fold_entries('
do
    grep -Fq "$operation" "$projection" ||
        fail "executable projection is missing: $operation"
done

"$repo_dir/bin/kofun" build "$projection" \
    -o "$work/projection-c11" \
    --emit-c "$work/projection.c" >/dev/null
"$work/projection-c11" >"$work/projection-c11.stdout"
cmp "$expected" "$work/projection-c11.stdout" ||
    fail 'C11 Map projection differs'

"$repo_dir/bin/kofun" build "$projection" \
    --target x86_64-linux -o "$work/projection-native" >/dev/null
"$work/projection-native" >"$work/projection-native.stdout"
cmp "$expected" "$work/projection-native.stdout" ||
    fail 'direct x86-64 Map projection differs'
cmp "$work/projection-c11.stdout" "$work/projection-native.stdout" ||
    fail 'C11 and direct x86-64 Map outcomes differ'

[ "$(sed -n '2,4p' "$work/projection-c11.stdout" | tr '\n' ' ')" = \
    '0 4 1 ' ] ||
    fail 'typed lookup outcome is not distinct from a stored value'

printf 'map Int-to-Int canonical surface: PASS\n'
printf 'map deterministic projection C11/x86-64 differential: PASS\n'
