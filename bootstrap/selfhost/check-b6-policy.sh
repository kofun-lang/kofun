#!/bin/sh
set -eu

# Whether a reproduction report qualifies as a **B6 attestation**:
#
#     sh bootstrap/selfhost/check-b6-policy.sh [REPORT]
#
# `check-reproduction-report.sh` already answers a different question — is this
# report well-formed, and does it describe this tree. Both can be yes for a
# report that closes nothing, and the committed `b6/report.tsv` is exactly
# that: a real, valid report whose builder is the repository checking itself.
#
# The gap between "valid report" and "attestation" is the policy in
# `b6/POLICY.md`, and this gate is the mechanical half of it. With no argument
# it runs its own fixtures and reports B6's status. With a REPORT argument it
# judges that one file and exits non-zero if it does not qualify.
#
# What it cannot do is authenticate a builder. `builder|identity` is text the
# builder typed, so this gate refuses *claimed* producer identities and
# POLICY.md section 3 makes the rest a human review step. A gate that claimed
# more would be the kind of green this repository exists to refuse.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
B6="$ROOT/bootstrap/selfhost/b6"
POLICY="$B6/POLICY.md"
PRODUCERS="$B6/producer-identities.tsv"
SELF_CHECK="$B6/report.tsv"
REGISTRY="$B6/closure-registry.json"
WORK=${KOFUN_B6_POLICY_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}selfhost-b6-policy"}
ASSERT_CONTEXT='selfhost b6 policy'

cd "$ROOT"
repo_root=$ROOT
. "$ROOT/bootstrap/selfhost/generations-lib.sh"

fail() {
    printf '%s\n' "FAIL: selfhost B6 policy: $*" >&2
    exit 1
}

