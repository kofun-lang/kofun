#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/aggregate-bridge"
CAPABILITIES="$ROOT/tests/conformance/capabilities.tsv"
WORK=${KOFUN_AGGREGATE_BRIDGE_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}aggregate-bridge"}
CC=${CC:-cc}
ASSERT_CONTEXT='aggregate bridge'
. "$ROOT/tests/assertions/assert.sh"
. "$ROOT/bootstrap/stage2/build.sh"

for tool in "$CC" node cmp awk
do
    command -v "$tool" >/dev/null 2>&1 ||
        assert_fail "required tool is unavailable: $tool"
done
case $WORK in
    */aggregate-bridge|*/aggregate-bridge.*) ;;
    *) assert_fail "work directory must end in aggregate-bridge[.suffix]: $WORK" ;;
esac
rm -rf "$WORK"
mkdir -p "$WORK/sidecar-build/stage1" \
    "$WORK/sidecar-build/stage2" \
    "$WORK/sidecar-build/events"

STAGE2="$WORK/kofun-stage2"
kofun_stage2_build "$ROOT" "$STAGE2"

SOURCE="$CASES/bridge.kofun"
GOLDEN="$CASES/bridge.stdout"
"$STAGE2" "$SOURCE" \
    "$WORK/bridge.c" "$WORK/bridge.ir" "$WORK/bridge.tokens" \
    >"$WORK/bridge.compile.stdout" 2>"$WORK/bridge.compile.stderr" ||
    assert_fail "mixed BridgeReport source did not lower"
assert_file_nonempty 'mixed BridgeReport C artifact' "$WORK/bridge.c"
assert_file_nonempty 'mixed BridgeReport typed HIR' "$WORK/bridge.ir"
assert_file_nonempty 'mixed BridgeReport token tape' "$WORK/bridge.tokens"
assert_file_empty 'mixed BridgeReport compiler stderr' "$WORK/bridge.compile.stderr"
assert_eq 'mixed BridgeReport compiler stdout' \
    "$(cat "$WORK/bridge.compile.stdout")" "$WORK/bridge.c"

"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/bootstrap/stage2" \
    "$WORK/bridge.c" -o "$WORK/bridge" \
    >"$WORK/bridge.cc.stdout" 2>"$WORK/bridge.cc.stderr" ||
    assert_fail "mixed BridgeReport emitted C did not build as strict C11"
assert_executable 'strict C11 BridgeReport executable' "$WORK/bridge"
assert_file_empty 'strict C11 compiler stdout' "$WORK/bridge.cc.stdout"
assert_file_empty 'strict C11 compiler stderr' "$WORK/bridge.cc.stderr"

run_bridge() {
    label=$1
    set +e
    "$WORK/bridge" >"$WORK/$label.stdout" 2>"$WORK/$label.stderr"
    status=$?
    set -e
    assert_num "$label runtime status" "$status" -eq 0
    assert_file_empty "$label runtime stderr" "$WORK/$label.stderr"
    cmp "$GOLDEN" "$WORK/$label.stdout" ||
        assert_fail "$label output differs byte-for-byte from bridge.stdout"
}

run_bridge first
run_bridge second
cmp "$WORK/first.stdout" "$WORK/second.stdout" ||
    assert_fail 'the two BridgeReport executions produced different bytes'
node "$CASES/check-production-field-access.mjs" \
    "$SOURCE" "$WORK/bridge.c" "$GOLDEN" "$WORK/first.stdout"

node "$ROOT/spec/aggregate-layout-v1/layout.mjs" describe \
    "$ROOT/spec/aggregate-layout-v1/targets/x86_64-linux.json" \
    "$CASES/layout.json" \
    >"$WORK/layout.output.json" 2>"$WORK/layout.stderr" ||
    assert_fail "AggregateLayout v1 refused the BridgeReport descriptor"
assert_file_nonempty 'computed BridgeReport AggregateLayout' "$WORK/layout.output.json"
assert_file_empty 'BridgeReport AggregateLayout stderr' "$WORK/layout.stderr"
node "$CASES/check-layout.mjs" "$WORK/layout.output.json" "$WORK/bridge.c"

KOFUN_BUILD_DIR="$WORK/sidecar-build/stage1" \
KOFUN_STAGE2_BUILD_DIR="$WORK/sidecar-build/stage2" \
KOFUN_STAGE2_EVENTS_BUILD_DIR="$WORK/sidecar-build/events" \
KOFUN_STAGE2_COMPILER="$STAGE2" \
    "$ROOT/bin/kofun" check "$SOURCE" \
    --emit-typed-sidecar "$WORK/bridge.kofun-semantic.json" \
    --generation 1 \
    >"$WORK/sidecar.stdout" 2>"$WORK/sidecar.stderr" ||
    assert_fail "mixed BridgeReport did not produce a complete typed sidecar"
