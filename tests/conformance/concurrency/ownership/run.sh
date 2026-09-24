#!/bin/sh
# Production scoped-parallel ownership (#1162) against the accepted model.
# The comparison lives in check.mjs, beside the model it imports.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
cd "$ROOT"
exec node tests/conformance/concurrency/ownership/check.mjs