identity_contract() {
    rm -rf "$WORK"
    mkdir -p "$WORK/current" "$WORK/mutated"

    jq -e '
        keys == ["acquisition_identity_schema", "attestations", "policy_bundle_schema",
                 "release_claim", "revocations", "schema", "status"] and
        .schema == "kofun.selfhost-b6-closure-registry/v1" and
        .acquisition_identity_schema == "kofun.selfhost-b6-acquisition/v1" and
        .policy_bundle_schema == "kofun.selfhost-b6-policy-bundle/v1" and
        (.status == "open" or .status == "closed") and
        (.attestations | type == "array") and (.revocations | type == "array") and
        (if .status == "open" then
            (.attestations | length) == 0 and .release_claim == null
         else
            (.attestations | length) > 0 and (.release_claim | type == "string")
         end)
    ' "$REGISTRY" >/dev/null ||
        fail "the B6 closure registry is malformed or its status/evidence join is incomplete"

    if test "$(jq -r .status "$REGISTRY")" = closed; then
        claim=$(jq -r .release_claim "$REGISTRY")
        jq -e --arg claim "$claim" \
            '.claims[] | select(.id == $claim and (.state == "implemented" or .state == "checkpoint"))' \
            release/claims.json >/dev/null ||
            fail "closed B6 registry does not join to an implemented/checkpoint release claim"
    fi

    grep -F 'bootstrap/selfhost/b6/closure-registry.json' bootstrap/manifest.json \
        >/dev/null || fail "bootstrap manifest does not delegate B6 truth to the registry"
    if grep -F 'Independent reproduction (B6, #274) remains open' \
        bootstrap/manifest.json >/dev/null
    then
        fail "bootstrap manifest still carries mutable B6 status"
    fi

    sh bootstrap/selfhost/declare-inputs.sh "$WORK/current" >/dev/null
    sh bootstrap/selfhost/check-declared-inputs.sh "$WORK/current" >/dev/null
    acquisition=$(digest_of "$WORK/current/declared-inputs.tsv")
    test "$(recorded_value "$WORK/current/declared-inputs.tsv" acquisition_identity_schema)" = \
        'kofun.selfhost-b6-acquisition/v1' ||
        fail "the generated acquisition set has the wrong identity schema"
    if grep -F '|path=bootstrap/selfhost/b6/closure-registry.json|' \
        "$WORK/current/declared-inputs.tsv" >/dev/null
    then
        fail "closure registry entered the generated acquisition set"
    fi

    # A closure-only edit is outside the set. Its bytes change, while the
    # already-derived canonical acquisition bytes and their digest do not.
    jq '.status = (if .status == "open" then "closed" else "open" end)' \
        "$REGISTRY" >"$WORK/mutated/registry.json"
    test "$(digest_of "$REGISTRY")" != \
        "$(digest_of "$WORK/mutated/registry.json")" ||
        fail "the closure-registry mutation changed no bytes"
    test "$acquisition" = "$(digest_of "$WORK/current/declared-inputs.tsv")" ||
        fail "a closure-only edit changed the acquisition identity"

    # The complete manifest is one input. Replace just that row with the
    # digest of a one-field mutation and require the set identity to move.
    jq '.truthful_status += " mutation"' bootstrap/manifest.json \
        >"$WORK/mutated/manifest.json"
    changed_manifest=$(digest_of "$WORK/mutated/manifest.json")
    awk -F '|' -v replacement="$changed_manifest" 'BEGIN { OFS = "|" }
        $1 == "input" && $2 == "role=manifest" {
            $4 = "sha256=" replacement
        }
        { print }
    ' "$WORK/current/declared-inputs.tsv" >"$WORK/mutated/manifest-inputs.tsv"
    test "$acquisition" != "$(digest_of "$WORK/mutated/manifest-inputs.tsv")" ||
        fail "a complete-manifest mutation did not stale the acquisition identity"

    policy=$(digest_of "$POLICY")
    producers=$(digest_of "$PRODUCERS")
    {
        printf 'schema|kofun.selfhost-b6-policy-bundle/v1\n'
        printf 'input|role=policy|path=bootstrap/selfhost/b6/POLICY.md|sha256=%s\n' "$policy"
        printf 'input|role=producer-identities|path=bootstrap/selfhost/b6/producer-identities.tsv|sha256=%s\n' "$producers"
    } >"$WORK/current/policy-bundle.tsv"
    { cat "$POLICY"; printf '\n'; } >"$WORK/mutated/POLICY.md"
    changed_policy=$(digest_of "$WORK/mutated/POLICY.md")
    {
        printf 'schema|kofun.selfhost-b6-policy-bundle/v1\n'
        printf 'input|role=policy|path=bootstrap/selfhost/b6/POLICY.md|sha256=%s\n' "$changed_policy"
        printf 'input|role=producer-identities|path=bootstrap/selfhost/b6/producer-identities.tsv|sha256=%s\n' "$producers"
    } >"$WORK/mutated/policy-bundle.tsv"
    test "$(digest_of "$WORK/current/policy-bundle.tsv")" != \
        "$(digest_of "$WORK/mutated/policy-bundle.tsv")" ||
        fail "a policy mutation did not stale the policy bundle"

    sh bootstrap/selfhost/check-reproduction-report.sh "$SELF_CHECK" \
        >"$WORK/retained.stdout"
    grep -F 'kofun.selfhost-b6-report/v1' "$WORK/retained.stdout" >/dev/null ||
        fail "the retained v1 report is no longer structurally identifiable"

    printf '%s\n' \
        'PASS: Option B keeps the whole bootstrap manifest in acquisition/v1 and the closure registry out' \
        'PASS: a registry-only mutation preserves the key while a manifest mutation stales it' \
        'PASS: policy-bundle/v1 has canonical component rows and a policy mutation stales it' \
        'PASS: registry status joins evidence/release truth, and the retained report stays historical v1'
}

field() {
    awk -F '|' -v s="$2" -v k="$3" '$1 == s && $2 == k { print $3; found = 1 }
        END { if (!found) exit 1 }' "$1"
}

