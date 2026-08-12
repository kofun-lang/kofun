#!/bin/sh
set -eu

# The command an independent builder runs, and the report they send back:
#
#     KOFUN_B6_BUILDER_IDENTITY='who you are' \
#     KOFUN_B6_BUILDER_BASIS='why you are independent of the Kofun project' \
#         sh bootstrap/selfhost/reproduce.sh OUTPUT REPORT
#
# It reproduces nothing itself. Every step below is an existing gate, invoked
# in its own normalized environment, and this file only sequences them and
# writes down what they measured. That is deliberate: the moment a second
# implementation of the acquisition, sufficiency, or fixed-point logic exists,
# a builder can reproduce one of them and not the other, and nobody finds out
# which.
#
#     declare-inputs.sh          what must be obtained, with digests
#     check-declared-inputs.sh   the manifest describes this tree
#     check-inputs-sufficient.sh the declared set alone reproduces the chain
#     check-fixed-point.sh       C2 == C3 and A2 == A3
#
# No network access is required after the acquisition set is obtained; nothing
# here reaches for one.
#
# ## What the report is, and what it is not
#
# The report has four sections and they mean different things.
#
# `result|` is what two builders must agree on. It holds generated-C and corpus
# digests, counts, schemas, and the criterion — and nothing that depends on who
# ran it, where, or when. `result_sha256` is a digest over exactly those rows,
# so two reports agree when that one value agrees.
#
# `provenance|` is what a builder cannot be expected to match: the host
# compiler, the operating system, and the executable digests those produce.
# `bootstrap/selfhost/declare-inputs.sh` states the policy this follows — the
# generated C is deterministic and expected to reproduce under any conforming
# C11 compiler; the executables are not, and a difference there is a toolchain
# difference rather than a defect. Recording them is how a reviewer tells the
# two apart. Comparing them is not what makes a reproduction.
#
# `builder|` is supplied by whoever runs this, and is required. It is also not
# self-authenticating: a field saying "independent" is a claim typed by the
# person making it. Neither this command nor its validator can establish
# independence, and neither says it does. What they can do is refuse to produce
# a report that omits the claim, so an independence assessment has something to
# assess.
#
# `audit|` is time, path, and host. It is written last, it is optional to read,
# and it is excluded from `result_sha256` by construction — so a report that
# moved between machines still has the identity it was published with.

fail() {
    printf '%s\n' "FAIL: selfhost reproduce: $*" >&2
    exit 1
}

