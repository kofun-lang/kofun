#!/bin/sh
set -eu

# The B6 reproduction packet, exercised end to end:
#
#     sh bootstrap/selfhost/check-b6-report.sh
#
# `reproduce.sh` is the command an independent builder runs and
# `check-reproduction-report.sh` is what a reviewer runs on what they send
# back. Neither is worth anything if the second passes reports the first could
# never have produced, so this gate runs the real command, validates its real
# report, and then damages that report one way at a time and requires each
# damage to be refused.
#
# It also validates a retained report whose subject has moved. That is not an
# oversight: a reviewer's ordinary situation is a report about a commit they do
# not have, and the structural half of the validator has to work there. The
# retained report is therefore checked structurally and never
# `--against-checkout`, and the live one is checked both ways.
#
# This gate does not close B6 and cannot. It proves the mechanics exist and
# refuse the things they say they refuse.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CASES="$ROOT/bootstrap/selfhost/b6"
WORK=${KOFUN_B6_REPORT_WORK:-"$ROOT/build/${KOFUN_GATE_WORK_NAMESPACE:+$KOFUN_GATE_WORK_NAMESPACE/}selfhost-b6-report"}
ASSERT_CONTEXT='selfhost b6 report'
. "$ROOT/tests/assertions/assert.sh"

cd "$ROOT"

rm -rf "$WORK"
mkdir -p "$WORK"

RUNNER="$ROOT/bootstrap/selfhost/reproduce.sh"
VALIDATOR="$ROOT/bootstrap/selfhost/check-reproduction-report.sh"

# ---------------------------------------------------------------------------
# 1. The runner refuses to produce a report with no builder behind it.
#
# The identity and the basis are the two fields nothing downstream can derive,
# so they are required at the only moment someone is present to supply them.
# ---------------------------------------------------------------------------
expect_runner_refusal() {
    stem=$1
    shift
    set +e
    env "$@" sh "$RUNNER" "$WORK/refused-$stem" "$WORK/refused-$stem.tsv" \
        >"$WORK/refused-$stem.stdout" 2>"$WORK/refused-$stem.stderr"
    refusal_status=$?
    set -e
    assert_num "runner refusal status for $stem" "$refusal_status" -ne 0
    assert_absent "refused-$stem.tsv" "$WORK/refused-$stem.tsv"
}

expect_runner_refusal no-identity \
    KOFUN_B6_BUILDER_IDENTITY= KOFUN_B6_BUILDER_BASIS=basis
assert_grep "refused-no-identity.stderr" -F 'KOFUN_B6_BUILDER_IDENTITY' \
    "$WORK/refused-no-identity.stderr"
expect_runner_refusal no-basis \
    KOFUN_B6_BUILDER_IDENTITY=someone KOFUN_B6_BUILDER_BASIS=
assert_grep "refused-no-basis.stderr" -F 'KOFUN_B6_BUILDER_BASIS' \
    "$WORK/refused-no-basis.stderr"
expect_runner_refusal separator-in-identity \
    'KOFUN_B6_BUILDER_IDENTITY=some|one' KOFUN_B6_BUILDER_BASIS=basis
assert_grep "refused-separator-in-identity.stderr" -F 'must not contain' \
    "$WORK/refused-separator-in-identity.stderr"

# ---------------------------------------------------------------------------
# 2. The real run, and the real report.
# ---------------------------------------------------------------------------
KOFUN_B6_BUILDER_IDENTITY='kofun repository self-check' \
KOFUN_B6_BUILDER_BASIS='the repository checkout itself, which is not independent of the project' \
    sh "$RUNNER" "$WORK/packet" "$WORK/report.tsv" >"$WORK/reproduce.stdout" 2>&1 ||
    {
        tail -n 30 "$WORK/reproduce.stdout" >&2 || true
        assert_fail 'the delegated reproduction command did not pass'
    }

# Each delegated step reported, and the runner retained their output rather
# than summarising it.
for step in declare-inputs check-declared-inputs check-inputs-sufficient \
    check-fixed-point; do
    assert_grep "reproduce.stdout" -F "PASS: $step" "$WORK/reproduce.stdout"
    assert_file_nonempty "$step.stdout" "$WORK/packet/logs/$step.stdout"
done

