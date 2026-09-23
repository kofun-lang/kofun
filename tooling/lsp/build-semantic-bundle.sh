#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SERVER="$ROOT/tooling/lsp"
OUTPUT=${KOFUN_LSP_BUNDLE_DIR:-"$SERVER/generated"}
CC=${CC:-cc}
NODE=${NODE:-node}

command -v "$CC" >/dev/null 2>&1 || {
    printf '%s\n' 'kofun-lsp: a C11 compiler is required' >&2
    exit 1
}
command -v "$NODE" >/dev/null 2>&1 || {
    printf '%s\n' 'kofun-lsp: node is required' >&2
    exit 1
}

NODE_PREFIX=$(
    "$NODE" -p \
        "require('path').resolve(require('path').dirname(process.execPath), '..')"
)
NODE_INCLUDE=
for candidate in \
    "${NODE_INCLUDE_DIR:-}" \
    "$NODE_PREFIX/include/node" \
    /usr/include/node \
    /usr/local/include/node
do
    if test -n "$candidate" && test -f "$candidate/node_api.h"; then
        NODE_INCLUDE=$candidate
        break
    fi
done
test -n "$NODE_INCLUDE" || {
    printf '%s\n' \
        'kofun-lsp: node_api.h was not found; set NODE_INCLUDE_DIR' >&2
    exit 1
}

mkdir -p "$OUTPUT"
bridge_temporary="$OUTPUT/.semantic-bridge.$$.node"
projector_temporary="$OUTPUT/.from-stage2.$$.mjs"
codec_temporary="$OUTPUT/.codec.$$.mjs"
captures_temporary="$OUTPUT/.captures.$$.mjs"
trap 'rm -f "$bridge_temporary" "$projector_temporary" "$codec_temporary" "$captures_temporary"' \
    0 1 2 15

case $(uname -s) in
    Darwin)
        shared_flags='-bundle -undefined dynamic_lookup'
        ;;
    Linux)
        shared_flags='-shared'
        ;;
    *)
        printf '%s\n' 'kofun-lsp: native bridge build supports Linux/macOS' >&2
        exit 1
        ;;
esac

# shellcheck disable=SC2086
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic -fPIC \
    $shared_flags \
    -DNAPI_VERSION=8 \
    -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
    -I"$NODE_INCLUDE" \
    -I"$ROOT/bootstrap/stage2" \
    "$SERVER/native/semantic_bridge.c" \
    "$ROOT/bootstrap/stage2/semantic_producer.c" \
    "$ROOT/bootstrap/stage2/semantic_events.c" \
    "$ROOT/bootstrap/stage2/sha256.c" \
    -o "$bridge_temporary"

cp "$ROOT/tooling/typed-sidecar/from-stage2.mjs" "$projector_temporary"
cp "$ROOT/tooling/typed-sidecar/codec.mjs" "$codec_temporary"
cp "$ROOT/tooling/typed-sidecar/captures.mjs" "$captures_temporary"
mv "$bridge_temporary" "$OUTPUT/semantic-bridge.node"
mv "$projector_temporary" "$OUTPUT/from-stage2.mjs"
mv "$codec_temporary" "$OUTPUT/codec.mjs"
mv "$captures_temporary" "$OUTPUT/captures.mjs"
