#!/bin/sh
set -eu

set_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$set_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-set-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'set checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$set_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$set_dir/set.kofun"
for declaration in \
    'type SetInt = {' \
    'fn set_int_empty(' \
    'fn set_int_length(' \
    'fn set_int_is_empty(' \
    'fn set_int_contains(' \
    'fn set_int_insert(' \
    'fn set_int_remove(' \
    'fn set_int_from_list(' \
    'fn set_int_to_list(' \
    'fn set_int_union(' \
    'fn set_int_intersection(' \
    'fn set_int_difference(' \
    'fn set_int_is_subset(' \
    'fn set_int_equal(' \
    'fn set_int_map(' \
    'fn set_int_filter(' \
    'fn set_int_fold('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for behavior in \
    'if set.values[index] > value { return false }' \
    'if !inserted && value < current' \
    'if current == value {' \
    'result = set_int_insert(result, values[index])' \
    'return map(set.values, fn(value: Int) => value)' \
    'output = push(output, left.values[index])' \
    'if !set_int_contains(right, left.values[index])' \
    'return set_int_is_subset(left, right) && set_int_is_subset(right, left)' \
    'return SetInt { values: filter(set.values, predicate) }' \
    'return fold(set.values, initial, combine)'
do
    grep -Fq "$behavior" "$source_file" ||
        fail "missing canonical behavior: $behavior"
done

if grep -Eq 'trusted|(^|[^a-z_])(print|clock|random|exit)\(' "$source_file"
then
    fail 'canonical Set API contains a trusted or nondeterministic effect'
fi

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical record source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S157]: List[Int] function parameters support only the immutable copy mode' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

projection="$set_dir/tests/projection.kofun"
expected="$set_dir/tests/projection.stdout"
for operation in \
    'set_projection_insert(' \
    'set_projection_remove(' \
    'set_projection_union_at(' \
    'set_projection_intersection_at(' \
    'set_projection_difference_at(' \
    'set_projection_subset_at(' \
    'set_projection_length_at(' \
    'set_projection_fold_digits('
do
    grep -Fq "$operation" "$projection" ||
        fail "executable projection is missing: $operation"
done

"$repo_dir/bin/kofun" build "$projection" \
    -o "$work/projection-c11" \
    --emit-c "$work/projection.c" >/dev/null
"$work/projection-c11" >"$work/projection-c11.stdout"
cmp "$expected" "$work/projection-c11.stdout" ||
    fail 'C11 Set projection differs'

"$repo_dir/bin/kofun" build "$projection" \
    --target x86_64-linux -o "$work/projection-native" >/dev/null
projection_rx_size=$(
    LC_ALL=C readelf -lW "$work/projection-native" |
        awk '$1 == "LOAD" && $7 == "R" && $8 == "E" { print $5 }'
)
[ -n "$projection_rx_size" ] ||
    fail 'direct x86-64 Set projection has no executable LOAD segment'
[ "$((projection_rx_size))" -le 4096 ] ||
    fail 'direct x86-64 Set projection exceeds the bounded RX page'
"$work/projection-native" >"$work/projection-native.stdout"
cmp "$expected" "$work/projection-native.stdout" ||
    fail 'direct x86-64 Set projection differs'
cmp "$work/projection-c11.stdout" "$work/projection-native.stdout" ||
    fail 'C11 and direct x86-64 Set outcomes differ'

printf 'set finite membership and algebra projection: PASS\n'
printf 'set deterministic traversal C11/x86-64 differential: PASS\n'