# The runner delegates: it holds no generation, digest-set, or fixed-point
# logic of its own. Reading this from the file rather than trusting the comment
# at the top of it is the difference between a rule and an intention.
assert_not_grep "reproduce.sh" -Eq \
    'derive_generation|corpus_run|corpus_compare' "$RUNNER"

sh "$VALIDATOR" "$WORK/report.tsv" >"$WORK/validate.stdout" 2>&1
assert_grep "validate.stdout" -F 'every required field present exactly once' \
    "$WORK/validate.stdout"
sh "$VALIDATOR" "$WORK/report.tsv" --against-checkout \
    >"$WORK/validate-subject.stdout" 2>&1
assert_grep "validate-subject.stdout" -F 'the report is about this checkout' \
    "$WORK/validate-subject.stdout"

# The two statements the packet exists to keep separate. A reader who quotes
# "the validator passed" must find these in the same output.
assert_grep "validate.stdout" -F 'cannot authenticate that claim' \
    "$WORK/validate.stdout"
assert_grep "validate.stdout" -F 'B6 is not closed by this command passing' \
    "$WORK/validate.stdout"

# The identity is over the semantic rows and nothing else, so rewriting the
# audit section leaves it unchanged.
awk -F '|' 'BEGIN { OFS = "|" }
    $1 == "audit" && $2 == "working_directory" { print $1, $2, "/elsewhere"; next }
    $1 == "audit" && $2 == "packet_directory" { print $1, $2, "/elsewhere/packet"; next }
    $1 == "audit" && $2 == "generated_at" { print $1, $2, "1999-12-31T23:59:59Z"; next }
    { print }' "$WORK/report.tsv" >"$WORK/rehomed.tsv"
assert_ne "the audit section was rewritten" \
    "$(cmp -s "$WORK/report.tsv" "$WORK/rehomed.tsv" && printf same || printf differs)" \
    same
sh "$VALIDATOR" "$WORK/rehomed.tsv" >"$WORK/rehomed.stdout" 2>&1
assert_eq "result identity after rehoming" \
    "$(awk -F '|' '$1 == "result_sha256" { print $2 }' "$WORK/rehomed.tsv")" \
    "$(awk -F '|' '$1 == "result_sha256" { print $2 }' "$WORK/report.tsv")"

# ---------------------------------------------------------------------------
# 3. A retained report about a subject that has moved.
# ---------------------------------------------------------------------------
sh "$VALIDATOR" "$CASES/report.tsv" >"$WORK/retained.stdout" 2>&1
assert_grep "retained.stdout" -F 'result_sha256 recomputes' "$WORK/retained.stdout"

# ---------------------------------------------------------------------------
# 4. Every refusal, by producing the thing refused.
# ---------------------------------------------------------------------------
expect_rejection() {
    stem=$1
    needle=$2
    set +e
    sh "$VALIDATOR" "$WORK/bad-$stem.tsv" \
        >"$WORK/bad-$stem.stdout" 2>"$WORK/bad-$stem.stderr"
    rejection_status=$?
    set -e
    assert_num "rejection status for $stem" "$rejection_status" -ne 0
    if ! grep -F "$needle" "$WORK/bad-$stem.stdout" "$WORK/bad-$stem.stderr" \
        >/dev/null
    then
        printf '%s\n' "----- $stem said:" >&2
        cat "$WORK/bad-$stem.stdout" "$WORK/bad-$stem.stderr" >&2
        assert_fail "$stem was refused for the wrong reason"
    fi
}

damage() {
    stem=$1
    shift
    "$@" <"$WORK/report.tsv" >"$WORK/bad-$stem.tsv"
    if cmp -s "$WORK/report.tsv" "$WORK/bad-$stem.tsv"; then
        assert_fail "damage $stem changed nothing"
    fi
}

damage unknown-field sed '$a\
invented|field|value'
expect_rejection unknown-field 'rows this validator does not understand'

damage missing-field grep -v '^result|corpus_cases|'
expect_rejection missing-field 'does not carry exactly its required keys'

damage extra-field sed '$a\
result|surplus|value'
expect_rejection extra-field 'does not carry exactly its required keys'

damage duplicate-row sed 's/^\(result|corpus_cases|.*\)$/\1\n\1/'
expect_rejection duplicate-row 'recorded more than once'

damage truncated head -c 400
expect_rejection truncated 'truncated'