test "$#" -eq 2 ||
    fail "usage: sh bootstrap/selfhost/reproduce.sh OUTPUT REPORT"
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac
case "$2" in
    /*) report=$2 ;;
    *) report=$PWD/$2 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

. "$repo_root/bootstrap/selfhost/generations-lib.sh"

kofun_generations_toolchain

builder_identity=${KOFUN_B6_BUILDER_IDENTITY:-}
builder_basis=${KOFUN_B6_BUILDER_BASIS:-}
test -n "$builder_identity" ||
    fail "set KOFUN_B6_BUILDER_IDENTITY to who is running this; the report records the claim it cannot check"
test -n "$builder_basis" ||
    fail "set KOFUN_B6_BUILDER_BASIS to the basis on which you are independent of the Kofun project"
case "$builder_identity$builder_basis" in
    *'|'*) fail "builder identity and basis must not contain \`|\`, which separates report fields" ;;
    *"$(printf '\t')"*) fail "builder identity and basis must not contain a tab" ;;
esac

mkdir -p "$output"
logs="$output/logs"
rm -rf "$logs"
mkdir -p "$logs"

# Each step is delegated, and its output is retained. A builder who reports a
# failure sends these files, not a description of them.
step() {
    step_name=$1
    shift
    if "$@" >"$logs/$step_name.stdout" 2>"$logs/$step_name.stderr"; then
        printf 'PASS: %s\n' "$step_name"
        return 0
    fi
    printf '%s\n' "----- $step_name said:" >&2
    tail -n 20 "$logs/$step_name.stdout" >&2 || true
    tail -n 20 "$logs/$step_name.stderr" >&2 || true
    printf '%s\n' "-----" >&2
    fail "$step_name did not pass; its full output is under $logs"
}

step declare-inputs sh bootstrap/selfhost/declare-inputs.sh "$output"
step check-declared-inputs sh bootstrap/selfhost/check-declared-inputs.sh "$output"
step check-inputs-sufficient sh bootstrap/selfhost/check-inputs-sufficient.sh "$output"
step check-fixed-point sh bootstrap/selfhost/check-fixed-point.sh "$output"

manifest="$output/declared-inputs.tsv"
sufficient="$output/inputs-sufficient.tsv"
fixed_point="$output/fixed-point.tsv"
provenance="$output/provenance.tsv"
for required in "$manifest" "$sufficient" "$fixed_point" "$provenance"; do
    test -s "$required" ||
        fail "\`$required\` is missing after the gates ran; the packet is incomplete"
done

declared_count=$(grep -c '^input|' "$manifest")
acquisition_digest=$(digest_of "$manifest")

# Every observation file the validated bundle retained, one digest over the
# set. `$output/corpus/<case>/` is a directory per case, so the files are one
# level down; digesting the directories instead produced the digest of an empty
# stream and a successful exit, which is why `tree_digest` now refuses a
# non-file argument rather than reporting one on stderr and carrying on.
corpus_observation_count=$(find "$output/corpus" -type f | wc -l | tr -d ' ')
test "$corpus_observation_count" -gt 0 ||
    fail "the validated bundle retained no corpus observation"
set -- $(find "$output/corpus" -type f | LC_ALL=C sort)
test "$#" -eq "$corpus_observation_count" ||
    fail "corpus observation paths are not word-safe; $# of $corpus_observation_count survived splitting"
corpus_observations=$(tree_digest "$@")

# The closure record in `bootstrap/manifest.json` is a declared input, and
# `check-fixed-point.sh` has just asserted every one of its digests against
# this run. Its digest is what a later report is compared against, so it is
# recorded rather than recomputed from the parts.
closure_digest=$(
    {
        printf '%s\n' "$(manifest_closure_value schema)"
        printf '%s\n' "$(manifest_closure_value canonical_source_sha256)"
        printf '%s\n' "$(manifest_closure_value trusted_seed_sha256)"
        printf '%s\n' "$(manifest_closure_value corpus_sha256)"
        printf '%s\n' "$(manifest_closure_value c1_sha256)"
        printf '%s\n' "$(manifest_closure_value c2_sha256)"
        printf '%s\n' "$(manifest_closure_value c3_sha256)"
    } | "$repo_root/bin/kofun-digest" | awk '{ print $1 }'
)

work="$output/.report.$$"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"

# The semantic section. Two builders must agree on every row here, and on
# nothing outside it.
{
    printf 'result|report_schema|kofun.selfhost-b6-report/v1\n'
    printf 'result|command|sh bootstrap/selfhost/reproduce.sh OUTPUT REPORT\n'
    printf 'result|criterion|%s\n' "$KOFUN_GENERATIONS_CRITERION"
    printf 'result|normalized_environment|%s\n' "$KOFUN_GENERATIONS_ENVIRONMENT"
    printf 'result|declared_inputs_schema|%s\n' \
        "$(recorded_value "$manifest" schema)"
    printf 'result|inputs_sufficient_schema|%s\n' \
        "$(recorded_value "$sufficient" schema)"
    printf 'result|fixed_point_schema|%s\n' \
        "$(recorded_value "$fixed_point" schema)"
    printf 'result|closure_schema|%s\n' "$(manifest_closure_value schema)"
    printf 'result|acquisition_set_sha256|%s\n' "$acquisition_digest"
    printf 'result|declared_inputs|%s\n' "$declared_count"
    printf 'result|canonical_source_sha256|%s\n' \
        "$(recorded_value "$provenance" canonical_source_sha256)"
    printf 'result|trusted_seed_sha256|%s\n' \
        "$(recorded_value "$provenance" trusted_seed_sha256)"
    printf 'result|corpus_sha256|%s\n' \
        "$(recorded_value "$provenance" corpus_sha256)"
    printf 'result|runtime_headers_sha256|%s\n' \
        "$(recorded_value "$provenance" runtime_headers_sha256)"
    printf 'result|c1_sha256|%s\n' \
        "$(recorded_value "$provenance" c1_sha256)"
    printf 'result|c2_sha256|%s\n' \
        "$(recorded_value "$provenance" c2_sha256)"
    printf 'result|c3_sha256|%s\n' \
        "$(recorded_value "$fixed_point" c3_sha256)"
    printf 'result|c3_bytes|%s\n' "$(recorded_value "$fixed_point" c3_bytes)"
    printf 'result|fixed_point_closure_sha256|%s\n' "$closure_digest"
    printf 'result|corpus_cases|%s\n' \
        "$(recorded_value "$fixed_point" corpus_cases_a1_a3)"
    printf 'result|corpus_observations|%s\n' "$corpus_observation_count"
    printf 'result|corpus_observations_sha256|%s\n' "$corpus_observations"
} >"$work/result.tsv"

result_digest=$(digest_of "$work/result.tsv")

# The provenance section. Required, recorded, and deliberately outside the
# identity above: a builder on another toolchain reproduces the C and not the
# executables, which is the declared policy rather than a shortfall.
{
    printf 'provenance|host_compiler_identity|%s\n' "$compiler_identity"
    printf 'provenance|host_compiler_flags|%s\n' "$kofun_generations_flags"
    printf 'provenance|a1_sha256|%s\n' \
        "$(recorded_value "$provenance" a1_sha256)"
    printf 'provenance|a2_sha256|%s\n' \
        "$(recorded_value "$provenance" a2_sha256)"
    printf 'provenance|a3_sha256|%s\n' \
        "$(recorded_value "$fixed_point" a3_sha256)"
    printf 'provenance|operating_system|%s\n' "$(uname -s)"
    printf 'provenance|kernel_release|%s\n' "$(uname -r)"
    printf 'provenance|architecture|%s\n' "$(uname -m)"
    printf 'provenance|libc|%s\n' "$(
        if command -v ldd >/dev/null 2>&1; then
            ldd --version 2>/dev/null | head -n 1
        fi
        printf ''
    )"
    printf 'provenance|digest_tool|%s\n' "$(digest_of bin/kofun-digest)"
} >"$work/provenance.tsv"

{
    printf 'schema|kofun.selfhost-b6-report/v1\n'
    printf 'result_sha256|%s\n' "$result_digest"
    cat "$work/result.tsv"
    cat "$work/provenance.tsv"
    printf 'builder|identity|%s\n' "$builder_identity"
    printf 'builder|basis|%s\n' "$builder_basis"
    # Written by the command that cannot check it, so that neither this file
    # nor anything reading it can mistake the claim above for a finding.
    printf 'builder|independence|claimed by the builder and not established by this report or its validator\n'
    printf 'audit|generated_at|%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'audit|working_directory|%s\n' "$repo_root"
    printf 'audit|packet_directory|%s\n' "$output"
} >"$work/report.tsv"

rm -f "$report"
mkdir -p "$(dirname "$report")"
cp "$work/report.tsv" "$report"

printf 'PASS: %s declared inputs, sufficient alone, and the fixed point reproduced\n' \
    "$declared_count"
printf 'PASS: report written with result identity %s\n' "$result_digest"
printf 'note: this command records a builder identity and basis; it does not establish independence, and B6 is not closed by running it\n'
