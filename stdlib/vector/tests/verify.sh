#!/bin/sh
set -eu

vector_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$vector_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-vector-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'vector checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$vector_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$vector_dir/vector.kofun"
for declaration in \
    'type IntVector = {' \
    'type VectorError =' \
    '| VectorIndexOutOfBounds(Int, Int)' \
    'fn vector_int_empty(' \
    'fn vector_int_from_list(' \
    'fn vector_int_to_list(' \
    'fn vector_int_length(' \
    'fn vector_int_is_empty(' \
    'fn vector_int_get(' \
    'fn vector_int_push(' \
    'fn vector_int_concat(' \
    'fn vector_int_reverse(' \
    'fn vector_int_map(' \
    'fn vector_int_filter(' \
    'fn vector_int_fold(' \
    'fn vector_int_contains('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for behavior in \
    'values: map(values, fn(value: Int) => value)' \
    'if index < -length || index >= length' \
    'Err(VectorIndexOutOfBounds(index, length))' \
    'return Ok(vector.values[index])' \
    'values: push(vector.values, value)' \
    'values: concat(left.values, right.values)' \
    'values: map(vector.values, transform)' \
    'values: filter(vector.values, predicate)' \
    'return fold(vector.values, initial, combine)'
do
    grep -Fq "$behavior" "$source_file" ||
        fail "missing canonical behavior: $behavior"
done

if grep -Eq 'trusted|(^|[^a-z_])(print|clock|random|exit)\(' "$source_file"
then
    fail 'canonical Vector API contains a trusted or nondeterministic effect'
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

checkpoint="$vector_dir/tests/checkpoint.kofun"
expected="$vector_dir/tests/checkpoint.stdout"
for operation in \
    'values[0]' \
    'values[-1]' \
    'map(values,' \
    'filter(values,' \
    'fold(values,' \
    'fold([],' \
    'filter(values, fn(value: Int) => value > 1)'
do
    grep -Fq "$operation" "$checkpoint" ||
        fail "executable projection is missing: $operation"
done
"$repo_dir/bin/kofun" build "$checkpoint" \
    --target x86_64-linux -o "$work/checkpoint-native" >/dev/null
"$work/checkpoint-native" >"$work/checkpoint-native.stdout"
cmp "$expected" "$work/checkpoint-native.stdout" ||
    fail 'direct x86-64 Vector vectors differ'

projection="$vector_dir/tests/projection.kofun"
projection_expected="$vector_dir/tests/projection.stdout"
"$repo_dir/bin/kofun" build "$projection" \
    -o "$work/projection-c11" \
    --emit-c "$work/projection.c" >/dev/null
"$work/projection-c11" >"$work/projection-c11.stdout"
cmp "$projection_expected" "$work/projection-c11.stdout" ||
    fail 'C11 checked-index projection differs'

"$repo_dir/bin/kofun" build "$projection" \
    --target x86_64-linux -o "$work/projection-native" >/dev/null
"$work/projection-native" >"$work/projection-native.stdout"
cmp "$projection_expected" "$work/projection-native.stdout" ||
    fail 'direct x86-64 checked-index projection differs'
cmp "$work/projection-c11.stdout" "$work/projection-native.stdout" ||
    fail 'C11 and direct x86-64 checked-index outcomes differ'

[ "$(sed -n '6,8p' "$work/projection-c11.stdout" | tr '\n' ' ')" = \
    '1 1 1 ' ] ||
    fail 'out-of-bounds outcomes are not distinct from valid access'

printf 'vector IntVector values and ordered pipelines: PASS\n'
printf 'vector typed access projection C11/x86-64 differential: PASS\n'
