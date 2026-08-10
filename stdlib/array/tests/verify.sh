#!/bin/sh
set -eu

array_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$array_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-array-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'array checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$array_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$array_dir/array.kofun"
for declaration in \
    'type IntArray1 = {' \
    'type ArrayError =' \
    '| ArrayNegativeLength(Int)' \
    '| ArrayIndexOutOfBounds(Int, Int)' \
    '| ArrayShapeMismatch(Int, Int)' \
    'fn array1_int_empty(' \
    'fn array1_int_from_list(' \
    'fn array1_int_filled(' \
    'fn array1_int_to_list(' \
    'fn array1_int_length(' \
    'fn array1_int_is_empty(' \
    'fn array1_int_get(' \
    'fn array1_int_set(' \
    'fn array1_int_map(' \
    'fn array1_int_zip_map(' \
    'fn array1_int_fold(' \
    'fn array1_int_contains('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for behavior in \
    'values: map(values, fn(value: Int) => value)' \
    'Err(ArrayNegativeLength(length))' \
    'if index < -length || index >= length' \
    'Err(ArrayIndexOutOfBounds(index, length))' \
    'normalized = length + normalized' \
    'if position == normalized {' \
    'Err(ArrayShapeMismatch(left_length, right_length))' \
    'combine(left.values[index], right.values[index])' \
    'return fold(array.values, initial, combine)'
do
    grep -Fq "$behavior" "$source_file" ||
        fail "missing canonical behavior: $behavior"
done

if grep -Eq 'trusted|(^|[^a-z_])(print|clock|random|exit)\(' "$source_file"
then
    fail 'canonical Array API contains a trusted or nondeterministic effect'
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

checkpoint="$array_dir/tests/checkpoint.kofun"
checkpoint_expected="$array_dir/tests/checkpoint.stdout"
for operation in \
    'values[0]' \
    'values[-1]' \
    'map(values,' \
    'fold(values,' \
    'len([])'
do
    grep -Fq "$operation" "$checkpoint" ||
        fail "List-backed checkpoint is missing: $operation"
done
"$repo_dir/bin/kofun" build "$checkpoint" \
    --target x86_64-linux -o "$work/checkpoint-native" >/dev/null
"$work/checkpoint-native" >"$work/checkpoint-native.stdout"
cmp "$checkpoint_expected" "$work/checkpoint-native.stdout" ||
    fail 'direct x86-64 Array observations differ'

projection="$array_dir/tests/projection.kofun"
projection_expected="$array_dir/tests/projection.stdout"
for operation in \
    'array_projection_normalize(' \
    'array_projection_index_error(' \
    'array_projection_get(' \
    'array_projection_set_at(' \
    'array_projection_fold3(' \
    'array_projection_contains3(' \
    'array_projection_zip_fold(' \
    'array_projection_shape_error(' \
    'array_projection_length_error('
do
    grep -Fq "$operation" "$projection" ||
        fail "executable projection is missing: $operation"
done

"$repo_dir/bin/kofun" build "$projection" \
    -o "$work/projection-c11" \
    --emit-c "$work/projection.c" >/dev/null
"$work/projection-c11" >"$work/projection-c11.stdout"
cmp "$projection_expected" "$work/projection-c11.stdout" ||
    fail 'C11 Array projection differs'

"$repo_dir/bin/kofun" build "$projection" \
    --target x86_64-linux -o "$work/projection-native" >/dev/null
"$work/projection-native" >"$work/projection-native.stdout"
cmp "$projection_expected" "$work/projection-native.stdout" ||
    fail 'direct x86-64 Array projection differs'
cmp "$work/projection-c11.stdout" "$work/projection-native.stdout" ||
    fail 'C11 and direct x86-64 Array outcomes differ'

[ "$(sed -n '4,5p' "$work/projection-c11.stdout" | tr '\n' ' ')" = \
    '1 1 ' ] ||
    fail 'out-of-bounds outcomes are not explicit'
[ "$(sed -n '13,16p' "$work/projection-c11.stdout" | tr '\n' ' ')" = \
    '1 0 1 0 ' ] ||
    fail 'shape and length errors are not distinct from valid cases'

printf 'array IntArray1 values and fixed-shape pipelines: PASS\n'
printf 'array typed boundary projection C11/x86-64 differential: PASS\n'
