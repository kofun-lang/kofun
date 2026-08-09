#!/usr/bin/env sh
set -eu

# Two documents cannot both be right (#1138): five sentences called the
# bootstrap C artifacts "audited" while docs/ROADMAP.md listed "audited
# bootstrap chain" as an M4 deliverable, and no audit record existed. The
# wording was corrected to what is true — the seeds are hash-pinned and gated,
# not audited — but a correction is only true on the day it is written.
#
# So this gate holds the two halves against each other rather than banning a
# word outright. While ROADMAP still lists the audited bootstrap chain as an
# open deliverable, the prose surfaces may not describe the artifacts as
# already audited. When the audit is performed and recorded, that ROADMAP line
# goes, and this gate stops constraining the word in the same commit.
#
# It is deliberately narrow. It reads prose surfaces only, and it matches the
# artifacts being *described* as audited, not the word in every context — the
# ROADMAP deliverable itself, the "can be independently audited" property, and
# any future audit record all have to remain sayable.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

ROADMAP=docs/ROADMAP.md
SURFACES="README.md DESIGN.md bootstrap/README.md docs/SECURITY.md"

test -f "$ROADMAP" || {
    printf '%s\n' "audited-claim: $ROADMAP is missing" >&2
    exit 2
}

# The deliverable's own line, which is what makes the claim premature.
if grep -Eq '^- audited bootstrap chain[[:space:]]*$' "$ROADMAP"; then
    DELIVERABLE_OPEN=true
else
    DELIVERABLE_OPEN=false
fi

failed=false

if test "$DELIVERABLE_OPEN" = true; then
    for surface in $SURFACES; do
        test -f "$surface" || continue
        # "audited <noun>" and "the audited ..." describe the artifact as having
        # been audited. "can be independently audited" states a property and is
        # not that claim.
        hits=$(grep -nE '\baudited\b' "$surface" |
            grep -vE '\b(be|being|independently) audited\b' || true)
        test -z "$hits" || {
            failed=true
            printf '%s\n' \
                "audited-claim: $surface describes the artifacts as audited," \
                "  while $ROADMAP still lists 'audited bootstrap chain' as an open" \
                "  M4 deliverable and no audit record exists:" \
                >&2
            printf '    %s\n' "$hits" >&2
        }
    done
fi

test "$failed" = false || {
    printf '%s\n' \
        "  Either record the audit and close the deliverable, or say what is" \
        "  true: the seeds are hash-pinned (bootstrap/manifest.json," \
        "  bootstrap/stage1/SHA256SUMS) and gated, which is a real and" \
        "  different property." >&2
    exit 1
}

if test "$DELIVERABLE_OPEN" = true; then
    printf '%s\n' \
        "PASS: no prose surface claims an audit while the M4 deliverable is open"
else
    printf '%s\n' \
        "PASS: the audited bootstrap chain deliverable is closed; the word is unconstrained"
fi
