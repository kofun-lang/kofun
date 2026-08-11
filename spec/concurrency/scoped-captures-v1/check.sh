#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
HERE="$ROOT/spec/concurrency/scoped-captures-v1"

fail() {
    printf '%s\n' "FAIL: scoped-capture contract: $*" >&2
    exit 1
}

for command in awk node sha256sum
do
    if ! command -v "$command" >/dev/null 2>&1; then
        fail "$command is required"
    fi
done

node --check "$HERE/model.mjs"
node --check "$HERE/check.mjs"
node "$HERE/check.mjs"

cd "$ROOT"
if ! sha256sum --check "$HERE/v1.sha256"; then
    fail "a frozen v1 contract or example changed"
fi

profile_rows=$(awk 'NR > 1 { rows += 1 } END { print rows + 0 }' \
    bootstrap/selfhost/profile.tsv)
if test "$profile_rows" -ne 46; then
    fail "selfhost profile has $profile_rows rows; expected exactly 46"
fi

printf '%s\n' \
    'PASS: scope-HIR v2 identities, places, captures, links, order, and bounds are frozen' \
    'PASS: KSE2 capture frames and typed-sidecar v2 captures are structured and private' \
    'PASS: selfhost-HIR, semantic-events, typed-sidecar v1 bytes and the 46-row profile are unchanged'
