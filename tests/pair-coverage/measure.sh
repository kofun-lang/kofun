#!/bin/sh
# Which branches of bootstrap/stage2/compiler.c does nothing this repository
# runs ever take? (#1408, parent #1401)
#
# WHY THE SET IS WORTH MEASURING. `compiler.kofun` and its hand-maintained
# `compiler.c` transliteration are compared only through emitted C, by
# `selfhost-generations` and `selfhost-fixed-point`. A divergence on a branch
# something takes changes that C and is caught. A divergence on a branch nothing
# takes is invisible. #1315's leak lived in `lower_body`, still the largest
# untaken region in the file.
#
# UNTAKEN DOES NOT MEAN DIVERGENT. It means undefended. The ledger records the
# size of the hiding place, not any defect.
#
#   sh tests/pair-coverage/measure.sh WORK_DIR    print `untaken<TAB>function` rows
#
# THE BASIS IS THE UNION of the verify drivers and the pinned corpus, per
# #1408's `amendment:v1`. Measured on one commit: the corpus alone reports 2,762
# untaken branches, the drivers alone 1,854, the union 1,804. A corpus-only
# ledger therefore names 958 branches as undefended that the suite demonstrably
# reaches -- concentrated in `sl_emit_expr`, `sh_parse_stmt` and
# `emit_selfhost_hir_document`, which run only when the generation chain
# compiles `compiler.kofun` and which no single-file invocation can reach. The
# drivers alone still misname 50. Build cost does not pick which branches we
# tell the truth about.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
WORK=${1:?usage: measure.sh WORK_DIR}

# The compiler for the INSTRUMENTED build only, never exported as `CC`.
#
# Using `CC` was wrong and the diverse pair is what exposed it: every gate
# builds its own emitted C with `${CC:-cc}`, so `CC=clang sh measure.sh` made
# 45 of 139 drivers compile generated code with clang, which refuses it
# (`if (((depth) == (INT64_C(0))))` -> "use '=' to turn this equality comparison
# into an assignment", 2 errors). The gates must keep their normal compiler; only
# this translation unit changes.
COVERAGE_CC=${KOFUN_PAIR_COVERAGE_CC:-cc}
HERE="$ROOT/tests/pair-coverage"
DRIVERS="$HERE/drivers.tsv"
INPUTS="$HERE/inputs.tsv"

# -O0 because gcov's attribution under optimisation is not trustworthy. -w
# because this build proves nothing about warnings.
COVERAGE_FLAGS="-std=c11 -O0 --coverage -w"
INPUT_TIMEOUT=${KOFUN_PAIR_COVERAGE_TIMEOUT:-600}

SOURCE=${KOFUN_PAIR_COVERAGE_SOURCE:-$ROOT/bootstrap/stage2/compiler.c}
if test "$SOURCE" != "$ROOT/bootstrap/stage2/compiler.c"; then
    echo "NOTE: measuring $SOURCE, not the tree's compiler.c" >&2
fi

mkdir -p "$WORK"
strip_comments() { grep -v '^#' "$1" | grep -v '^[[:space:]]*$' | sort; }

# ---------------------------------------------------------------------------
# Both lists are COMMITTED and checked against the tree in both directions.
#
# Deriving them at run time would satisfy the intent of "named, not discovered"
# while violating its letter, and the letter is what stops a basis drifting
# under a ledger that still claims to describe it. An artifact that says it
# describes the tree must fail when the tree moves out from under it.
# ---------------------------------------------------------------------------
test -f "$DRIVERS" || { echo "measure.sh: missing $DRIVERS" >&2; exit 1; }
test -f "$INPUTS"  || { echo "measure.sh: missing $INPUTS" >&2; exit 1; }

# The verify task list, as Taskfile.yml states it. `roadmap` is run by
# verify-runner.sh after the parallel lane, so it is part of what verify
# executes even though it is not in that list.
awk '/^  verify:/{f=1}
     f&&/^      - cmd: \|-/{c=1;next}
     c&&/^ {10}/{print}
     c&&!/^ {10}/&&!/^[[:space:]]*$/{exit}' "$ROOT/Taskfile.yml" |
    sed 's/\\$//' | tr -s ' \n' ' ' |
    sed 's/sh "[^"]*" "[^"]*" "[^"]*" //' | tr ' ' '\n' |
    grep -vE '^$|verify-runner|PWD|VERIFY_JOBS' >"$WORK/verify-tasks.txt"
echo roadmap >>"$WORK/verify-tasks.txt"
sort -u "$WORK/verify-tasks.txt" -o "$WORK/verify-tasks.txt"

