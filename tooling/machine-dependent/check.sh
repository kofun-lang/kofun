#!/bin/sh
set -eu

# The machine-dependent bound ledger (#1472) and its negative self-tests.
#
# Two commands and not one: the checker proves the ledger describes the tree,
# and the self-test proves the checker still refuses. A checker that quietly
# stopped enforcing a rule would keep reporting PASS on an honest ledger, which
# is the failure `tests/diagnostics/check.sh` and
# `tooling/forbidden-requirements/self-test.mjs` exist to prevent in their own
# ledgers.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

command -v node >/dev/null 2>&1 || {
    printf '%s\n' 'FAIL: machine-dependent: Node.js is required' >&2
    exit 1
}

node --check "$ROOT/tooling/machine-dependent/detect.mjs"
node --check "$ROOT/tooling/machine-dependent/check.mjs"
node --check "$ROOT/tooling/machine-dependent/self-test.mjs"

node "$ROOT/tooling/machine-dependent/check.mjs"
node "$ROOT/tooling/machine-dependent/self-test.mjs"
