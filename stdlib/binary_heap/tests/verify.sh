#!/bin/sh
set -eu

heap_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$heap_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-binary-heap-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'binary heap checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$heap_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$heap_dir/binary_heap.kofun"
for declaration in \
    'type BinaryHeapInt = {' \
    'type BinaryHeapError =' \
    '| BinaryHeapEmpty' \
    'type BinaryHeapPopInt = {' \
    'fn binary_heap_int_empty(' \
    'fn binary_heap_int_length(' \
    'fn binary_heap_int_is_empty(' \
    'fn binary_heap_int_peek_min(' \
    'fn binary_heap_int_push(' \
    'fn binary_heap_int_from_list(' \
    'fn binary_heap_int_pop_min(' \
    'fn binary_heap_int_to_sorted_list('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

for behavior in \
    'let parent = (index - 1) // 2' \
    'if values[parent] <= values[index] { return }' \
    'let left = index * 2 + 1' \
    'values[right] < values[left]' \
    'return Err(BinaryHeapEmpty)' \
    'values = push(values, value)' \
    'binary_heap_int_sift_up(values, len(values) - 1)' \
    'binary_heap_int_sift_down(values, 0)' \
    'output = push(output, popped.value)'
do
    grep -Fq "$behavior" "$source_file" ||
        fail "missing canonical behavior: $behavior"
done

if grep -Eq 'trusted|(^|[^a-z_])(print|clock|random|exit)\(' "$source_file"
then
    fail 'canonical BinaryHeap API contains a trusted or nondeterministic effect'
fi

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical record source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S32]: record `BinaryHeapInt` has a field type outside the Stage 2 Int/Bool/Text slice' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

projection="$heap_dir/tests/projection.kofun"
expected="$heap_dir/tests/projection.stdout"
for operation in \
    'binary_heap_projection_push(' \
    'binary_heap_projection_peek_min(' \
    'binary_heap_projection_pop_min(' \
    'binary_heap_projection_sift_up(' \
    'binary_heap_projection_sift_down(' \
    'binary_heap_projection_drain('
do
    grep -Fq "$operation" "$projection" ||
        fail "executable projection is missing: $operation"
done

"$repo_dir/bin/kofun" build "$projection" \
    -o "$work/projection-c11" \
    --emit-c "$work/projection.c" >/dev/null
"$work/projection-c11" >"$work/projection-c11.stdout"
cmp "$expected" "$work/projection-c11.stdout" ||
    fail 'C11 BinaryHeap projection differs'

"$repo_dir/bin/kofun" build "$projection" \
    --target x86_64-linux -o "$work/projection-native" >/dev/null
"$work/projection-native" >"$work/projection-native.stdout"
cmp "$expected" "$work/projection-native.stdout" ||
    fail 'direct x86-64 BinaryHeap projection differs'
cmp "$work/projection-c11.stdout" "$work/projection-native.stdout" ||
    fail 'C11 and direct x86-64 BinaryHeap outcomes differ'

[ "$(sed -n '3,4p' "$work/projection-c11.stdout" | uniq | wc -l | tr -d ' ')" -eq 1 ] ||
    fail 'equivalent insertion histories do not drain identically'
[ "$(sed -n '5,8p' "$work/projection-c11.stdout" | tr '\n' ' ')" = \
    '1 1 0 0 ' ] ||
    fail 'empty and present outcomes are not distinct'

printf 'binary heap min-order and duplicate projection: PASS\n'
printf 'binary heap C11/x86-64 differential: PASS\n'