strip_comments "$DRIVERS" >"$WORK/pinned-drivers.txt"
undriven=$(comm -13 "$WORK/pinned-drivers.txt" "$WORK/verify-tasks.txt")
stale=$(comm -23 "$WORK/pinned-drivers.txt" "$WORK/verify-tasks.txt")
if test -n "$undriven"; then
    echo "measure.sh: verify runs these tasks and drivers.tsv does not pin them:" >&2
    printf '%s\n' "$undriven" | sed 's/^/  /' >&2
    echo "  An undriven gate makes the ledger grow for a reason unrelated to the" >&2
    echo "  compiler. Regenerate drivers.tsv." >&2
    exit 1
fi
if test -n "$stale"; then
    echo "measure.sh: drivers.tsv pins these and verify no longer runs them:" >&2
    printf '%s\n' "$stale" | sed 's/^/  /' >&2
    exit 1
fi

strip_comments "$INPUTS" >"$WORK/pinned-inputs.txt"
( cd "$ROOT" && git ls-files '*.kofun' ) | sort >"$WORK/tree-inputs.txt"
unpinned=$(comm -13 "$WORK/pinned-inputs.txt" "$WORK/tree-inputs.txt")
missing=$(comm -23 "$WORK/pinned-inputs.txt" "$WORK/tree-inputs.txt")
if test -n "$unpinned"; then
    echo "measure.sh: these *.kofun are in the tree and not pinned:" >&2
    printf '%s\n' "$unpinned" | sed 's/^/  /' >&2
    echo "  #1409's regression fixture landed exactly this way while this harness" >&2
    echo "  was being written. Regenerate inputs.tsv." >&2
    exit 1
fi
if test -n "$missing"; then
    echo "measure.sh: pinned inputs are not in the tree:" >&2
    printf '%s\n' "$missing" | sed 's/^/  /' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
echo "building instrumented compiler.c with: $COVERAGE_CC $COVERAGE_FLAGS" >&2
# shellcheck disable=SC2086
"$COVERAGE_CC" $COVERAGE_FLAGS "$SOURCE" -o "$WORK/stage2-cov" 2>"$WORK/build.stderr" || {
    echo "measure.sh: instrumented build failed:" >&2
    cat "$WORK/build.stderr" >&2
    exit 1
}

# Half one: the gates, injected through the hook `bootstrap/stage2/build.sh`
# already honours, so no gate script is modified. SEQUENTIAL because concurrent
# gcda writers corrupt the merge, and a corrupt profile understates coverage --
# which here invents undefended branches.
KOFUN_STAGE2_COMPILER="$WORK/stage2-cov"
export KOFUN_STAGE2_COMPILER
phase_start=$(date +%s)
: >"$WORK/driver-results.tsv"
while IFS= read -r driver; do
    test -n "$driver" || continue
    # `</dev/null` is load-bearing: a gate that reads standard input otherwise
    # consumes the rest of THIS loop's input and the loop ends early, exiting 0.
    # `cli-framework` did exactly that, silently running 76 of 138 drivers.
    if ( cd "$ROOT" && task "$driver" ) >"$WORK/log.$driver" 2>&1 </dev/null
    then
        printf '%s\tok\n' "$driver" >>"$WORK/driver-results.tsv"
    else
        printf '%s\texit=%s\n' "$driver" "$?" >>"$WORK/driver-results.tsv"
    fi
done <"$WORK/pinned-drivers.txt"
declared=$(grep -c . "$WORK/pinned-drivers.txt")
attempted=$(grep -c . "$WORK/driver-results.tsv")
test "$declared" -eq "$attempted" || {
    echo "measure.sh: $((declared - attempted)) driver(s) never ran." >&2
    echo "  Refusing to report a basis smaller than the one the ledger names." >&2
    exit 1
}

echo "drivers took $(( $(date +%s) - phase_start ))s" >&2
phase_start=$(date +%s)

# Half two: the pinned corpus, both output modes. A second argument ending in
# `.c` lowers to C; ending in `.kofun` is the identity projection. They reach
# different halves of the file -- #1409 lived in the half `hm-levels` never
# drove, which is why coverage of an input is not coverage of a path through it.
timedout=0
: >"$WORK/timeouts.txt"
while IFS= read -r input; do
    test -n "$input" || continue
    for suffix in kofun c; do
        timeout "$INPUT_TIMEOUT" "$WORK/stage2-cov" "$ROOT/$input" \
            "$WORK/out.$suffix" "$WORK/out.ir" "$WORK/out.tokens" \
            >/dev/null 2>&1 || {
            status=$?
            if test "$status" -eq 124; then
                timedout=$((timedout + 1))
                printf '%s\t%s\n' "$input" "$suffix" >>"$WORK/timeouts.txt"
            fi
        }
    done
