#!/usr/bin/env sh
# Standard library capability matrix gate.
#
# The matrix exists so that "the standard library covers X" is a checkable
# statement rather than a habit. Three things are checked, in the order in
# which their absence would mislead most:
#
#   1. every row has exactly one valid tier and state;
#   2. every state's evidence is the kind of evidence that state permits, and
#      that evidence resolves — a `task` target that exists, a file that
#      exists, or an issue reference; and
#   3. the checker still refuses each way (1) and (2) can be broken.
#
# (3) matters as much as the rest. A checker that quietly stopped enforcing a
# rule would keep reporting PASS on an honest matrix, so every rule is proved
# by a mutation that must fail.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd)
MATRIX=${KOFUN_STDLIB_MATRIX:-"$ROOT/stdlib/capabilities.tsv"}
TASKFILE="$ROOT/Taskfile.yml"
WORK=${KOFUN_STDLIB_MATRIX_WORK:-"$ROOT/build/stdlib-capabilities"}

if test "$#" -gt 0; then
    printf '%s\n' "capabilities: unexpected argument: $1" >&2
    exit 2
fi

fail() {
    printf '%s\n' "capabilities: $*" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

TIERS='prelude portable adapter module none'
STATES='implemented specified planned deferred non-goal'

# Validate one matrix file. Returns 0 when every row is well formed.
# Used both on the real matrix and on each deliberately broken mutation.
validate() {
    file=$1
    rows=0
    seen_jobs="$WORK/seen-jobs"
    : >"$seen_jobs"

    # Skip comments and the header row.
    while IFS='	' read -r job tier state evidence note; do
        case $job in ''|'#'*|job) continue ;; esac
        rows=$((rows + 1))

        test -n "$note" || return 1

        grep -Fxq "$job" "$seen_jobs" && return 1
        printf '%s\n' "$job" >>"$seen_jobs"

        printf '%s' "$TIERS" | tr ' ' '\n' | grep -Fxq "$tier" || return 1
        printf '%s' "$STATES" | tr ' ' '\n' | grep -Fxq "$state" || return 1

        case $state in
            implemented)
                # Evidence must be a task target that Taskfile.yml declares.
                case $evidence in
                    'task '*) ;;
                    *) return 1 ;;
                esac
                target=${evidence#task }
                grep -q "^  $target:" "$TASKFILE" || return 1
                ;;
            specified)
                # Evidence must be a spec or docs path that exists.
                case $evidence in
                    spec/*|docs/*) ;;
                    *) return 1 ;;
                esac
                test -f "$ROOT/$evidence" || return 1
                ;;
            planned|deferred)
                # Evidence must be one or more issue references.
                case $evidence in
                    '#'[0-9]*) ;;
                    *) return 1 ;;
                esac
                for ref in $evidence; do
                    case $ref in
                        '#'[0-9]*) ;;
                        *) return 1 ;;
                    esac
                done
                ;;
            non-goal)
                # A non-goal cites no artifact; the note carries the reason.
                test "$evidence" = charter || return 1
                ;;
        esac
    done <"$file"

    test "$rows" -ge 1 || return 1
    printf '%s\n' "$rows"
}

test -f "$MATRIX" || fail "matrix not found: $MATRIX"

row_count=$(validate "$MATRIX") ||
    fail "the committed matrix does not satisfy its own rules"
printf '%s\n' "PASS: $row_count capability rows carry a valid tier, state, and resolving evidence"

# Every job listed in the charter's coverage goal must appear. A capability
# that is simply missing from the matrix is the failure this list prevents,
# because an absent row looks exactly like an absent problem.
REQUIRED='
collections-sequence
collections-associative
syscall-file-round-trip
process-spawn
directory-listing
environment-authority
cli-parsing
http-server
http-client
date-time-core
clock-core
clock-adapters
time-zone-data
json
csv
toml
logging
unit-testing
benchmark-harness
concurrency
stream-protocol
buffered-io
url
hashes-checksums
compression-archive
crypto-tls
mime
temporary-files
secure-randomness
yaml
'
for job in $REQUIRED; do
    test -n "$job" || continue
    cut -f1 "$MATRIX" | grep -Fxq "$job" ||
        fail "the charter requires a row for '$job' and the matrix has none"
done
printf '%s\n' "PASS: every capability the charter names has a row"

# Negative self-tests. Each mutation breaks exactly one rule and must be
# refused; a checker that accepted any of them would still pass above.
validate_complete() {
    file=$1
    validate "$file" >/dev/null || return 1
    for job in $REQUIRED; do
        test -n "$job" || continue
        cut -f1 "$file" | grep -Fxq "$job" || return 1
    done
}

mutate() {
    name=$1
    shift
    out="$WORK/$name.tsv"
    cp "$MATRIX" "$out"
    "$@" "$out"
    if validate_complete "$out" >/dev/null 2>&1; then
        fail "mutation '$name' was accepted"
    fi
    printf '%s\n' "PASS [capabilities-negative] $name"
}

mutate unknown-state sed -i 's/\timplemented\ttask stdlib\t/\tshipped\ttask stdlib\t/'
mutate unknown-tier sed -i 's/\tportable\timplemented\t/\tstandard\timplemented\t/'
mutate implemented-without-task sed -i 's/\timplemented\ttask stdlib\t/\timplemented\tstdlib\/json\t/'
mutate implemented-unknown-task sed -i 's/\timplemented\ttask stdlib\t/\timplemented\ttask no-such-target\t/'
mutate missing-evidence sed -i 's/^syscall-file-round-trip\tadapter\timplemented\ttask stdlib\t/syscall-file-round-trip\tadapter\timplemented\t \t/'
mutate specified-missing-file sed -i 's|\tspecified\tspec/effects/validation-accumulation.md\t|\tspecified\tspec/effects/does-not-exist.md\t|'
mutate planned-without-issue sed -i 's/\tplanned\t#555 #736\t/\tplanned\tsoon\t/'
mutate non-goal-with-evidence sed -i 's/\tnon-goal\tcharter\t/\tnon-goal\ttask stdlib\t/'
mutate missing-note sed -i 's/\tTOML is the baseline config format.*$/\t/'

# A duplicate job id is how two rows can disagree about one capability.
duplicate() {
    grep -v '^#' "$1" | sed -n '2p' >>"$1"
}
mutate duplicate-job duplicate

# Row validity alone cannot detect an omitted capability, so exercise the
# charter coverage check through the same mutation boundary.
remove_required_row() {
    sed -i '/^process-spawn\t/d' "$1"
}
mutate missing-required-row remove_required_row

printf '%s\n' \
    'PASS: the capability matrix states are exact, and 11 mutations are refused'
