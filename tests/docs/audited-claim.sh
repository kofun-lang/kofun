#!/usr/bin/env sh
set -eu

# Two documents cannot both be right (#1138): five sentences called the
# bootstrap C artifacts "audited" while docs/ROADMAP.md listed "audited
# bootstrap chain" as an M4 deliverable, and no audit record existed. The
# wording was corrected to what is true — the seeds are hash-pinned and gated,
# not audited — and this holds that correction.
#
# The first version of this gate did not hold it. It decided the deliverable
# was open by grepping for a `- audited bootstrap chain` bullet in ROADMAP,
# and #1141 had already replaced that bullet list with a table. The pattern
# never matched, so the gate took its else-branch on every run and printed
# "the deliverable is closed; the word is unconstrained" — asserting, in CI,
# the very claim #1138 was filed about, while the row it had just read said
# `partial`. It was inert from the commit that introduced it.
#
# Two things changed as a result.
#
# It no longer keys off prose. The deliverable is closed when the audit record
# exists, at one declared path; nothing else decides it. Prose can be
# reformatted freely without silently disarming this. (`git ls-files | grep -i
# audit` is not the test either, tempting as it looks: this file matches it.)
#
# And it fails closed. Anything unexpected — a missing surface, an unreadable
# record path — constrains the word rather than releasing it. Releasing it is
# the outcome that restores the defect, so it is the one that has to be earned.
#
# The self-test at the bottom is what makes the above more than intent: it
# reintroduces the removed sentence into a scratch copy and requires this gate
# to refuse it. A gate that has gone inert fails there instead of passing
# green.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

# The audit, when it is performed, is recorded here. Its absence is what keeps
# the word unavailable; its presence is what releases it. docs/ROADMAP.md's
# `audited bootstrap chain` row cites this path as its evidence.
AUDIT_RECORD=bootstrap/AUDIT.md

SURFACES="README.md DESIGN.md bootstrap/README.md docs/SECURITY.md"

# "audited <noun>" describes the artifacts as having been audited. "can be
# independently audited" states a property, and the ROADMAP deliverable and any
# future audit record both have to remain sayable.
offending_lines() {
    scan_root=$1
    for surface in $SURFACES; do
        test -f "$scan_root/$surface" || continue
        grep -nE '\baudited\b' "$scan_root/$surface" |
            grep -vE '\b(be|being|independently) audited\b' |
            sed "s|^|$surface:|" || true
    done
}

if test -f "$ROOT/$AUDIT_RECORD"; then
    printf '%s\n' \
        "PASS: $AUDIT_RECORD records the audit; the word is unconstrained"
    exit 0
fi

# ------------------------------------------------------------------- the gate
hits=$(offending_lines "$ROOT")
if test -n "$hits"; then
    printf '%s\n' \
        "audited-claim: a prose surface describes the bootstrap artifacts as" \
        "  audited, while no audit record exists at $AUDIT_RECORD:" >&2
    printf '    %s\n' "$hits" >&2
    printf '%s\n' \
        "  Either record the audit there and close the docs/ROADMAP.md" \
        "  deliverable, or say what is true: the seeds are hash-pinned" \
        "  (bootstrap/manifest.json, bootstrap/stage1/SHA256SUMS) and gated," \
        "  which is a real and different property." >&2
    exit 1
fi

# --------------------------------------------------------------- self-test
# The failure this gate has already had once is silence, not a wrong answer.
# So it proves on every run that it still refuses the sentence #1138 removed.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kofun-audited-claim.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
for surface in $SURFACES; do
    test -f "$ROOT/$surface" || continue
    mkdir -p "$scratch/$(dirname "$surface")"
    cp "$ROOT/$surface" "$scratch/$surface"
done

test -f "$scratch/DESIGN.md" || {
    printf '%s\n' \
        "audited-claim: DESIGN.md is not among the scanned surfaces," \
        "  so the self-test cannot prove this gate still bites" >&2
    exit 1
}
printf '%s\n' 'Its audited C11 seed starts the compiler.' >>"$scratch/DESIGN.md"

if test -z "$(offending_lines "$scratch")"; then
    printf '%s\n' \
        "audited-claim: the scan did not flag a reintroduced audit claim." \
        "  This gate is inert — it would report PASS while the defect #1138" \
        "  describes is present. Fix the scan, not this assertion." >&2
    exit 1
fi

printf '%s\n' \
    "PASS: no prose surface claims an audit, and the scan still refuses one"
