#!/bin/sh
set -eu

# The other half of the B6 packet: what a reviewer runs on a report someone
# sent them.
#
#     sh bootstrap/selfhost/check-reproduction-report.sh REPORT
#     sh bootstrap/selfhost/check-reproduction-report.sh REPORT --against-checkout
#
# Without `--against-checkout` this reads the report alone: schema, sections,
# every required field present exactly once, no unknown field, well-formed
# digests and counts, the criterion the report claims to have met, and the
# result identity recomputed from the rows it covers. That is what a reviewer
# can do with a report about a commit they do not have.
#
# With `--against-checkout` it additionally requires the report to be about
# *this* tree: the acquisition set is re-derived here and compared, and the
# closure digests are compared against `bootstrap/manifest.json`. A report of a
# different subject fails there rather than being read as agreement.
#
# ## What it cannot do
#
# It cannot tell you the builder was independent. `builder|identity` and
# `builder|basis` are required — a report without them is refused — and they
# are also just text the builder typed. Nothing in a file can authenticate its
# own author. This command says so in its output rather than leaving the
# absence of a statement to be read as one, because "the validator passed" is
# exactly the sentence someone would otherwise quote as if it meant more.
#
# Deciding whether a basis constitutes independence is a person's judgement,
# recorded elsewhere. B6 is not closed by this command passing.

fail() {
    printf '%s\n' "FAIL: selfhost reproduction report: $*" >&2
    exit 1
}

test "$#" -ge 1 && test "$#" -le 2 ||
    fail "usage: sh bootstrap/selfhost/check-reproduction-report.sh REPORT [--against-checkout]"