assert_eq 'typed-sidecar check stdout' \
    "$(cat "$WORK/sidecar.stdout")" "ok: $SOURCE"
assert_file_empty 'typed-sidecar check stderr' "$WORK/sidecar.stderr"
assert_file_nonempty 'mixed BridgeReport typed sidecar' \
    "$WORK/bridge.kofun-semantic.json"
node "$ROOT/spec/typed-sidecar/validate.mjs" validate \
    "$WORK/bridge.kofun-semantic.json"
node "$CASES/check-sidecar.mjs" \
    "$WORK/bridge.kofun-semantic.json" "$SOURCE"

expect_refusal() {
    label=$1
    source=$2
    expected=$3
    set +e
    "$STAGE2" "$source" \
        "$WORK/refuse-$label.c" \
        "$WORK/refuse-$label.ir" \
        "$WORK/refuse-$label.tokens" \
        >"$WORK/refuse-$label.stdout" \
        2>"$WORK/refuse-$label.stderr"
    status=$?
    set -e
    assert_num "$label refusal status" "$status" -eq 1
    assert_file_empty "$label refusal internal stderr" \
        "$WORK/refuse-$label.stderr"
    cmp "$expected" "$WORK/refuse-$label.stdout" ||
        assert_fail "$label refusal diagnostic is not byte-exact"
    assert_absent "$label rejected C artifact" "$WORK/refuse-$label.c"
}

# Reuse the existing exact boundary fixtures. The focused bridge adds only the
# named nested path that neither owning corpus already had.
expect_refusal capacity-65 \
    "$ROOT/tests/stage2/list-int-values/oversized.kofun" \
    "$ROOT/tests/stage2/list-int-values/oversized.stdout"
expect_refusal list-text-field \
    "$ROOT/tests/conformance/records/stage2_unsupported_field.kofun" \
    "$ROOT/tests/conformance/records/stage2_unsupported_field.diagnostic"
expect_refusal named-nested-record-list \
    "$CASES/nested_record_list.kofun" \
    "$CASES/nested_record_list.diagnostic"

sh "$ROOT/tests/conformance/check-capabilities.sh" >/dev/null
node "$CASES/check-capability-truth.mjs" "$CAPABILITIES"

mutate_capability() {
    output=$1
    corpus=$2
    state=$3
    evidence=$4
    reason=$5
    awk -F '\t' -v OFS='\t' \
        -v wanted="$corpus" \
        -v replacement_state="$state" \
        -v replacement_evidence="$evidence" \
        -v replacement_reason="$reason" '
        $1 == "c11-stage2" && $2 == wanted {
            $3 = replacement_state
            $4 = replacement_evidence
            $5 = replacement_reason
        }
        { print }
    ' "$CAPABILITIES" >"$output"
}

expect_truth_mutation_refused() {
    label=$1
    pattern=$2
    manifest=$3
    sh "$ROOT/tests/conformance/check-capabilities.sh" "$manifest" >/dev/null ||
        assert_fail "$label mutation is not structurally valid"
    set +e
    node "$CASES/check-capability-truth.mjs" "$manifest" \
        >"$WORK/$label.stdout" 2>"$WORK/$label.stderr"
    status=$?
    set -e
    assert_num "$label capability-truth status" "$status" -eq 1
    assert_file_empty "$label capability-truth stdout" "$WORK/$label.stdout"
    assert_grep "$label capability-truth diagnostic" \
        -Fq "$pattern" "$WORK/$label.stderr"
}

old_list='The Stage 2 C11 Core lowers only bounded List[Int] locals and direct signatures; general lists and record fields remain unsupported'
old_text='The Stage 2 C11 Core does not lower Text values in this backend profile'
mutate_capability "$WORK/old-list.tsv" list unsupported - "$old_list"
expect_truth_mutation_refused old-list 'old false wording' "$WORK/old-list.tsv"
mutate_capability "$WORK/old-text.tsv" text unsupported - "$old_text"
expect_truth_mutation_refused old-text 'old false wording' "$WORK/old-text.tsv"
mutate_capability "$WORK/promoted-list.tsv" list supported \
    tests/conformance/run.sh -
expect_truth_mutation_refused promoted-list \
    'must remain unsupported for the general profile' "$WORK/promoted-list.tsv"
mutate_capability "$WORK/promoted-text.tsv" text supported \
    tests/conformance/run.sh -
expect_truth_mutation_refused promoted-text \
    'must remain unsupported for the general profile' "$WORK/promoted-text.tsv"

printf '%s\n' \
    'PASS: strict C11 executes the mixed Text/List[Int]/Int report twice against one exact golden' \
    'PASS: pass/return, field reads, len, checked indexing, UTF-8, and copy-not-view behavior are observed' \
    'PASS: capacity 65, List[Text], and a named nested record/list path refuse exactly with no C artifact' \
    'PASS: old capability denials and accidental general list/Text promotion are rejected'
