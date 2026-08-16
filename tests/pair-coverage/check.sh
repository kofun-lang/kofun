#!/bin/sh
# The Stage 2 pair's undefended-branch ledger, held exact in both directions and
# under both host compilers. (#1408, parent #1401)
#
# `undefended.tsv` records, per function of `bootstrap/stage2/compiler.c`, how
# many of its branches nothing this repository runs ever takes -- once under
# each compiler of the diverse pair. That set is where a divergence between
# `compiler.kofun` and its hand-maintained `compiler.c` transliteration can
# hide: a divergence on a taken branch changes emitted C, and
# `selfhost-generations` and `selfhost-fixed-point` compare that. #1315's leak
# lived in `lower_body`, still the largest untaken region in the file.
#
# THE LEDGER RECORDS A HIDING PLACE, NOT A DEFECT. A listed function is not
# wrong; it is unwatched.
#
# AND IT IS NOT THE ONLY HIDING PLACE. The sentence above says a divergence on a
# taken branch changes emitted C and is caught. That is true of the C half. It
# overstates what happens to the Kofun half, and the difference was measured by
# the session working #1315, who found it the right way -- a byte count that did
# not move after adding ~480 lines to what they believed was the input.
#
# `bootstrap/manifest.json` names the fixed-point chain's inputs:
#
#     canonical_source  bootstrap/stage1/compiler.kofun
#     trusted_seed      bootstrap/stage2/compiler.c
#
# `bootstrap/stage2/compiler.kofun` is neither. Checked here rather than taken
# on trust: it IS processed -- `bootstrap/stage2/check.sh:592` round-trips it
# through `kofun-stage2`, byte-compares the identity projection against the
# source, and produces an IR -- but that IR is only asserted NON-EMPTY and to
# carry a version header. Its contents are compared to nothing, and nothing
# compiles it to C or runs the result.
#
# So the Kofun half is checked for syntax and for structure -- matching function
# names and counts, asserted string literals, the per-name dispatch minimums in
# `list-int-signatures`, `optional-pair` and `sha256-pair`. A logic error that
# preserved all of those would be invisible to every gate in this repository,
# whether or not the corresponding C branch is ever taken.
#
# THIS LEDGER DOES NOT MEASURE THAT LARGER SET, and saying so is the point: a
# ledger that implied it covered the whole risk would be worse than one that
# names its own edge.
#
# TWO COMPILERS, because one column cannot distinguish "undefended" from
# "undefended under gcc", and telling those apart is the whole point of keeping
# a diverse pair. A branch one compiler folds and the other keeps is exactly the
# kind of thing a single-column ledger would report as settled.
#
# Exact in both directions, per the `tests/assertions/budget.tsv` idiom:
#
#   more untaken than recorded   a branch stopped being reached -- regression
#   fewer untaken than recorded  an improvement nobody wrote down, which leaves
#                                slack for the next regression to hide in
#   recorded, now absent         the function is gone or fully covered
#   present, not recorded        new undefended surface with no entry
#
#   sh tests/pair-coverage/check.sh           check the ledger
#   sh tests/pair-coverage/check.sh --count   print current rows, to regenerate
#
# Regeneration is deliberately manual: the number moving is the event this file
# exists to make visible.
#
# THIS HARNESS IS SHELL, AND THAT IS RECORDED DEBT, NOT A CHOICE THAT WAS MADE
# HERE. RFC-0018 is accepted: Kofun is a self-contained native toolchain, and
# the maintainer's direction is that everything around the compiler becomes
# Kofun -- these three scripts included, not only the CLI and the package
# manager. The debt is written down rather than implied: this file, measure.sh
# and prove.sh each carry a `shell-build-driver` row in
# tooling/forbidden-requirements/census.tsv, and measure.sh carries `cc` and
# `go-task` rows besides. That census re-derives every row from the tree and
# fails in both directions, so this cannot quietly stop being true.
#
# What a Kofun rewrite has to be able to do, recorded so whoever picks it up
# inherits the requirements and not just the row: spawn on the order of 1,400
# child processes and collect their exit status; read the coverage tool's own
# output format for two different tool families; and hold a per-function table
# over a file with several hundred entries. #1451 owns that work.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
# The ledger, overridable only so `prove.sh` can hand this gate a deliberately
# broken one. It ANNOUNCES itself for the same reason the measurement seam does:
# a gate silently reading a ledger other than the committed one would report on
# a file nobody is looking at.
LEDGER=${KOFUN_PAIR_COVERAGE_LEDGER:-$ROOT/tests/pair-coverage/undefended.tsv}
if test "$LEDGER" != "$ROOT/tests/pair-coverage/undefended.tsv"; then
    printf 'NOTE: pair coverage: checking %s, not the committed ledger.\n' \
        "$LEDGER" >&2