case "$1" in
    /*) report=$1 ;;
    *) report=$PWD/$1 ;;
esac
against_checkout=0
if test "$#" -eq 2; then
    test "$2" = '--against-checkout' ||
        fail "the only option is \`--against-checkout\`, not \`$2\`"
    against_checkout=1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

. "$repo_root/bootstrap/selfhost/generations-lib.sh"

test -s "$report" || fail "\`$report\` is missing or empty"

# A file that ends mid-row is truncated, and a truncated report whose last
# complete row happened to be a digest would otherwise read as a shorter but
# valid one.
test "$(tail -c 1 "$report" | wc -l | tr -d ' ')" -eq 1 ||
    fail "the report does not end with a newline; it is truncated"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-b6-report.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# Every row belongs to a known section. An unknown prefix is a field this
# validator does not understand, and a validator that skips what it does not
# understand cannot say what it checked.
awk -F '|' '
    $1 == "schema" || $1 == "result_sha256" || $1 == "result" ||
    $1 == "provenance" || $1 == "builder" || $1 == "audit" { next }
    { print NR ": " $0 }
' "$report" >"$work/unknown"
test ! -s "$work/unknown" || {
    printf '%s\n' "----- rows in no known section:" >&2
    cat "$work/unknown" >&2
    fail "the report carries rows this validator does not understand"
}

# Duplicate rows, by section and key. `recorded_value` refuses a duplicated
# key one at a time; this refuses the whole file at once so the message names
# every one.
awk -F '|' '
    $1 == "result" || $1 == "provenance" || $1 == "builder" || $1 == "audit" {
        seen[$1 "|" $2] += 1
        next
    }
    { seen[$1] += 1 }
    END { for (key in seen) if (seen[key] > 1) print key, seen[key] }
' "$report" | LC_ALL=C sort >"$work/duplicates"
test ! -s "$work/duplicates" || {
    printf '%s\n' "----- keys recorded more than once:" >&2
    cat "$work/duplicates" >&2
    fail "a report field is recorded more than once"
}

field() {
    awk -F '|' -v section="$1" -v key="$2" \
        '$1 == section && $2 == key { print substr($0, length(section) + length(key) + 3) }' \
        "$report"
}

require() {
    require_section=$1
    require_key=$2
    require_value=$(field "$require_section" "$require_key")
    test -n "$require_value" ||
        fail "\`$require_section|$require_key\` is missing or empty"
    printf '%s\n' "$require_value"
}

schema=$(awk -F '|' '$1 == "schema" { print $2 }' "$report")
test "$schema" = 'kofun.selfhost-b6-report/v1' ||
    fail "unknown report schema \`$schema\`"

# The required field set, exactly. Missing is a report that says less than it
# must; extra is a field nothing here checks, and an unchecked field in a
# report about reproducibility is where a wrong value lives.
result_keys='report_schema command criterion normalized_environment
declared_inputs_schema inputs_sufficient_schema fixed_point_schema
closure_schema acquisition_set_sha256 declared_inputs
canonical_source_sha256 trusted_seed_sha256 corpus_sha256
runtime_headers_sha256 c1_sha256 c2_sha256 c3_sha256 c3_bytes
fixed_point_closure_sha256 corpus_cases corpus_observations
corpus_observations_sha256'
provenance_keys='host_compiler_identity host_compiler_flags a1_sha256 a2_sha256
a3_sha256 operating_system kernel_release architecture libc digest_tool'
builder_keys='identity basis independence'

check_section() {
    section=$1
    expected=$2
    printf '%s\n' $expected | LC_ALL=C sort >"$work/expected"
    awk -F '|' -v s="$section" '$1 == s { print $2 }' "$report" |
        LC_ALL=C sort >"$work/present"
    if ! cmp -s "$work/expected" "$work/present"; then
        printf '%s\n' "----- $section keys, expected then present:" >&2
        diff "$work/expected" "$work/present" >&2 || true
        fail "the \`$section\` section does not carry exactly its required keys"
    fi
}

check_section result "$result_keys"
check_section provenance "$provenance_keys"
check_section builder "$builder_keys"

# `libc` is the one required field that is legitimately empty on a host with no
# `ldd`, so it is required to be present and allowed to be blank; everything
# else must say something.
for key in $result_keys; do
    value=$(field result "$key")
    test -n "$value" || fail "\`result|$key\` is present but empty"
done
for key in $provenance_keys; do
    test "$key" = libc && continue
    value=$(field provenance "$key")
    test -n "$value" || fail "\`provenance|$key\` is present but empty"
done

hexadecimal() {
    case "$2" in
        *[!0-9a-f]*|'') fail "\`$1\` is not a lowercase hexadecimal digest" ;;
    esac
    test "${#2}" -eq 64 || fail "\`$1\` is not 64 hexadecimal characters"
    # The digest of an empty stream. It is what a set digest returns when the
    # set was not read at all, it is stable across runs, and it therefore
    # compares equal to itself and looks like evidence. A real artifact never
    # has it, so a report carrying it is reporting that nothing was measured.
    test "$2" != 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ||
        fail "\`$1\` is the digest of an empty input; nothing was measured there"
}

positive() {
    case "$2" in
        *[!0-9]*|''|0) fail "\`$1\` is not a positive count" ;;
    esac
}

for key in acquisition_set_sha256 canonical_source_sha256 trusted_seed_sha256 \
    corpus_sha256 runtime_headers_sha256 c1_sha256 c2_sha256 c3_sha256 \
    fixed_point_closure_sha256 corpus_observations_sha256; do
    hexadecimal "result|$key" "$(field result "$key")"
done
for key in a1_sha256 a2_sha256 a3_sha256 digest_tool; do
    hexadecimal "provenance|$key" "$(field provenance "$key")"
done
for key in declared_inputs c3_bytes corpus_cases corpus_observations; do
    positive "result|$key" "$(field result "$key")"
done

# The semantic section carries no absolute path, no timestamp, and no host
# name. Those belong to `audit|`, where they cannot reach the identity below.
awk -F '|' '$1 == "result" || $1 == "builder" {
    value = substr($0, length($1) + length($2) + 3)
    if (value ~ /(^|[[:space:]=])\//) print $1 "|" $2 ": absolute path"
    if (value ~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) print $1 "|" $2 ": timestamp"
}' "$report" >"$work/leaks"
test ! -s "$work/leaks" || {
    printf '%s\n' "----- values that belong in the audit section:" >&2
    cat "$work/leaks" >&2
    fail "the semantic section leaks a path or a time"
}

# Schemas and the command are versioned strings, not free text.
test "$(field result report_schema)" = "$schema" ||
    fail "the report schema row disagrees with the result section"
test "$(field result command)" = 'sh bootstrap/selfhost/reproduce.sh OUTPUT REPORT' ||
    fail "the report was not produced by the declared command"
test "$(field result declared_inputs_schema)" = 'kofun.selfhost-declared-inputs/v1' ||
    fail "unknown declared-input schema"
test "$(field result inputs_sufficient_schema)" = 'kofun.selfhost-inputs-sufficient/v1' ||
    fail "unknown inputs-sufficient schema"
test "$(field result fixed_point_schema)" = 'kofun.selfhost-fixed-point/v1' ||
    fail "unknown fixed-point schema"
test "$(field result closure_schema)" = 'kofun.selfhost-fixed-point-closure/v1' ||
    fail "unknown closure schema"
test "$(field result normalized_environment)" = "$KOFUN_GENERATIONS_ENVIRONMENT" ||
    fail "the report was produced under a different normalized environment"
test "$(field result criterion)" = "$KOFUN_GENERATIONS_CRITERION" ||
    fail "the report states a different fixed-point criterion"

# The criterion the report claims to have met, read out of the report itself.
# A report whose own C2 and C3 differ is a report of a failed reproduction, and
# passing it because every field was well-formed is the exact shape of a bogus
# success.
test "$(field result c2_sha256)" = "$(field result c3_sha256)" ||
    fail "the report's own C2 and C3 differ: it does not record a fixed point"
test "$(field provenance a2_sha256)" = "$(field provenance a3_sha256)" ||
    fail "the report's own A2 and A3 differ: it does not record a fixed point"

# The result identity, recomputed over exactly the rows it covers.
grep '^result|' "$report" >"$work/result.tsv"
recomputed=$(digest_of "$work/result.tsv")
declared=$(awk -F '|' '$1 == "result_sha256" { print $2 }' "$report")
hexadecimal 'result_sha256' "$declared"
test "$declared" = "$recomputed" ||
    fail "result_sha256 is $declared but the result rows digest to $recomputed"

builder_identity=$(require builder identity)
builder_basis=$(require builder basis)
test "$(field builder independence)" = \
    'claimed by the builder and not established by this report or its validator' ||
    fail "the independence row does not carry the statement this validator can support"

if test "$against_checkout" -eq 1; then
    # Re-derive the acquisition set here and compare. This is the check that
    # separates "a well-formed report" from "a report about this tree", and it
    # is deliberately not run against the retained fixtures, whose subject is a
    # commit that has moved.
    subject="$work/subject"
    mkdir -p "$subject"
    sh bootstrap/selfhost/declare-inputs.sh "$subject" >"$work/declare.stdout" 2>&1 ||
        fail "the checkout's own acquisition set could not be derived"
    here_digest=$(digest_of "$subject/declared-inputs.tsv")
    here_count=$(grep -c '^input|' "$subject/declared-inputs.tsv")
    test "$(field result acquisition_set_sha256)" = "$here_digest" ||
        fail "the report is about acquisition set $(field result acquisition_set_sha256), and this checkout is $here_digest"
    test "$(field result declared_inputs)" = "$here_count" ||
        fail "the report declares $(field result declared_inputs) inputs and this checkout has $here_count"
    for pair in canonical_source_sha256 trusted_seed_sha256 corpus_sha256 \
        c1_sha256 c2_sha256 c3_sha256; do
        test "$(field result "$pair")" = "$(manifest_closure_value "$pair")" ||
            fail "report $pair differs from bootstrap/manifest.json's closure record"
    done
    printf 'PASS: the report is about this checkout: acquisition set, count, and closure digests agree\n'
fi

printf 'PASS: schema %s, every required field present exactly once, no unknown field\n' \
    "$schema"
printf 'PASS: %s declared inputs, %s corpus cases, %s retained observations\n' \
    "$(field result declared_inputs)" "$(field result corpus_cases)" \
    "$(field result corpus_observations)"
printf 'PASS: C2 == C3 and A2 == A3 as recorded, and result_sha256 recomputes\n'
printf 'PASS: the semantic section carries no path, time, or empty-input digest\n'
printf 'note: the builder is recorded as `%s`, on the basis `%s`\n' \
    "$builder_identity" "$builder_basis"
printf 'note: this validator cannot authenticate that claim, and does not assert that the builder is independent; B6 is not closed by this command passing\n'