CURRENT_SELF_CHECK=${KOFUN_B6_PRODUCER_REPORT:-}

ensure_current_self_check() {
    if test -n "$CURRENT_SELF_CHECK"; then
        test -f "$CURRENT_SELF_CHECK" ||
            fail "configured current producer report does not exist: $CURRENT_SELF_CHECK"
        return 0
    fi
    mkdir -p "$WORK/producer"
    KOFUN_B6_BUILDER_IDENTITY='kofun repository current self-check' \
    KOFUN_B6_BUILDER_BASIS='the current checkout itself, which is not independent of the project' \
        sh "$ROOT/bootstrap/selfhost/reproduce.sh" \
            "$WORK/producer/packet" "$WORK/producer/report.tsv" \
            >"$WORK/producer/reproduce.stdout" 2>"$WORK/producer/reproduce.stderr" || {
                tail -n 30 "$WORK/producer/reproduce.stdout" >&2 || true
                tail -n 30 "$WORK/producer/reproduce.stderr" >&2 || true
                fail "the current producer report could not be generated"
            }
    CURRENT_SELF_CHECK="$WORK/producer/report.tsv"
}

# One reason per refusal, printed to stderr and never to stdout, so a caller
# can tell a verdict from an explanation.
# `exit 1`, not `return 1`: a refusal must end the judgement, and a `return`
# inside `test ... && refuse ...` leaves the caller running the next rule with
# a stale verdict. Every caller therefore runs `judge` in a subshell.
refuse() {
    printf 'not a B6 attestation: %s\n' "$1" >&2
    exit 1
}

# The whole judgement, so the fixtures below and a real submission take the
# same path. Every refusal names the policy section that owns it. Always call
# it as `( judge REPORT )` — `refuse` exits, and the subshell is what confines
# that to one verdict.
judge() {
    report=$1

    test -f "$report" || refuse "no such report: $report"

    identity=$(field "$report" builder identity 2>/dev/null) ||
        refuse 'no `builder|identity` row (POLICY.md 3)'
    basis=$(field "$report" builder basis 2>/dev/null) ||
        refuse 'no `builder|basis` row (POLICY.md 3)'
    independence=$(field "$report" builder independence 2>/dev/null) ||
        refuse 'no `builder|independence` row (POLICY.md 3)'

    test -n "$identity" || refuse 'empty `builder|identity` (POLICY.md 3)'
    test -n "$basis" || refuse 'empty `builder|basis` (POLICY.md 3)'

    test "$independence" = \
        'claimed by the builder and not established by this report or its validator' ||
        refuse 'the `builder|independence` line is not the one the packet writes (POLICY.md 3)'

    # Section 1. The boundary is the data file, not this script.
    lowered=$(printf '%s' "$identity" | tr '[:upper:]' '[:lower:]')
    while IFS='	' read -r kind value _; do
        case "$kind" in '#'*|'') continue ;; esac
        test -n "$value" || continue
        pattern=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
        case "$kind" in
            exact)
                test "$lowered" = "$pattern" &&
                    refuse "identity \`$identity\` is producer-side (POLICY.md 1)"
                ;;
            substring)
                case "$lowered" in
                    *"$pattern"*)
                        refuse "identity \`$identity\` contains the producer-side marker \`$value\` (POLICY.md 1)"
                        ;;
                esac
                ;;
            *) refuse "producer-identities.tsv has an unknown kind \`$kind\`" ;;
        esac
    done <"$PRODUCERS"

    self_basis=$(field "$SELF_CHECK" builder basis)
    test "$basis" != "$self_basis" ||
        refuse 'the basis is the packet self-check basis (POLICY.md 1)'

    # Section 2. Recorded, not required to differ — but recorded.
    for key in host_compiler_identity operating_system kernel_release architecture libc; do
        field "$report" provenance "$key" >/dev/null 2>&1 ||
            refuse "no \`provenance|$key\` row; section 2 requires it recorded"
    done

    # Section 5. The freshness key is a digest, never wall time.
    key=$(field "$report" result acquisition_set_sha256 2>/dev/null) ||
        refuse 'no `result|acquisition_set_sha256`, so freshness cannot be decided (POLICY.md 5)'
    current=$(field "$CURRENT_SELF_CHECK" result acquisition_set_sha256)
    test "$key" = "$current" ||
        refuse "stale: acquisition set \`$key\` is not this tree's \`$current\` (POLICY.md 5)"

    # Section 6. Disagreement is a mismatch to investigate, not a bad file.
    theirs=$(awk -F '|' '$1 == "result_sha256" { print $2 }' "$report")
    ours=$(awk -F '|' '$1 == "result_sha256" { print $2 }' "$CURRENT_SELF_CHECK")
    test -n "$theirs" || refuse 'no `result_sha256` row'
    test "$theirs" = "$ours" ||
        refuse "mismatch: \`$theirs\` disagrees with the producer's \`$ours\` for the same key; POLICY.md 6 holds B6 open and opens an investigation"

    # A qualifying attestation is about the current checkout and the current
    # policy bundle. Run this after the policy-specific classifications above
    # so a stale key and a producer mismatch keep their distinct remedies.
    sh "$ROOT/bootstrap/selfhost/check-reproduction-report.sh" \
        "$report" --against-checkout >/dev/null 2>&1 ||
        refuse 'the report is malformed or policy-stale for this checkout (POLICY.md acquisition identity)'

    return 0
}

