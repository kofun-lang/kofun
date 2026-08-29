#!/bin/sh
# Does every program Stage 2 accepts emit C that compiles? (#1539)
#
# THE PROPERTY, stated here once so a future gate can cite it rather than
# restate it:
#
#     IF `bin/kofun build` DOES NOT REFUSE A PROGRAM WITH AN `error[...]`
#     DIAGNOSTIC, THEN THE C IT WROTE MUST COMPILE.
#
# Much weaker than "the compiler is correct" and entirely mechanical. A
# violation is a program the compiler said yes to and then handed to `cc`, which
# said no, and the author is shown a message about generated code at a byte
# offset in a file they did not write.
#
# WHY NOTHING ELSE CHECKS IT. Every gate that compiles emitted C does so over
# HAND-WRITTEN fixtures, so it covers what someone thought to write. The grammar
# fuzzer generates MALFORMED programs and never invokes a host C compiler.
# `selfhost-generations` and `selfhost-fixed-point` compare the two halves'
# output, so a defect present in both is invisible to them by construction.
# `stage2-pair-coverage` measures untaken branches, and none of this class is an
# untaken branch: the emitter runs, takes its branch, and emits the wrong thing.
#
# WHAT IT REPORTS, and the distinction that is the point: "refused by name" and
# "the host compiler said no" are the same exit status today, and this separates
# them. Every tracked `*.kofun` lands in exactly one of three outcomes:
#
#     built            `bin/kofun build` exited 0
#     refused          it exited non-zero and named an `error[...]` code
#     neither          it exited non-zero with no code — the violation
#
# The third set is `tests/emission/exceptions.tsv`, which fails in BOTH
# directions: an unlisted violation is new drift, and a listed row that now
# builds or is refused is an improvement that was not recorded.
#
#   sh tests/emission/check.sh             check the corpus against the ledger
#   sh tests/emission/check.sh --count     print the current classification
#   sh tests/emission/check.sh --prove     demonstrate it can refuse
#
# WHAT IT DOES NOT COVER, stated because a partial check read as a total one is
# worse than none:
#   - ANY CLAIM ABOUT CORRECTNESS beyond "it compiles". A program that compiles
#     and computes the wrong answer is a different property with different
#     gates.
#   - THE GENERATED HALF. This pins what exists; it cannot find a violation in a
#     program nobody has written. #1539 owns that design question, and the
#     measurement here is its cost input: 1320 files, 249 seconds serially.
#   - Files whose owning driver is not the default C path. Eighteen native,
#     wasm and selfhost-A1 fixtures are recorded as `other-driver`, because
#     running this driver over them is the wrong invocation rather than a
#     defect. That judgement is per row and lives in the ledger's reason column.
#
# NOT IN `task verify`, deliberately: 249 seconds on an 8-core x86-64 Linux box
# against a suite that runs in about seventeen minutes. Recorded with that
# reason in tooling/gate-reachability/unreachable.tsv.
set -u

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)

LEDGER=${KOFUN_EMISSION_LEDGER:-"$ROOT/tests/emission/exceptions.tsv"}
BUILD=${KOFUN_EMISSION_BUILD:-"$ROOT/bin/kofun build"}
# The corpus is a file of paths, so `--prove` can run three of them instead of
# 1320. It ANNOUNCES itself: a gate quietly checking a corpus of one would report
# a green that means nothing.
CORPUS=${KOFUN_EMISSION_CORPUS:-}

if test -n "$CORPUS"; then
    printf 'NOTE: emission: reading the corpus from %s, not the tracked tree.\n' \
        "$CORPUS" >&2
fi
if test "$LEDGER" != "$ROOT/tests/emission/exceptions.tsv"; then
    printf 'NOTE: emission: reading %s, not the committed ledger.\n' "$LEDGER" >&2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-emission.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

