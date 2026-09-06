#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
exec node "$ROOT/tests/conformance/move-call-crossings/check.mjs"
