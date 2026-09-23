#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SERVER="$ROOT/tooling/lsp/kofun-lsp"
RESULTS="${KOFUN_LSP_RESULTS:-$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}lsp/performance.json}"
REVISION=$(git -C "$ROOT" rev-parse --verify HEAD)
BRIDGE="$ROOT/tooling/lsp/generated/semantic-bridge.node"
DISABLED_BRIDGE="$ROOT/tooling/lsp/generated/semantic-bridge.node.issue866-disabled"
ASSERT_CONTEXT='lsp'
. "$ROOT/tests/assertions/assert.sh"

cleanup() {
    if test -f "$DISABLED_BRIDGE"
    then
        mv "$DISABLED_BRIDGE" "$BRIDGE"
    fi
}
trap cleanup EXIT HUP INT TERM

# The bundle used to be produced by the extension's `vscode:prepublish`. The
# extension is hjosugi/kofun-vscode now; the server it packages stays here,
# because the three generated modules below must equal this repository's own
# typed-sidecar sources byte for byte, and only this repository can prove that.
sh "$ROOT/tooling/lsp/build-semantic-bundle.sh"
cmp "$ROOT/tooling/typed-sidecar/from-stage2.mjs" \
    "$ROOT/tooling/lsp/generated/from-stage2.mjs"
cmp "$ROOT/tooling/typed-sidecar/codec.mjs" \
    "$ROOT/tooling/lsp/generated/codec.mjs"
cmp "$ROOT/tooling/typed-sidecar/captures.mjs" \
    "$ROOT/tooling/lsp/generated/captures.mjs"
assert_file_nonempty "tooling/lsp/generated/semantic-bridge.node" \
    "$ROOT/tooling/lsp/generated/semantic-bridge.node"

node --check "$ROOT/tooling/lsp/server.js"
node --check "$ROOT/tooling/lsp/semantic-sidecar.mjs"
node --check "$ROOT/tooling/lsp/semantic-worker.mjs"
node --check "$ROOT/tooling/lsp/generated/from-stage2.mjs"
node --check "$ROOT/tooling/lsp/generated/codec.mjs"
node --check "$ROOT/tooling/lsp/generated/captures.mjs"
# Syntax-only checks do not resolve imports. Load the copied projector to
# prove that the bundle contains its complete static dependency closure.
node "$ROOT/tooling/lsp/generated/from-stage2.mjs"
node --check "$ROOT/tests/lsp/client.js"
node --check "$ROOT/tests/lsp/protocol_test.js"
node --check "$ROOT/tests/lsp/semantic_sidecar_test.mjs"
node --check "$ROOT/tests/lsp/performance_test.js"
node --check "$ROOT/tests/lsp/bridge_fallback_test.js"
node --expose-gc "$ROOT/tests/lsp/semantic_sidecar_test.mjs"
node "$ROOT/tests/lsp/protocol_test.js" "$SERVER"
sh "$ROOT/tests/lsp/visibility.sh"
KOFUN_LSP_REVISION="$REVISION" \
    node "$ROOT/tests/lsp/performance_test.js" "$SERVER" "$RESULTS"

# A missing or foreign-platform native bridge must be observable and must not
# turn valid requests into silent nulls. Disable only the generated bridge,
# after all native-sidecar tests have used it, and restore it on every exit.
mv "$BRIDGE" "$DISABLED_BRIDGE"
node "$ROOT/tests/lsp/bridge_fallback_test.js" "$SERVER"
mv "$DISABLED_BRIDGE" "$BRIDGE"
