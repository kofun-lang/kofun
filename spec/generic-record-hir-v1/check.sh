#!/usr/bin/env sh
# Gate for the generic-record HIR v1 contract (#1674).
#
# Producer-independent: the oracle recomputes every identity from its preimage
# with the #303 frame and checks the canonical document, the substituted
# fields, the limits and the refusals. The compiler entry that must reproduce
# these bytes is the next slice and joins this gate then.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/spec/generic-record-hir-v1"

command -v node >/dev/null 2>&1 || {
    printf '%s\n' "generic-record-hir requires node" >&2
    exit 1
}

node --check "$HERE/model.mjs"
node --check "$HERE/check.mjs"
exec node "$HERE/check.mjs"