done <"$WORK/pinned-inputs.txt"
echo "corpus took $(( $(date +%s) - phase_start ))s" >&2
test "$timedout" -eq 0 || {
    echo "measure.sh: $timedout invocation(s) exceeded ${INPUT_TIMEOUT}s:" >&2
    cat "$WORK/timeouts.txt" >&2
    echo "  An input that did not finish leaves its branches untaken, so the set" >&2
    echo "  below would be OVERSTATED. Refusing to report it." >&2
    exit 1
}

# gcov writes into the current directory and names output after the source, so
# a mutated copy yields `compiler.mutated.c.gcov`.
# clang's --coverage writes LLVM-format notes and data; GNU gcov reads neither
# and says so obliquely -- "no functions found", "version 'B11*', prefer
# 'B61*'", then "No executable lines", which reads like a coverage result rather
# than a wrong tool. `llvm-cov gcov` is the reader for that format.
case $(basename "$COVERAGE_CC") in
    clang*) GCOV_TOOL="llvm-cov gcov" ;;
    *)      GCOV_TOOL="gcov" ;;
esac
command -v "${GCOV_TOOL%% *}" >/dev/null 2>&1 || {
    echo "measure.sh: ${GCOV_TOOL%% *} is required to read $COVERAGE_CC coverage" >&2
    exit 1
}
# The coverage data records the source path as the compiler saw it, and clang
# relativises it against the compile directory: `Source:bootstrap/stage2/
# compiler.c`. Run from $WORK that does not resolve, and llvm-cov emits a
# four-line stub with no records -- which parses to "0 untaken branches", i.e.
# perfect coverage. Symlinking the top-level directories into $WORK makes the
# recorded relative path resolve while keeping the .gcov output out of the tree.
for top in bootstrap unicode vendor; do
    test -e "$ROOT/$top" && ln -sfn "$ROOT/$top" "$WORK/$top"
done
# shellcheck disable=SC2086
( cd "$WORK" && $GCOV_TOOL -b -f -o "$WORK/stage2-cov-compiler" "$SOURCE" ) \
    >"$WORK/gcov.stdout" 2>&1 || true
GCOV_OUT="$WORK/$(basename "$SOURCE").gcov"
test -f "$GCOV_OUT" || {
    echo "measure.sh: gcov produced no $(basename "$GCOV_OUT")" >&2
    tail -5 "$WORK/gcov.stdout" >&2
    exit 1
}

# An empty or unreconciled parse must FAIL, not report zero. A gcov file with no
# records parses to "0 untaken branches", which reads as perfect coverage and is
# the most dangerous possible wrong answer here. Reconcile against the tool's own
# summary before believing the rows.
records=$(grep -c '^function ' "$GCOV_OUT" || true)
test "$records" -gt 0 || {
    echo "measure.sh: $GCOV_OUT has no function records." >&2
    echo "  The coverage reader produced a file but no data -- that is a broken" >&2
    echo "  measurement, not a compiler with no undefended branches." >&2
    head -4 "$GCOV_OUT" >&2
    exit 1
}
derived=$(awk '/^branch /{ if ($0 ~ /never executed/ || $0 ~ /taken 0%/) n++ } END { print n+0 }' "$GCOV_OUT")
# The summary must be the one for THIS FILE. With `-f`, gcov prints a block per
# function before the file-level block, so an unanchored `/Taken at least once/`
# matches the first function -- "90.00% of 30", implying 3 untaken against a
# derived 1804, and the guard refuses a correct measurement. Anchor on the
# `File '...'` line for the source actually being measured.
reported=$(awk -v want="$(basename "$SOURCE")" '
    $0 ~ ("File .*" want "\047") { infile = 1; next }
    infile && /Taken at least once:/ {
        pct = $0; sub(/.*:/, "", pct); sub(/%.*/, "", pct)
        tot = $0; sub(/.*of /, "", tot)
        printf "%d", tot - (tot * pct / 100) + 0.5
        exit
    }' "$WORK/gcov.stdout")
if test -n "$reported" && test "$reported" -gt 0; then
    delta=$((derived > reported ? derived - reported : reported - derived))
    test "$delta" -le 2 || {
        echo "measure.sh: parsed $derived untaken branches, the tool's own summary" >&2
        echo "  implies about $reported. A derived number that does not reconcile" >&2
        echo "  with its instrument is wrong until it does." >&2
        exit 1
    }
fi

# Exact branch records, not gcov's rounded percentages.
awk '
/^function / { name = $2; next }
/^branch /   {
    if (name == "") next
    if ($0 ~ /never executed/ || $0 ~ /taken 0%/) untaken[name]++
    seen[name] = 1
}
END { for (f in seen) if (untaken[f] > 0) printf "%d\t%s\n", untaken[f], f }
' "$GCOV_OUT" | sort -k2,2
