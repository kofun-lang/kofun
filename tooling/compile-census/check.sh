#!/bin/sh
set -eu

# The compile census (#1485) and its negative self-tests.
#
# Two commands and not one, for the same reason as
# `tooling/machine-dependent/check.sh`: the checker proves the ledger describes
# the run, and the self-test proves the checker still refuses. A checker that
# quietly stopped enforcing the ceiling would keep reporting PASS on an honest
# ledger.
#
# The checker is a no-op outside a full verify run, and says so rather than
# passing silently: it reads the completed census that `verify-runner.sh`
# produces, and there is nothing to read without one.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

command -v node >/dev/null 2>&1 || {
    printf '%s\n' 'FAIL: compile census: Node.js is required' >&2
    exit 1
}

node --check "$ROOT/tooling/compile-census/census.mjs"
node --check "$ROOT/tooling/compile-census/check.mjs"
node --check "$ROOT/tooling/compile-census/self-test.mjs"

node "$ROOT/tooling/compile-census/check.mjs"
node "$ROOT/tooling/compile-census/self-test.mjs"