damage empty-value sed 's/^result|corpus_cases|.*$/result|corpus_cases|/'
expect_rejection empty-value 'is present but empty'

damage short-digest \
    sed 's/^result|corpus_sha256|.*$/result|corpus_sha256|abc123/'
expect_rejection short-digest '64 hexadecimal characters'

damage empty-input-digest \
    sed 's/^result|corpus_observations_sha256|.*$/result|corpus_observations_sha256|e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855/'
expect_rejection empty-input-digest 'digest of an empty input'

damage zero-count sed 's/^result|corpus_cases|.*$/result|corpus_cases|0/'
expect_rejection zero-count 'is not a positive count'

damage path-leak \
    sed 's#^builder|basis|.*$#builder|basis|reproduced under /home/someone/kofun#'
expect_rejection path-leak 'leaks a path or a time'

damage broken-fixed-point \
    sed 's/^result|c3_sha256|.*$/result|c3_sha256|0000000000000000000000000000000000000000000000000000000000000000/'
expect_rejection broken-fixed-point 'does not record a fixed point'

damage broken-executable-fixed-point \
    sed 's/^provenance|a3_sha256|.*$/provenance|a3_sha256|0000000000000000000000000000000000000000000000000000000000000000/'
expect_rejection broken-executable-fixed-point 'does not record a fixed point'

damage stale-identity \
    sed 's/^result_sha256|.*$/result_sha256|0000000000000000000000000000000000000000000000000000000000000000/'
expect_rejection stale-identity 'result rows digest to'

damage wrong-schema \
    sed 's#^schema|kofun\.selfhost-b6-report/v1$#schema|kofun.selfhost-b6-report/v9#'
expect_rejection wrong-schema 'unknown report schema'

damage foreign-command \
    sed 's#^result|command|.*$#result|command|sh scripts/something-else.sh#'
expect_rejection foreign-command 'not produced by the declared command'

damage softened-independence \
    sed 's/^builder|independence|.*$/builder|independence|verified independent/'
expect_rejection softened-independence 'does not carry the statement this validator can support'

# A well-formed report about another tree.
#
# Built rather than waited for. The retained report describes whatever commit it
# was recorded at, so today it may still match this checkout and the refusal
# would have nothing to refuse — a check that is inert until the compiler moves
# is a check nobody has seen work. So this changes the subject and repairs the
# identity, producing a report that is internally consistent in every way the
# structural half can see. Only `--against-checkout` can tell, and it is the
# only mode that is asked to.
awk -F '|' 'BEGIN { OFS = "|" }
    $1 == "result" && $2 == "acquisition_set_sha256" {
        print $1, $2,
            "1111111111111111111111111111111111111111111111111111111111111111"
        next
    }
    { print }' "$WORK/report.tsv" >"$WORK/other-subject.rows"
grep '^result|' "$WORK/other-subject.rows" >"$WORK/other-subject.result"
other_identity=$("$ROOT/bin/kofun-digest" "$WORK/other-subject.result" |
    awk '{ print $1 }')
awk -F '|' -v identity="$other_identity" 'BEGIN { OFS = "|" }
    $1 == "result_sha256" { print $1, identity; next }
    { print }' "$WORK/other-subject.rows" >"$WORK/other-subject.tsv"

sh "$VALIDATOR" "$WORK/other-subject.tsv" >"$WORK/other-subject.stdout" 2>&1
assert_grep "other-subject.stdout" -F 'result_sha256 recomputes' \
    "$WORK/other-subject.stdout"

set +e
sh "$VALIDATOR" "$WORK/other-subject.tsv" --against-checkout \
    >"$WORK/stale-subject.stdout" 2>"$WORK/stale-subject.stderr"
stale_status=$?
set -e
assert_num "stale subject status" "$stale_status" -ne 0
assert_grep "stale-subject.stderr" -F 'this checkout is' \
    "$WORK/stale-subject.stderr"

printf '%s\n' \
    'PASS: the delegated command runs four existing gates and holds no reproduction logic of its own' \
    'PASS: its report validates structurally and against this checkout, and rehoming it leaves the identity' \
    'PASS: 16 damaged reports, a foreign subject, and 3 builderless runs are each refused, by their own reason' \
    'PASS: the packet records a builder claim it states it cannot authenticate, and does not close B6'
