#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
fixtures="$root/tests/stage2/list-int-values"
work=${TMPDIR:-/tmp}/kofun-stage2-list-int-values.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"
ASSERT_CONTEXT='stage2 List[Int] values'
. "$root/tests/assertions/assert.sh"

if command -v cc >/dev/null 2>&1; then
    compiler=cc
elif command -v clang >/dev/null 2>&1; then
    compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    compiler=gcc
else
    echo "list-int-values: a C11 compiler is required" >&2
    exit 1
fi

. "$root/bootstrap/stage2/build.sh"
kofun_stage2_build "$root" "$work/kofun-stage2"
node --check "$fixtures/layout-check.mjs"
node "$root/spec/aggregate-layout-v1/layout.mjs" describe \
    "$root/spec/aggregate-layout-v1/targets/x86_64-linux.json" \
    "$root/spec/aggregate-layout-v1/vectors/core.json" \
    >"$work/aggregate-layout.json"

compile_success() {
    stem=$1
    source=$2
    "$work/kofun-stage2" \
        "$source" \
        "$work/$stem.c" \
        "$work/$stem.ir" \
        "$work/$stem.tokens" \
        >"$work/$stem.compile.stdout" \
        2>"$work/$stem.compile.stderr"
    assert_file_nonempty "$stem generated C" "$work/$stem.c"
    assert_file_empty "$stem compiler stderr" "$work/$stem.compile.stderr"
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I"$root/bootstrap/stage2" \
        "$work/$stem.c" \
        -o "$work/$stem"
}

compile_success complete "$fixtures/complete.kofun"
assert_file_nonempty "complete typed HIR" "$work/complete.ir"
assert_grep \
    "explicit List[Int] binding reaches typed HIR" \
    -Fq "|explicit|immutable|List[Int]|gc|initialized|" \
    "$work/complete.ir"
assert_grep \
    "inferred List[Int] binding reaches typed HIR" \
    -Fq "|inferred|immutable|List[Int]|gc|initialized|" \
    "$work/complete.ir"
assert_grep \
    "empty List[Int] binding reaches typed HIR" \
    -Fq "|empty|immutable|List[Int]|gc|initialized|" \
    "$work/complete.ir"
node "$fixtures/layout-check.mjs" \
    "$work/aggregate-layout.json" "$work/complete.c"
node "$fixtures/layout-check.mjs" \
    "$work/aggregate-layout.json" "$work/complete.c" mutate-payload \
    >"$work/layout-drift.c"
if cmp -s "$work/complete.c" "$work/layout-drift.c"; then
    fail "descriptor-derived payload mutation did not change emitted C"
fi
set +e
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$root/bootstrap/stage2" \
    "$work/layout-drift.c" \
    -o "$work/layout-drift" \
    >"$work/layout-drift.stdout" \
    2>"$work/layout-drift.stderr"
layout_status=$?
set -e
assert_num "descriptor-derived layout drift status" "$layout_status" -ne 0
assert_absent "descriptor-derived layout drift binary" "$work/layout-drift"
assert_file_empty \
    "descriptor-derived layout drift stdout" \
    "$work/layout-drift.stdout"
assert_grep \
    "descriptor-derived layout drift diagnostic" \
    -Fq "AggregateLayout List[Int] payload offset" \
    "$work/layout-drift.stderr"
"$work/complete" >"$work/complete.stdout" 2>"$work/complete.stderr"
cmp "$fixtures/complete.stdout" "$work/complete.stdout"
assert_file_empty "complete runtime stderr" "$work/complete.stderr"
"$work/complete" \
    >"$work/complete-repeat.stdout" \
    2>"$work/complete-repeat.stderr"
cmp "$work/complete.stdout" "$work/complete-repeat.stdout"
cmp "$work/complete.stderr" "$work/complete-repeat.stderr"

# Mutable lists are still by-value carriers. The fixture copies a parameter,
# writes positive and negative indices, copies a direct-call result, and then
# proves both source values stayed unchanged.
compile_success mutable "$fixtures/mutable.kofun"
assert_grep \
    "annotated mutable List[Int] binding reaches typed HIR" \
    -Fq "|out|mutable|List[Int]|gc|initialized|" \
    "$work/mutable.ir"
assert_grep \
    "inferred mutable List[Int] binding reaches typed HIR" \
    -Fq "|direct|mutable|List[Int]|gc|initialized|" \
    "$work/mutable.ir"
"$work/mutable" >"$work/mutable.stdout" 2>"$work/mutable.stderr"
cmp "$fixtures/mutable.stdout" "$work/mutable.stdout"
assert_file_empty "mutable runtime stderr" "$work/mutable.stderr"

# Exercise the new write path under the host sanitizers when the selected C11
# compiler supports them. Unsupported sanitizer flags are not a product
# failure, but a supported instrumented build must run byte-identically.
if "$compiler" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I"$root/bootstrap/stage2" \
    "$work/mutable.c" -o "$work/mutable-sanitized" \
    >"$work/mutable-sanitize.stdout" \
    2>"$work/mutable-sanitize.stderr"
