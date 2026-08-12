#!/bin/sh
set -eu

# The #1224 gate: the production KSE2 capture codec and typed-sidecar v2
# capture projector, joined to #1219's frozen contract.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
node --check "$ROOT/tooling/typed-sidecar/captures.mjs"
node --check "$ROOT/tests/typed-sidecar/captures_test.mjs"
node "$ROOT/tests/typed-sidecar/captures_test.mjs"

# v1 is untouched by this slice, so its own gates are the evidence for that
# rather than a claim in a comment.
sh "$ROOT/tests/typed-sidecar/codec.sh"