fi
MEASURE="$ROOT/tests/pair-coverage/measure.sh"

# The diverse pair, defaulting to the same two
# `bootstrap/selfhost/check-diverse-double-compilation.sh` uses, so the ledger's
# columns mean what that gate's columns mean.
CC_A=${KOFUN_DDC_CC_A:-gcc}
CC_B=${KOFUN_DDC_CC_B:-clang}

TMP_PARENT="$ROOT/build/tmp"
mkdir -p "$TMP_PARENT"
WORK=$(mktemp -d "$TMP_PARENT/pair-coverage.XXXXXX")
# Clean up only on SUCCESS. A measuring run costs the better part of an hour,
# and deleting it on failure destroys the evidence needed to tell a broken
# harness from a changed compiler -- which is exactly the case that occurred:
# a guard misread gcov's per-function summary as the file's, refused a correct
# measurement, and took 40 minutes of coverage data with it.
cleanup() { test "${KEEP_WORK:-0}" = 1 || rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM
fail_keeping_work() {
    KEEP_WORK=1
    printf 'FAIL: pair coverage: %s\n' "$1" >&2
    printf '      Work kept for diagnosis: %s\n' "$WORK" >&2
    exit 1
}

# Two measuring runs cost the better part of an hour, and `prove.sh` needs the
# comparison exercised many times, so this seam supplies a measurement instead
# of taking one. It ANNOUNCES ITSELF on every use: a seam that silently replaced
# the measurement would turn this gate into one that checks a file against
# itself.
if test -n "${KOFUN_PAIR_COVERAGE_MEASURED:-}"; then
    printf 'NOTE: pair coverage: using the supplied measurement %s;\n' \
        "$KOFUN_PAIR_COVERAGE_MEASURED" >&2
    printf '      nothing was measured from the tree on this run.\n' >&2
    cp "$KOFUN_PAIR_COVERAGE_MEASURED" "$WORK/measured.tsv"
else
    for compiler in "$CC_A" "$CC_B"; do
        command -v "$compiler" >/dev/null 2>&1 || {
            printf 'FAIL: pair coverage: %s is not on PATH.\n' "$compiler" >&2
            printf '      A one-compiler ledger cannot tell "undefended" from\n' >&2
            printf '      "undefended under %s", so this refuses rather than\n' "$CC_A" >&2
            printf '      measuring half of what it reports. Name another pair with\n' >&2
            printf '      KOFUN_DDC_CC_A and KOFUN_DDC_CC_B.\n' >&2
            exit 1
        }
    done
    for compiler in "$CC_A" "$CC_B"; do
        # KOFUN_PAIR_COVERAGE_CC, not CC: the gates must keep compiling their
        # own emitted C with the compiler they normally use. Exporting CC made
        # 45 of 139 drivers build generated code with clang, which refuses it.
        KOFUN_PAIR_COVERAGE_CC="$compiler" sh "$MEASURE" "$WORK/measure-$compiler" \
            >"$WORK/raw-$compiler.tsv" || {
            fail_keeping_work "the $compiler measurement did not complete; the
      untaken set is unknown rather than unchanged."
        }
    done
    # Full outer join on the function name. A function untaken under one
    # compiler and fully covered under the other must still appear, with a zero,
    # because "0 under clang" is a measurement and an absent row is not.
    awk -F '\t' '
        FNR == NR { a[$2] = $1; seen[$2] = 1; next }
                  { b[$2] = $1; seen[$2] = 1 }
        END {
            for (f in seen) printf "%d\t%d\t%s\n", (f in a ? a[f] : 0), (f in b ? b[f] : 0), f
        }
    ' "$WORK/raw-$CC_A.tsv" "$WORK/raw-$CC_B.tsv" | sort -k3,3 >"$WORK/measured.tsv"
fi

if test "${1:-}" = "--count"; then
    cat "$WORK/measured.tsv"
    exit 0
fi

test -s "$LEDGER" || {
    printf 'FAIL: pair coverage: %s is missing or empty\n' "$LEDGER" >&2
    exit 1
}

grep -v '^#' "$LEDGER" | grep -v '^[[:space:]]*$' | sort -k3,3 >"$WORK/ledger.tsv"

# A ROW THAT IS NOT THREE TAB-SEPARATED FIELDS IS CORRUPTION, AND SILENCE ABOUT
# IT IS WORSE THAN THE CORRUPTION. The comparison below skips any row whose
# function name is empty, so a malformed line was ignored there and still
# counted in the PASS line's function total -- the gate reported 355 functions
# over a 354-row measurement and passed. That is the shape this whole harness
# exists to refuse: an output that is well formed, means nothing, and reads as
# success.
#
# It was not hypothetical. The generator that writes this header built one of
# its lines from `grep -c . file || echo 0`, which on an EMPTY file prints 0 AND
# exits 1, so the fallback fired too and the value spanned two lines. The second
# line landed in the ledger without its `#`.
malformed=$(awk -F '\t' 'NF != 3 || $3 == "" { print FNR ": " $0 }' "$WORK/ledger.tsv")
if test -n "$malformed"; then
    printf 'FAIL: pair coverage: %s is not a ledger of rows.\n' "$LEDGER" >&2
    printf '      Every row must be exactly three tab-separated fields,\n' >&2
    printf '      "%s<TAB>%s<TAB>function". These are not:\n' "$CC_A" "$CC_B" >&2
    printf '%s\n' "$malformed" | sed 's/^/        /' >&2
    printf '      A row the comparison cannot read is skipped by it and still\n' >&2
    printf '      counted in the totals, so this refuses rather than reporting a\n' >&2
    printf '      number over a file it did not fully understand.\n' >&2
    exit 1
fi

failures=0
report() {
    printf 'FAIL: pair coverage: %s\n' "$1" >&2
    failures=$((failures + 1))
}

while IFS='	' read -r rec_a rec_b fn; do
    test -n "$fn" || continue
    row=$(awk -F '\t' -v f="$fn" '$3 == f { print $1 "\t" $2 }' "$WORK/measured.tsv")
    if test -z "$row"; then
        report "$fn is in the ledger ($CC_A $rec_a, $CC_B $rec_b) and has no untaken
      branches now — it is gone or fully covered. Remove the row in the same
      change, with \`sh tests/pair-coverage/check.sh --count\`."
        continue
    fi
    got_a=$(printf '%s' "$row" | cut -f1)
    got_b=$(printf '%s' "$row" | cut -f2)
    for pair in "$CC_A:$rec_a:$got_a" "$CC_B:$rec_b:$got_b"; do
        who=${pair%%:*}; rest=${pair#*:}; want=${rest%%:*}; got=${rest#*:}
        if test "$got" -gt "$want"; then
            report "$fn has $got untaken branch(es) under $who, ledger says $want —
      $((got - want)) new undefended branch(es). Reach them with a fixture, or
      record the growth deliberately so the hiding place is not enlarged silently."
        elif test "$got" -lt "$want"; then
            report "$fn has $got untaken branch(es) under $who but the ledger still says
      $want — an improvement that was not recorded. Lower it in the same change,
      or the slack hides the next regression."
        fi
    done
done <"$WORK/ledger.tsv"

while IFS='	' read -r got_a got_b fn; do
    test -n "$fn" || continue
    if ! awk -F '\t' -v f="$fn" '$3 == f { found = 1 } END { exit !found }' \
        "$WORK/ledger.tsv"
    then
        report "$fn has untaken branches ($CC_A $got_a, $CC_B $got_b) and no ledger entry"
    fi
done <"$WORK/measured.tsv"

if test "$failures" -gt 0; then
    printf 'FAIL: pair coverage: %s discrepancy/ies between the ledger and the tree\n' \
        "$failures" >&2
    exit 1
fi

total_a=$(awk -F '\t' '{ s += $1 } END { print s + 0 }' "$WORK/ledger.tsv")
total_b=$(awk -F '\t' '{ s += $2 } END { print s + 0 }' "$WORK/ledger.tsv")
functions=$(grep -c . "$WORK/ledger.tsv")
printf 'PASS: the Stage 2 pair ledger is exact: %s untaken under %s, %s under %s, across %s function(s)\n' \
    "$total_a" "$CC_A" "$total_b" "$CC_B" "$functions"
