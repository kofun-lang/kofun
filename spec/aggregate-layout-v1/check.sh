#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/spec/aggregate-layout-v1"
LAYOUT="$HERE/layout.mjs"
SPEC="$ROOT/spec/aggregate-layout-v1.md"
TMP_PARENT="$ROOT/build/tmp"
mkdir -p "$TMP_PARENT"
TMP_DIR=$(mktemp -d "$TMP_PARENT/aggregate-layout.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
ASSERT_CONTEXT='aggregate layout v1'
. "$ROOT/tests/assertions/assert.sh"

node --check "$LAYOUT"
node "$LAYOUT" schema > /dev/null
node "$LAYOUT" self-test-limits > /dev/null

# The golden descriptors are recomputed rather than merely read, so a change
# to any layout rule fails here instead of being absorbed by a stale file.
for target in x86_64-linux wasm32; do
    node "$LAYOUT" describe \
        "$HERE/targets/$target.json" "$HERE/vectors/core.json" \
        > "$TMP_DIR/$target.json"
    cmp "$HERE/examples/core.$target.json" "$TMP_DIR/$target.json" ||
        {
            printf '%s\n' "FAIL: aggregate-layout: $target descriptors differ from the checked-in vectors" >&2
            exit 1
        }
    node "$LAYOUT" describe \
        "$HERE/targets/$target.json" "$HERE/vectors/core.json" \
        > "$TMP_DIR/$target.second.json"
    cmp "$TMP_DIR/$target.json" "$TMP_DIR/$target.second.json" ||
        {
            printf '%s\n' "FAIL: aggregate-layout: $target descriptors are not deterministic" >&2
            exit 1
        }
done

# The two targets must actually disagree. A contract that computed identical
# bytes for a 4-byte and an 8-byte reference would pass every positive check
# above while having silently decided pointer width, which is exactly the
# failure option A was rejected for.
if cmp -s "$HERE/examples/core.x86_64-linux.json" "$HERE/examples/core.wasm32.json"; then
    printf '%s\n' "FAIL: aggregate-layout: the two targets produced identical descriptors" >&2
    exit 1
fi

expect_rejected() {
    label=$1
    target=$2
    document=$3
    if node "$LAYOUT" describe "$target" "$document" \
        > "$TMP_DIR/$label.out" 2> "$TMP_DIR/$label.err"; then
        printf '%s\n' "FAIL: aggregate-layout: $label was accepted but must be rejected" >&2
        exit 1
    else
        status=$?
    fi
    test "$status" -eq 1 ||
        {
            printf '%s\n' "FAIL: aggregate-layout: $label exited $status, expected 1" >&2
            exit 1
        }
    # A rejection writes no descriptor: a partial layout is worse than none,
    # because a consumer cannot tell it apart from a complete one.
    test ! -s "$TMP_DIR/$label.out" ||
        {
            printf '%s\n' "FAIL: aggregate-layout: $label wrote a descriptor while failing" >&2
            exit 1
        }
    assert_num "lines in $TMP_DIR/$label.err" \
        "$(wc -l < "$TMP_DIR/$label.err")" -eq 1
    grep -q '^aggregate-layout: ' "$TMP_DIR/$label.err"
}

expect_rejected overflow-elements \
    "$HERE/targets/x86_64-linux.json" "$HERE/invalid/overflow-elements.json"
expect_rejected recursive \
    "$HERE/targets/x86_64-linux.json" "$HERE/invalid/recursive.json"
expect_rejected size-overflow \
    "$HERE/invalid/tiny-target.json" "$HERE/vectors/core.json"
expect_rejected big-endian \
    "$HERE/invalid/big-endian-target.json" "$HERE/vectors/core.json"

# The normative rules the golden vectors cannot express on their own.
assert_grep "SPEC" -q 'option B' "$SPEC"
assert_grep "SPEC" -q 'niche optimization' "$SPEC"
assert_grep "SPEC" -q 'declaration order' "$SPEC"
assert_grep "SPEC" -q 'decimal string' "$SPEC"
assert_grep "SPEC" -q 'not a compatibility requirement' "$SPEC"

# The carrier and the contract must agree about the bounded List[Int] value.
#
# They did not, and that disagreement is what #1183 was filed against: the
# Stage 2 backend stores a `List[Int]` by value in 520 bytes while the
# contract described every list value as one reference. RFC-0011 resolved it
# by adding the `bounded_list` kind, and this is the join that keeps the two
# from drifting apart again. Reading `_Static_assert` numbers out of the
# emitter is deliberate: they are the numbers the emitted C actually enforces,
# so a change to either side fails here rather than at the next increment.
STAGE2="$ROOT/bootstrap/stage2/compiler.kofun"
descriptor_field() {
    node -e '
        const fs = require("node:fs")
        const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
        const found = doc.layouts.find((entry) => entry.id === process.argv[2])
        if (found === undefined) {
            process.stderr.write(`no layout ${process.argv[2]}\n`)
            process.exit(1)
        }
        process.stdout.write(String(found[process.argv[3]]))
    ' "$HERE/examples/core.x86_64-linux.json" "BoundedList[Int, 64]" "$1"
}
carrier_assert() {
    sed -n "s/.*_Static_assert($1 == \([0-9]*\).*/\1/p" "$STAGE2" | head -n 1
}

assert_num "bounded List[Int] carrier size" \
    "$(descriptor_field size)" -eq "$(carrier_assert 'sizeof(KofunIntListValue)')"
assert_num "bounded List[Int] carrier alignment" \
    "$(descriptor_field align)" -eq "$(carrier_assert '_Alignof(KofunIntListValue)')"
assert_num "bounded List[Int] length offset" \
    "$(descriptor_field length_offset)" \
    -eq "$(carrier_assert 'offsetof(KofunIntListValue, length)')"
assert_num "bounded List[Int] elements offset" \
    "$(descriptor_field elements_offset)" \
    -eq "$(carrier_assert 'offsetof(KofunIntListValue, elements)')"

# A bounded list of a reference element keeps a pointer per slot, so the kind
# is not silently "the trivial one". Without this, an implementation could
# drop the per-slot bitmap and every vector above would still pass.
assert_grep "x86-64 descriptors" -q '"BoundedList\[Text, 3\]"' \
    "$HERE/examples/core.x86_64-linux.json"

printf '%s\n' \
    'PASS: AggregateLayout v1 descriptors are deterministic and target-parameterized' \
    'PASS: overflow, recursive layout, and unsupported targets are refused without a descriptor' \
    'PASS: the bounded List[Int] descriptor agrees with the Stage 2 carrier assertions'
