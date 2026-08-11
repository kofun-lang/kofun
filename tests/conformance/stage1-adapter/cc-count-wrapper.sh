#!/usr/bin/env sh
# A `cc` that records which compiles it was asked for before performing them.
#
# KOFUN_STAGE1_CC_LOG names a file; one line is appended per invocation, holding
# every operand. The gate reads it to count how many times the Stage 1 seed was
# compiled during one conformance run — "once per runner, not once per fixture"
# is a claim about a number, so something has to count.
set -eu

test -n "${KOFUN_STAGE1_CC_LOG:-}" || {
    printf '%s\n' "cc-count-wrapper: KOFUN_STAGE1_CC_LOG is unset" >&2
    exit 2
}

printf '%s\n' "$*" >>"$KOFUN_STAGE1_CC_LOG"

exec "${KOFUN_STAGE1_CC_REAL:-cc}" "$@"