# A REPORT argument means "judge this one", for a reviewer with a submission in
# hand. No argument means "run the fixtures", for the gate.
if test "$#" -gt 0; then
    if test "$1" = '--identity-contract'; then
        test "$#" -eq 1 || fail "--identity-contract takes no report"
        identity_contract
        exit 0
    fi
    rm -rf "$WORK"
    mkdir -p "$WORK"
    ensure_current_self_check
    ( judge "$1" )
    printf 'PASS: %s qualifies as a B6 attestation under bootstrap/selfhost/b6/POLICY.md\n' "$1"
    exit 0
fi

. "$ROOT/tests/assertions/assert.sh"

rm -rf "$WORK"
mkdir -p "$WORK"
ensure_current_self_check

assert_regular_file 'the policy' "$POLICY"
assert_regular_file 'the producer boundary' "$PRODUCERS"
assert_regular_file 'the packet self-check report' "$SELF_CHECK"

# The policy and the data file are one fact. If the policy stops naming the
# file, a reader has prose and the gate has data and neither knows.
assert_grep 'POLICY.md names the producer boundary file' -F \
    'producer-identities.tsv' "$POLICY"
assert_grep 'POLICY.md records the selected option' -F \
    'An independent external party' "$POLICY"
# Section 10's own sentence, not the phrase `B6 stays open` — that phrase
# appears three times in this policy, so asserting it caught nothing: softening
# section 10 to "B6 is fine" left the other two occurrences and the check
# passed. Measured, not assumed: that mutation is why this line is specific.
assert_grep 'POLICY.md keeps B6 open when there is no builder' -F \
    'visibly blocked on an external party' "$POLICY"

# ---------------------------------------------------------------------------
# 1. The standing negative: the packet's own report is a valid report and is
#    not an attestation. This is the fixture that cannot rot, because it is the
#    file the packet actually ships.

set +e
( judge "$SELF_CHECK" ) >"$WORK/self.stdout" 2>"$WORK/self.stderr"
self_status=$?
set -e
assert_num 'the self-check report is refused' "$self_status" -ne 0
assert_grep 'self.stderr' -F 'producer-side' "$WORK/self.stderr"
assert_file_empty 'self.stdout' "$WORK/self.stdout"

# ---------------------------------------------------------------------------
# 2. A report that would qualify, then one damage at a time. Every refusal has
#    to come from its own reason — a gate that refuses everything for the same
#    reason has one rule wearing six hats.

