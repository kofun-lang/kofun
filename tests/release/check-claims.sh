#!/bin/sh
# Release claim manifest gate.
#
# Three things are checked, in order of how badly their absence would mislead:
#
#   1. the manifest still joins every published capability to its evidence;
#   2. the checker still refuses each way that join can be broken; and
#   3. the committed evidence pack is exactly what the manifest generates.
#
# (2) matters as much as (1). A checker that quietly stopped enforcing a rule
# would keep reporting PASS on the honest manifest, so every rule is proved by
# a fixture that must fail.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
VALIDATOR="$ROOT/tests/release/validate-claims.mjs"
GENERATOR="$ROOT/tests/release/make-invalid.mjs"
PACK="artifacts/release-evidence"

if test "$#" -gt 0; then
    printf '%s\n' "release-claims: unexpected argument: $1" >&2
    printf '%s\n' "release-claims: usage: sh tests/release/check-claims.sh" >&2
    exit 2
fi

TMP_PARENT="$ROOT/build/tmp"
mkdir -p "$TMP_PARENT"
WORK=$(mktemp -d "$TMP_PARENT/release-claims.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

node --check "$VALIDATOR"
node --check "$GENERATOR"

# The shared Taskfile reader follows both dependency forms. The honest fixture
# proves a serialized `- task:` edge reaches its children without treating the
# YAML mapping as shell text; the controlled omission proves a removed edge is
# not retained by a permissive parser. `bounded-bytes` depends on this exact
# traversal for its published `cc` prerequisite.
node --input-type=module - "$ROOT/tests/lib/taskfile.mjs" "$WORK" <<'NODE'
import { writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const [modulePath, fixtureRoot] = process.argv.slice(2)
const { taskfileCommands } = await import(pathToFileURL(modulePath))
const honest = `version: '3'
tasks:
  serial:
    deps: [setup]
    cmds:
      - task: first
      - cmd: "node direct.mjs"
      - task: second
  setup:
    cmds:
      - "sh setup.sh"
  first:
    cmds:
      - "sh first.sh"
  second:
    cmds:
      - "sh second.sh"
`

function observed(source) {
    writeFileSync(`${fixtureRoot}/Taskfile.yml`, source)
    const entry = taskfileCommands(fixtureRoot).get('serial')
    return JSON.stringify({ deps: entry.deps, cmds: entry.cmds })
}

const complete = JSON.stringify({
    deps: ['setup', 'first', 'second'],
    cmds: ['node direct.mjs'],
})
if (observed(honest) !== complete) {
    throw new Error('Taskfile reader did not follow the serialized child-task edges')
}
const omitted = honest.replace('      - task: first\n', '')
const afterOmission = JSON.stringify({
    deps: ['setup', 'second'],
    cmds: ['node direct.mjs'],
})
if (observed(omitted) !== afterOmission) {
    throw new Error('Taskfile reader accepted the removed child-task edge')
}
NODE

node "$VALIDATOR" schema
node "$VALIDATOR" validate

# Every mutation must be refused, and must name the row it broke. A refusal
# that blamed the wrong claim would send a reader to the wrong file.
mutations=0
node "$GENERATOR" list > "$WORK/mutations.tsv"
while IFS='	' read -r mutation blame; do
    test -n "$mutation" || continue
    mutations=$((mutations + 1))
    node "$GENERATOR" "$mutation" "$WORK/$mutation.json"
    if node "$VALIDATOR" validate "$WORK/$mutation.json" \
        > "$WORK/$mutation.out" 2> "$WORK/$mutation.err"
    then
        printf '%s\n' \
            "FAIL: release claims: the checker accepted the \`$mutation\` mutation" >&2
        exit 1
    fi
    if ! grep -qF -- "$blame" "$WORK/$mutation.err"; then
        printf '%s\n' \
            "FAIL: release claims: the \`$mutation\` refusal does not name \`$blame\`" >&2
        cat "$WORK/$mutation.err" >&2
        exit 1
    fi
    if ! grep -q 'Repair: ' "$WORK/$mutation.err"; then
        printf '%s\n' \
            "FAIL: release claims: the \`$mutation\` refusal carries no repair instruction" >&2
        exit 1
    fi
done < "$WORK/mutations.tsv"

if test "$mutations" -eq 0; then
    printf '%s\n' "FAIL: release claims: no negative mutations were exercised" >&2
    exit 1
fi

# The pack is generated twice into separate directories. Identical output is
# what makes it evidence rather than a snapshot of one machine's mood.
node "$VALIDATOR" evidence "$WORK/pack-a" > /dev/null
node "$VALIDATOR" evidence "$WORK/pack-b" > /dev/null
for page in index.json CLAIMS.md EVIDENCE.md LIMITS.md REPRO.md; do
    if ! cmp -s "$WORK/pack-a/$page" "$WORK/pack-b/$page"; then
        printf '%s\n' \
            "FAIL: release claims: $page is not deterministic across runs" >&2
        exit 1
    fi
    if ! cmp -s "$WORK/pack-a/$page" "$ROOT/$PACK/$page"; then
        printf '%s\n' \
            "FAIL: release claims: $PACK/$page is stale; run \`task release-evidence\`" >&2
        exit 1
    fi
done

printf '%s\n' \
    "PASS: release claims join their evidence, $mutations mutations are refused, and $PACK is current"
