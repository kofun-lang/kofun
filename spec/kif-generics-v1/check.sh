#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

for tool in node "${CC:-cc}"; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s\n' "kif-generics-codec requires $tool" >&2
        exit 1
    }
done

# The gate builds the production v1/v2 reader and offers it a v3 envelope, so
# `cc` is a hard requirement rather than an optional extra: skipping that step
# would leave "no old artifact is reinterpreted as v3" asserted only by the
# implementation that has the least reason to disagree.
exec node "$ROOT/spec/kif-generics-v1/check.mjs"