external() {
    sed \
        -e 's/^builder|identity|.*/builder|identity|Rowan Iwasaki (independent)/' \
        -e 's/^builder|basis|.*/builder|basis|no affiliation with the Kofun project; own hardware/' \
        "$CURRENT_SELF_CHECK" >"$1"
}

external "$WORK/ok.tsv"
( judge "$WORK/ok.tsv" ) >"$WORK/ok.stdout" 2>"$WORK/ok.stderr"
assert_file_empty 'a qualifying report explains nothing' "$WORK/ok.stderr"

damage() {
    name=$1
    shift
    external "$WORK/$name.tsv"
    "$@" "$WORK/$name.tsv" >"$WORK/$name.edited" && mv "$WORK/$name.edited" "$WORK/$name.tsv"
    set +e
    ( judge "$WORK/$name.tsv" ) >"$WORK/$name.stdout" 2>"$WORK/$name.stderr"
    status=$?
    set -e
    assert_num "$name is refused" "$status" -ne 0
    assert_file_empty "$name writes no verdict" "$WORK/$name.stdout"
}

drop_row() { grep -v "^$1" "$2"; }
edit_row() { sed "$1" "$2"; }

damage producer-identity edit_row 's/^builder|identity|.*/builder|identity|claude-9999-some-agent/'
assert_grep 'producer-identity.stderr' -F 'producer-side marker' "$WORK/producer-identity.stderr"

damage self-check-basis edit_row 's/^builder|basis|.*/builder|basis|the repository checkout itself, which is not independent of the project/'
assert_grep 'self-check-basis.stderr' -F 'self-check basis' "$WORK/self-check-basis.stderr"

damage empty-basis edit_row 's/^builder|basis|.*/builder|basis|/'
assert_grep 'empty-basis.stderr' -F 'empty `builder|basis`' "$WORK/empty-basis.stderr"

damage no-identity drop_row 'builder|identity|'
assert_grep 'no-identity.stderr' -F 'no `builder|identity`' "$WORK/no-identity.stderr"

damage softened-independence edit_row 's/^builder|independence|.*/builder|independence|verified independent/'
assert_grep 'softened-independence.stderr' -F 'not the one the packet writes' "$WORK/softened-independence.stderr"

damage stale-key edit_row 's/^result|acquisition_set_sha256|.*/result|acquisition_set_sha256|0000000000000000000000000000000000000000000000000000000000000000/'
assert_grep 'stale-key.stderr' -F 'stale' "$WORK/stale-key.stderr"

damage no-provenance drop_row 'provenance|libc|'
assert_grep 'no-provenance.stderr' -F 'provenance|libc' "$WORK/no-provenance.stderr"

damage mismatch edit_row 's/^result_sha256|.*/result_sha256|1111111111111111111111111111111111111111111111111111111111111111/'
assert_grep 'mismatch.stderr' -F 'disagrees with' "$WORK/mismatch.stderr"

# ---------------------------------------------------------------------------
# 3. B6's status, stated rather than implied. A gate that passed silently with
#    no attestation on file would read as "B6 is fine".

attestations=$(find "$B6" -name 'attestation-*.tsv' 2>/dev/null | wc -l | tr -d ' ')
if test "$attestations" -eq 0; then
    b6_line='PASS: B6 remains OPEN: no attestation is on file, which POLICY.md 10 says is the honest outcome'
else
    for candidate in "$B6"/attestation-*.tsv; do
        ( judge "$candidate" )
    done
    b6_line="PASS: $attestations attestation(s) on file, each qualifying under POLICY.md"
fi

printf '%s\n' \
    'PASS: the policy names its producer boundary file, its selected option, and its no-builder outcome' \
    'PASS: the packet self-check report is a valid report and is refused as an attestation' \
    'PASS: 8 damaged attestations are refused, each by its own reason' \
    "$b6_line"