then
    "$work/mutable-sanitized" \
        >"$work/mutable-sanitized.stdout" \
        2>"$work/mutable-sanitized.stderr"
    cmp "$fixtures/mutable.stdout" "$work/mutable-sanitized.stdout"
    assert_file_empty \
        "mutable sanitizer runtime stderr" \
        "$work/mutable-sanitized.stderr"
fi

# The native Core C reference is independent of the Stage 2 lowerer. Its
# binding observation and the emitted C11 program must agree byte for byte.
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$root/bootstrap/native/fixtures/list_int_reference.c" \
    -o "$work/list-int-reference"
"$work/list-int-reference" binding >"$work/reference.native.stdout"
compile_success reference "$fixtures/reference.kofun"
"$work/reference" >"$work/reference.stage2.stdout"
cmp "$fixtures/reference.stdout" "$work/reference.native.stdout"
cmp "$work/reference.native.stdout" "$work/reference.stage2.stdout"

# Repetition and different absolute directories must not change source-derived
# C, typed HIR, or the token tape.
mkdir -p "$work/normalized-a/src" "$work/normalized-b/src"
cp "$fixtures/complete.kofun" "$work/normalized-a/src/case.kofun"
cp "$fixtures/complete.kofun" "$work/normalized-b/src/case.kofun"
for directory in normalized-a normalized-b
do
    "$work/kofun-stage2" \
        "$work/$directory/src/case.kofun" \
        "$work/$directory/case.c" \
        "$work/$directory/case.ir" \
        "$work/$directory/case.tokens" \
        >"$work/$directory/compile.stdout" \
        2>"$work/$directory/compile.stderr"
    assert_file_empty \
        "$directory compiler stderr" \
        "$work/$directory/compile.stderr"
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I"$root/bootstrap/stage2" \
        "$work/$directory/case.c" \
        -o "$work/$directory/case"
    "$work/$directory/case" \
        >"$work/$directory/runtime.stdout" \
        2>"$work/$directory/runtime.stderr"
    cmp "$fixtures/complete.stdout" "$work/$directory/runtime.stdout"
    assert_file_empty \
        "$directory runtime stderr" \
        "$work/$directory/runtime.stderr"
done
cmp "$work/normalized-a/case.c" "$work/normalized-b/case.c"
cmp "$work/normalized-a/case.ir" "$work/normalized-b/case.ir"
cmp "$work/normalized-a/case.tokens" "$work/normalized-b/case.tokens"
cmp "$work/normalized-a/runtime.stdout" "$work/normalized-b/runtime.stdout"
cmp "$work/normalized-a/runtime.stderr" "$work/normalized-b/runtime.stderr"

# A dynamic index is checked by the generated runtime before printing.
compile_success dynamic-out-of-range "$fixtures/dynamic_out_of_range.kofun"
set +e
"$work/dynamic-out-of-range" \
    >"$work/dynamic-out-of-range.stdout" \
    2>"$work/dynamic-out-of-range.stderr"
dynamic_status=$?
set -e
assert_num "dynamic out-of-range status" "$dynamic_status" -eq 1
assert_file_empty \
    "dynamic out-of-range stdout" \
    "$work/dynamic-out-of-range.stdout"
cmp \
    "$fixtures/dynamic_out_of_range.stderr" \
    "$work/dynamic-out-of-range.stderr"

# A dynamic out-of-range write is checked before its observable RHS call, the
# write, and every later observation. It uses the same R023 resolver as a read.
compile_success \
    dynamic-out-of-range-write \
    "$fixtures/dynamic_out_of_range_write.kofun"
set +e
"$work/dynamic-out-of-range-write" \
    >"$work/dynamic-out-of-range-write.stdout" \
    2>"$work/dynamic-out-of-range-write.stderr"
dynamic_write_status=$?
set -e
assert_num "dynamic out-of-range write status" "$dynamic_write_status" -eq 1
assert_file_empty \
    "dynamic out-of-range write stdout" \
    "$work/dynamic-out-of-range-write.stdout"
cmp \
    "$fixtures/dynamic_out_of_range_write.stderr" \
    "$work/dynamic-out-of-range-write.stderr"

# Every compile-time refusal is transactional: stable stdout, empty compiler
# stderr, status 1, and no partial C artifact.
for stem in \
    argument_boundary \
    immutable_write \
    non_int_index \
    non_int_write_index \
    non_int_write_value \
    out_of_range \
    out_of_range_write \
    oversized \
    unsupported_annotation \
    unsupported_element
do
    set +e
    "$work/kofun-stage2" \
        "$fixtures/$stem.kofun" \
        "$work/refuse-$stem.c" \
        "$work/refuse-$stem.ir" \
        "$work/refuse-$stem.tokens" \
        >"$work/refuse-$stem.stdout" \
        2>"$work/refuse-$stem.stderr"
    status=$?
    set -e
    assert_num "$stem refusal status" "$status" -eq 1
    assert_absent "$stem rejected C artifact" "$work/refuse-$stem.c"
    assert_file_empty "$stem compiler stderr" "$work/refuse-$stem.stderr"
    cmp "$fixtures/$stem.stdout" "$work/refuse-$stem.stdout"
done

(
    cd "$root"
    "$root/bin/kofun-digest" -c bootstrap/stage2/SHA256SUMS
)

echo "PASS: Stage 2 List[Int] locals, bounded literals, len, and checked indexing"