if test "${1:-}" = "--prove"; then
    PROVE=${2:-"$WORK/proof"}
    mkdir -p "$PROVE"
    proved=0
    behaved=0

    # Two real tracked files, so the proof exercises the actual classifier
    # rather than a transcription of it: one the default driver builds, and one
    # it accepts and then hands to cc, which refuses it (#1628).
    builds=tests/conformance/functions/branch_join.kofun
    violates=tests/conformance/inference/hm-levels/recursion.kofun
    printf '%s\n%s\n' "$builds" "$violates" >"$PROVE/corpus.txt"
    printf '%s\n' "$builds" >"$PROVE/corpus-clean.txt"
    : >"$PROVE/corpus-empty.txt"

    tab=$(printf '\t')
    printf '%s%semission-defect%s#1628, proof fixture\n' \
        "$violates" "$tab" "$tab" >"$PROVE/ledger-matching.tsv"
    printf '# path%skind%sreason\n' "$tab" "$tab" >"$PROVE/ledger-empty.tsv"
    printf '%s%semission-defect%s#1628, proof fixture\n' \
        "$builds" "$tab" "$tab" >"$PROVE/ledger-stale.tsv"
    printf 'tests/does/not/exist.kofun%semission-defect%sproof fixture\n' \
        "$tab" "$tab" >"$PROVE/ledger-absent.tsv"
    printf '%s%sinvented-kind%sproof fixture\n' \
        "$violates" "$tab" "$tab" >"$PROVE/ledger-badkind.tsv"
    printf '%s%semission-defect%s\n' \
        "$violates" "$tab" "$tab" >"$PROVE/ledger-noreason.tsv"
    printf '%s%semission-defect\n' "$violates" "$tab" >"$PROVE/ledger-short.tsv"

    # The must-not-fire case is FIRST and is not decoration: a version of this
    # gate that refused everything would satisfy every refusal below and be
    # useless. A rule with a false-positive shape has two properties and testing
    # only the one it is named for leaves the other unproved.
    proved=$((proved + 1))
    if env "KOFUN_EMISSION_CORPUS=$PROVE/corpus.txt" \
           "KOFUN_EMISSION_LEDGER=$PROVE/ledger-matching.tsv" \
           sh "$0" >"$PROVE/clean.out" 2>&1
    then
        behaved=$((behaved + 1))
        printf 'PASS [emission-accepts] corpus-matching-ledger, as it must\n'
    else
        printf 'FAIL: prove corpus-matching-ledger: refused a corpus its ledger covers:\n' >&2
        sed 's/^/      /' "$PROVE/clean.out" >&2
    fi

    prove() {
        case_name=$1
        case_needle=$2
        shift 2
        proved=$((proved + 1))
        if env "$@" sh "$0" >"$PROVE/$case_name.out" 2>&1; then
            printf 'FAIL: prove %s: accepted when it must refuse\n' "$case_name" >&2
            return
        fi
        if grep -qF "$case_needle" "$PROVE/$case_name.out"; then
            behaved=$((behaved + 1))
            printf 'PASS [emission-refuses] %s\n' "$case_name"
            return
        fi
        printf 'FAIL: prove %s: refused, but never named it — expected %s\n' \
            "$case_name" "$case_needle" >&2
        sed 's/^/      /' "$PROVE/$case_name.out" >&2
    }

    # The two directions this ledger fails in, which is the whole contract.
    prove unlisted-violation 'no ledger row records it' \
        "KOFUN_EMISSION_CORPUS=$PROVE/corpus.txt" \
        "KOFUN_EMISSION_LEDGER=$PROVE/ledger-empty.tsv"
    prove stale-row 'now builds or is refused by name' \
        "KOFUN_EMISSION_CORPUS=$PROVE/corpus-clean.txt" \
        "KOFUN_EMISSION_LEDGER=$PROVE/ledger-stale.tsv"

    # A ledger that could look official and cover nothing.
    prove absent-path 'names a path the corpus does not carry' \
        "KOFUN_EMISSION_CORPUS=$PROVE/corpus.txt" \
        "KOFUN_EMISSION_LEDGER=$PROVE/ledger-absent.tsv"
    prove invented-kind 'which is not one of' \
        "KOFUN_EMISSION_CORPUS=$PROVE/corpus.txt" \
        "KOFUN_EMISSION_LEDGER=$PROVE/ledger-badkind.tsv"
    prove unreasoned-row 'an unreasoned exemption is indistinguishable from drift' \
        "KOFUN_EMISSION_CORPUS=$PROVE/corpus.txt" \
        "KOFUN_EMISSION_LEDGER=$PROVE/ledger-noreason.tsv"
    prove malformed-row 'expected 3' \
        "KOFUN_EMISSION_CORPUS=$PROVE/corpus.txt" \
        "KOFUN_EMISSION_LEDGER=$PROVE/ledger-short.tsv"

    # And the denominator: a gate that reached nothing must not read as green.
    prove empty-corpus 'the corpus is empty' \
        "KOFUN_EMISSION_CORPUS=$PROVE/corpus-empty.txt" \
        "KOFUN_EMISSION_LEDGER=$PROVE/ledger-matching.tsv"

    printf '%s of %s cases behaved as required\n' "$behaved" "$proved"
    test "$behaved" -eq "$proved" || exit 1
    exit 0
fi

mode=${1:-check}
failures=0
refuse() {
    printf 'FAIL: emission: %s\n' "$1" >&2
    failures=$((failures + 1))
}

if test -n "$CORPUS"; then
    grep -v '^#' "$CORPUS" 2>/dev/null | grep . | sort >"$WORK/corpus.txt"
else
    ( cd "$ROOT" && git ls-files '*.kofun' ) | sort >"$WORK/corpus.txt"
fi

# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` would append a
# second line and make the comparison below fail with "integer expected".
corpus_size=$(grep -c . "$WORK/corpus.txt" 2>/dev/null || true)
: "${corpus_size:=0}"
# An empty corpus and a corpus the reader could not build look identical from
# here, and a gate that passes because it reached nothing is the failure this
# whole family exists to remove.
if test "$corpus_size" -eq 0; then
    printf 'FAIL: emission: the corpus is empty. A gate that checked nothing\n' >&2
    printf '      and a gate that found nothing are the same picture from here.\n' >&2
    exit 1
fi

if ! test -s "$LEDGER"; then
    printf 'FAIL: emission: %s is missing or empty\n' "$LEDGER" >&2
    exit 1
fi

# The ledger, as `path<TAB>kind<TAB>reason`. A row is refused for its own shape
# before any program is built, so a malformed ledger never reads as a clean run.
: >"$WORK/listed.txt"
while IFS= read -r ledger_line
do
    case "$ledger_line" in ''|'#'*) continue ;; esac
    ledger_fields=$(printf '%s\n' "$ledger_line" | awk -F'\t' '{ print NF }')
    ledger_path=$(printf '%s\n' "$ledger_line" | cut -f1)
    ledger_kind=$(printf '%s\n' "$ledger_line" | cut -f2)
    ledger_reason=$(printf '%s\n' "$ledger_line" | cut -f3)
    if test "$ledger_fields" -ne 3; then
        refuse "ledger row '$ledger_path' has $ledger_fields tab-separated field(s), expected 3"
        continue
    fi
    case "$ledger_kind" in
        other-driver|seed-include-path|emission-defect) ;;
        *) refuse "ledger row '$ledger_path' has kind '$ledger_kind', which is not one of other-driver, seed-include-path, emission-defect" ; continue ;;
    esac
    if test -z "$ledger_reason"; then
        refuse "ledger row '$ledger_path' carries no reason; an unreasoned exemption is indistinguishable from drift"
        continue
    fi
    if ! grep -qxF "$ledger_path" "$WORK/corpus.txt"; then
        refuse "ledger row '$ledger_path' names a path the corpus does not carry"
        continue
    fi
    printf '%s\n' "$ledger_path" >>"$WORK/listed.txt"
done <"$LEDGER"
sort -o "$WORK/listed.txt" "$WORK/listed.txt"

built=0
refused=0
: >"$WORK/violations.txt"
while IFS= read -r source
do
    test -n "$source" || continue
    if (cd "$ROOT" && $BUILD "$source" -o "$WORK/out.bin") \
        >"$WORK/stdout" 2>"$WORK/stderr"
    then
        built=$((built + 1))
        continue
    fi
    if grep -q 'error\[' "$WORK/stdout" "$WORK/stderr" 2>/dev/null; then
        refused=$((refused + 1))
        continue
    fi
    printf '%s\n' "$source" >>"$WORK/violations.txt"
    if test "$mode" = "--count"; then
        printf '%s\t%s\n' "$source" \
            "$(grep -m1 -oE 'fatal error: [^:]*|error: [^[]*' "$WORK/stderr" | cut -c1-70)"
    fi
done <"$WORK/corpus.txt"
sort -o "$WORK/violations.txt" "$WORK/violations.txt"

violations=$(grep -c . "$WORK/violations.txt" 2>/dev/null || true)
: "${violations:=0}"

# Both directions, the way tests/backlog/debt.tsv and
# tests/assertions/budget.tsv fail: an unlisted violation is new drift, and a
# listed row that no longer violates is an improvement that was not recorded.
comm -23 "$WORK/violations.txt" "$WORK/listed.txt" >"$WORK/unlisted.txt"
comm -13 "$WORK/violations.txt" "$WORK/listed.txt" >"$WORK/stale.txt"

while IFS= read -r unlisted
do
    test -n "$unlisted" || continue
    refuse "$unlisted is accepted by Stage 2 and its C does not compile, and no ledger row records it"
done <"$WORK/unlisted.txt"

while IFS= read -r stale
do
    test -n "$stale" || continue
    refuse "$stale is recorded in the ledger and now builds or is refused by name. Remove the row: an improvement that is not recorded is the direction this ledger also fails in."
done <"$WORK/stale.txt"

if test "$mode" = "--count"; then
    printf '# %s tracked program(s): %s built, %s refused by name, %s neither\n' \
        "$corpus_size" "$built" "$refused" "$violations"
fi

if test "$failures" -eq 0; then
    printf 'PASS: %s of %s tracked program(s) build or are refused by name; %s recorded in %s\n' \
        "$((built + refused))" "$corpus_size" "$violations" \
        "${LEDGER#"$ROOT"/}"
    exit 0
fi
printf '\n%s emission finding(s). Print the current classification with: sh %s --count\n' \
    "$failures" "tests/emission/check.sh" >&2
exit 1
