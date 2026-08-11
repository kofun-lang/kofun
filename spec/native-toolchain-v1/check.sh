#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROFILE=${1:-all}

node "$ROOT/spec/native-toolchain-v1/check.mjs" "$PROFILE"
