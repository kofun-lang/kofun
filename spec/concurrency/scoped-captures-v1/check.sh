#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
HERE="$ROOT/spec/concurrency/scoped-captures-v1"
TYPED_SIDECAR="$ROOT/spec/tooling/typed-sidecar.md"
V2_SCHEMA="$ROOT/spec/typed-sidecar/kofun.typed-sidecar.v2.schema.json"
SUCCESSOR_ROUTE='spec/tooling/typed-sidecar.md#compatibility-and-privacy'
TMP_PARENT="$ROOT/build/tmp"
mkdir -p "$TMP_PARENT"
WORK=$(mktemp -d "$TMP_PARENT/scoped-captures-v1.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf '%s\n' "FAIL: scoped-capture contract: $*" >&2
    exit 1
}

check_frozen_v1() {
    manifest=$1
    report=$2
    if "$ROOT/bin/kofun-digest" -c "$manifest" >"$report" 2>&1; then
        return 0
    fi
    printf '%s\n' \
        "FAIL: scoped-capture contract: a frozen v1 contract or example changed; see $SUCCESSOR_ROUTE for the successor route" \
        >>"$report"
    return 1
}

for command in awk grep node
do
    if ! command -v "$command" >/dev/null 2>&1; then
        fail "$command is required"
    fi
done

node --check "$HERE/model.mjs"
node --check "$HERE/check.mjs"
node "$HERE/check.mjs"

cd "$ROOT"

# The version route is load-bearing: keep the normative section, the link at
# the freeze, and the v2 inheritance fact that explains why a changed object
# needs a successor-owned definition. These checks fail in both directions
# rather than letting release-evidence regeneration bless missing guidance.
grep -qF '## Compatibility and privacy' "$TYPED_SIDECAR" ||
    fail "typed-sidecar compatibility section is missing"
grep -qF \
    '| a new value already admitted by an existing free-form field and by its producer contract | use the existing schema and prove the value through its normal gates |' \
    "$TYPED_SIDECAR" ||
    fail "typed-sidecar existing-schema route is missing"
grep -qF \
    '| a new emitted fact kind, public reason, or node kind declared by a frozen semantic-event or v1 file | leave v1 unchanged and define the successor event/schema route |' \
    "$TYPED_SIDECAR" ||
    fail "typed-sidecar frozen-contract successor route is missing"
grep -qF \
    '| a new root or object shape | define a successor version that owns every changed definition rather than inheriting that definition from frozen v1 |' \
    "$TYPED_SIDECAR" ||
    fail "typed-sidecar successor-owned object route is missing"
grep -qF \
    '| a change to accepted semantics or to a v1 compatibility claim | record a separate amendment to DD-028 with compatibility evidence |' \
    "$TYPED_SIDECAR" ||
    fail "typed-sidecar DD-028 amendment route is missing"
grep -qF \
    'The existing `kofun.typed-sidecar/v2` schema is one instance of that route.' \
    "$TYPED_SIDECAR" ||
    fail "typed-sidecar v2 successor example is missing"
grep -qF \
    '[typed-sidecar compatibility route](../tooling/typed-sidecar.md#compatibility-and-privacy)' \
    "$HERE/../scoped-captures-v1.md" ||
    fail "the frozen-contract section does not link to $SUCCESSOR_ROUTE"

ref_counts=$(
    node --input-type=module - "$V2_SCHEMA" <<'NODE'
import fs from "node:fs";

const document = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const refs = [];

function visit(value) {
    if (Array.isArray(value)) {
        for (const item of value) visit(item);
        return;
    }
    if (value === null || typeof value !== "object") return;
    for (const [key, child] of Object.entries(value)) {
        if (key === "$ref" && typeof child === "string") refs.push(child);
        visit(child);
    }
}

visit(document);
const v1 = refs.filter((ref) =>
    ref.startsWith("kofun.typed-sidecar.v1.schema.json#")
);
const nodes = v1.filter((ref) =>
    ref === "kofun.typed-sidecar.v1.schema.json#/properties/nodes"
);
process.stdout.write(`${v1.length} ${nodes.length}`);
NODE
)
v1_refs=${ref_counts%% *}
v1_node_refs=${ref_counts#* }
test "$v1_refs" -eq 10 ||
    fail "typed-sidecar v2 has $v1_refs references into frozen v1; expected 10"
test "$v1_node_refs" -eq 1 ||
    fail "typed-sidecar v2 has $v1_node_refs references to frozen v1 nodes; expected 1"

# `bin/kofun-digest -c`, not GNU `sha256sum`: #1213 replaced that dependency
# with the repository's own tool precisely because `sha256sum` is absent
# outside a GNU userland, and this gate was the last caller it left behind.
# Four other gates already check their SHA256SUMS this way.
if ! check_frozen_v1 "$HERE/v1.sha256" "$WORK/current.report"; then
    cat "$WORK/current.report" >&2
    exit 1
fi
cat "$WORK/current.report"

# Prove the failure route without changing a frozen source: corrupt a private
# copy of the manifest, then require the exact successor pointer in the report.
zeros=0000000000000000000000000000000000000000000000000000000000000000
awk -v replacement="$zeros" \
    'NR == 1 { $1 = replacement } { print }' \
    "$HERE/v1.sha256" >"$WORK/mutated.sha256"
if check_frozen_v1 "$WORK/mutated.sha256" "$WORK/mutated.report"; then
    fail "a mutated frozen-v1 manifest was accepted"
fi
grep -qF \
    "FAIL: scoped-capture contract: a frozen v1 contract or example changed; see $SUCCESSOR_ROUTE for the successor route" \
    "$WORK/mutated.report" ||
    fail "the frozen-v1 refusal does not name the successor route"

profile_rows=$(awk 'NR > 1 { rows += 1 } END { print rows + 0 }' \
    bootstrap/selfhost/profile.tsv)
if test "$profile_rows" -ne 46; then
    fail "selfhost profile has $profile_rows rows; expected exactly 46"
fi

printf '%s\n' \
    'PASS: scope-HIR v2 identities, places, captures, links, order, and bounds are frozen' \
    'PASS: KSE2 capture frames and typed-sidecar v2 captures are structured and private' \
    'PASS: selfhost-HIR, semantic-events, typed-sidecar v1 bytes and the 46-row profile are unchanged' \
    'PASS: the typed-sidecar successor route, v2 inheritance, and frozen-manifest refusal are pinned'
