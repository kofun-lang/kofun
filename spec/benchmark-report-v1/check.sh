#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/spec/benchmark-report-v1"
WORK=${KOFUN_BENCHMARK_REPORT_SPEC_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}benchmark-report-spec"}
ASSERT_CONTEXT='benchmark-report v1 executable profile'
. "$ROOT/tests/assertions/assert.sh"

case $WORK in
    */benchmark-report-spec|*/benchmark-report-spec.*) ;;
    *) assert_fail "work directory must end in benchmark-report-spec[.suffix]: $WORK" ;;
esac

command -v node >/dev/null 2>&1 || assert_fail 'node is required'
command -v cmp >/dev/null 2>&1 || assert_fail 'cmp is required'
rm -rf "$WORK"
mkdir -p "$WORK"

node --check "$HERE/contract.mjs"
node --check "$HERE/model.mjs"
node --check "$HERE/check.mjs"
node "$HERE/check.mjs"

vectors=0
for vector in "$HERE"/vectors/positive/*.json
do
    name=$(basename "$vector")
    node "$HERE/model.mjs" validate "$vector" >"$WORK/$name"
    cmp "$vector" "$WORK/$name" ||
        assert_fail "$name did not round-trip byte-for-byte"
    vectors=$((vectors + 1))
done
assert_num 'canonical positive vector count' "$vectors" -eq 3

assert_grep 'benchmark charter names the versioned report' \
    -Fq 'kofun.bench-report/v1' "$ROOT/docs/stdlib/benchmark.md"
assert_grep 'spec index names the executable profile' \
    -Fq 'benchmark-report-v1.md' "$ROOT/spec/README.md"

printf '%s\n' \
    'PASS: benchmark-report-spec owns three canonical positive vectors and a digest-pinned negative corpus' \
    'PASS: benchmark-report-spec remains a pure contract with no production runner, codec, or filesystem claim'
