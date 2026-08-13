#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ASSERT_CONTEXT="example law evidence"
. "$ROOT/tests/assertions/assert.sh"

EVIDENCE="$ROOT/artifacts/optional-bool-monad.evidence.json"
SOURCE="$ROOT/examples/proven_optional_bool_monad.kofun"

assert_regular_file 'optional Bool monad source' "$SOURCE"
assert_regular_file 'optional Bool monad evidence binding' "$EVIDENCE"

fields=$(node -e '
const fs = require("node:fs");
const evidence = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
console.log(evidence.schema);
console.log(evidence.status);
console.log(evidence.source.path);
console.log(evidence.source.sha256);
console.log(Array.isArray(evidence.diagnostics) && evidence.diagnostics.length > 0 ? "diagnosed" : "missing");
' "$EVIDENCE")

schema=$(printf '%s\n' "$fields" | sed -n '1p')
status=$(printf '%s\n' "$fields" | sed -n '2p')
source_path=$(printf '%s\n' "$fields" | sed -n '3p')
recorded_hash=$(printf '%s\n' "$fields" | sed -n '4p')
diagnostic_state=$(printf '%s\n' "$fields" | sed -n '5p')
actual_hash=$("$ROOT/bin/kofun-sha256" "$SOURCE" | awk '{ print $1 }')

assert_eq 'artifact schema' "$schema" 'kofun.law-evidence/v1'
assert_eq 'artifact truth state' "$status" 'unverified'
assert_eq 'bound source path' "$source_path" 'examples/proven_optional_bool_monad.kofun'
assert_eq 'bound source digest' "$recorded_hash" "$actual_hash"
assert_eq 'unverified state explains why no result is asserted' \
    "$diagnostic_state" 'diagnosed'

assert_not_grep 'unverified artifact must not claim a passing result' \
    -Fq -- '"status": "passed"' "$EVIDENCE"
assert_not_grep 'unverified artifact must not claim finite proof assurance' \
    -Fq -- 'proven-finite' "$EVIDENCE"
assert_not_grep 'unverified artifact must not retain historical case counts' \
    -Fq -- 'cases_checked' "$EVIDENCE"

printf 'example law evidence: exact source binding, honestly unverified: PASS\n'
