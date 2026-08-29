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
#   sh tests/pair-coverage/measure.sh --check-drivers [DRIVERS]
#                                                 check drivers.tsv alone, in
#                                                 milliseconds, without measuring
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

HERE="$ROOT/tests/pair-coverage"
DRIVERS="$HERE/drivers.tsv"
INPUTS="$HERE/inputs.tsv"
strip_comments() { grep -v '^#' "$1" | grep -v '^[[:space:]]*$' | sort; }

# The driver failure policy, defined before the dispatch below so that the rule
# a measuring run enforces and the rule the proof exercises are the SAME code.
# Transcribing it into a test would prove the transcription: this repository has
# already paid for that once, where a hand-written gate accepted a module the
# normative validator refused.
#
#   sh measure.sh --check-driver-failures RESULTS EXPECTED
#
# RESULTS is `driver<TAB>ok|exit=N`, EXPECTED is `driver<TAB>exit=N<TAB>reason`.
check_driver_failures() {
    cdf_results=$1
    cdf_expected=$2
    cdf_work=${3:-$(dirname -- "$cdf_results")}
    cdf_bad=0

    awk -F '\t' '$2 != "ok" { print $1 "\t" $2 }' "$cdf_results" | sort \
        >"$cdf_work/failed.txt"
    if test -f "$cdf_expected"; then
        grep -v '^#' "$cdf_expected" | grep -v '^[[:space:]]*$' | cut -f1,2 | sort \
            >"$cdf_work/failed-expected.txt"
    else
        : >"$cdf_work/failed-expected.txt"
    fi

    while IFS= read -r cdf_row; do
        test -n "$cdf_row" || continue
        if ! grep -qxF "$cdf_row" "$cdf_work/failed-expected.txt"; then
            if test "$cdf_bad" -eq 0; then
                echo "measure.sh: driver(s) failed and are not recorded in" >&2
                echo "  tests/pair-coverage/driver-failures.tsv:" >&2
            fi
            printf '    %s\n' "$cdf_row" >&2
            cdf_bad=$((cdf_bad + 1))
        fi
    done <"$cdf_work/failed.txt"

    while IFS= read -r cdf_row; do
        test -n "$cdf_row" || continue
        if ! grep -qxF "$cdf_row" "$cdf_work/failed.txt"; then
            echo "measure.sh: driver-failures.tsv records '$cdf_row', which now" >&2
            echo "  succeeds. Remove the row: a stale excuse hides the next failure." >&2
            cdf_bad=$((cdf_bad + 1))
        fi
    done <"$cdf_work/failed-expected.txt"

    test "$cdf_bad" -eq 0 || {
        echo "  A driver that failed contributes only the coverage it reached, so the" >&2
        echo "  untaken set would be larger than the tree warrants. Refusing to report" >&2
        echo "  a fabricated one. Re-run on a quiet machine, or record the failure with" >&2
        echo "  a reason someone checked." >&2
        return 1
    }
}

# Does drivers.tsv still pin exactly the tasks `verify` runs? Defined here, and
# reachable on its own below, for the reason check_driver_failures is: the rule a
# measuring run enforces and the rule anything else checks must be the SAME code.
#
# This one has a second reader because of what it costs to learn late. The basis
# is Taskfile.yml's verify list, which any issue may edit; the only thing that
# read it was a measurement that takes hours, so #1321 pinning a new `verify`
# task and not this file was discovered at the top of a 2.5-hour run. The
# comparison itself is milliseconds. Reaching it in milliseconds is #1596.
check_drivers() {
    cd_work=$1
    # The pinned list is an argument rather than an environment seam, for the
    # reason check_driver_failures takes its two files that way: a caller
    # checking something other than the tree's list has said so in the command,
    # so nothing can quietly check a file against itself.
    cd_drivers=${2:-$DRIVERS}

    # The verify task list, as Taskfile.yml states it. `roadmap` is run by
    # verify-runner.sh after the parallel lane, so it is part of what verify
    # executes even though it is not in that list.
    awk '/^  verify:/{f=1}
         f&&/^      - cmd: \|-/{c=1;next}
         c&&/^ {10}/{print}
         c&&!/^ {10}/&&!/^[[:space:]]*$/{exit}' "$ROOT/Taskfile.yml" |
        sed 's/\\$//' | tr -s ' \n' ' ' |
        sed 's/sh "[^"]*" "[^"]*" "[^"]*" //' | tr ' ' '\n' |
        grep -vE '^$|verify-runner|PWD|VERIFY_JOBS' >"$cd_work/verify-tasks.txt"
    echo roadmap >>"$cd_work/verify-tasks.txt"
    sort -u "$cd_work/verify-tasks.txt" -o "$cd_work/verify-tasks.txt"

    # An extraction that silently matched nothing would compare a pinned list
    # against an empty one and report every driver as stale, which reads as a
    # regenerated Taskfile rather than as a moved anchor.
    test -s "$cd_work/verify-tasks.txt" || {
        echo "measure.sh: the verify task list could not be read from Taskfile.yml;" >&2
        echo "  its anchor moved. Fix the extraction in measure.sh's check_drivers." >&2
        return 1
    }

    strip_comments "$cd_drivers" >"$cd_work/pinned-drivers.txt"
    cd_undriven=$(comm -13 "$cd_work/pinned-drivers.txt" "$cd_work/verify-tasks.txt")
    cd_stale=$(comm -23 "$cd_work/pinned-drivers.txt" "$cd_work/verify-tasks.txt")
    if test -n "$cd_undriven"; then
        echo "measure.sh: verify runs these tasks and drivers.tsv does not pin them:" >&2
        printf '%s\n' "$cd_undriven" | sed 's/^/  /' >&2
        echo "  An undriven gate makes the ledger grow for a reason unrelated to the" >&2
        echo "  compiler. Regenerate drivers.tsv." >&2
        return 1
    fi
    if test -n "$cd_stale"; then
        echo "measure.sh: drivers.tsv pins these and verify no longer runs them:" >&2
        printf '%s\n' "$cd_stale" | sed 's/^/  /' >&2
        return 1
    fi
}

if test "${1:-}" = "--check-driver-failures"; then
    check_driver_failures "${2:?usage: --check-driver-failures RESULTS EXPECTED}" \
        "${3:?usage: --check-driver-failures RESULTS EXPECTED}"
    echo "PASS: every driver that failed is recorded, and every record still fails"
    exit 0
fi

# The basis check on its own, so a caller that is not measuring can reach it.
# `tests/preflight/check.sh` is the caller this exists for: it reports every
# structural obligation a change carries in one run, and until this entry point
# existed the only thing that read drivers.tsv was a multi-hour measurement.
if test "${1:-}" = "--check-drivers"; then
    cd_dir=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pair-drivers.XXXXXX")
    trap 'rm -rf "$cd_dir"' 0 1 2 15
    test -f "${2:-$DRIVERS}" || {
        echo "measure.sh: missing ${2:-$DRIVERS}" >&2
        exit 1
    }
    check_drivers "$cd_dir" "${2:-}"
    echo "PASS: drivers.tsv pins exactly the tasks verify runs"
    exit 0
fi

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

# -O0 because gcov's attribution under optimisation is not trustworthy. -w
# because this build proves nothing about warnings.
COVERAGE_FLAGS="-std=c11 -O0 --coverage -w"
INPUT_TIMEOUT=${KOFUN_PAIR_COVERAGE_TIMEOUT:-600}

SOURCE=${KOFUN_PAIR_COVERAGE_SOURCE:-$ROOT/bootstrap/stage2/compiler.c}
if test "$SOURCE" != "$ROOT/bootstrap/stage2/compiler.c"; then
    echo "NOTE: measuring $SOURCE, not the tree's compiler.c" >&2
fi

mkdir -p "$WORK"

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

check_drivers "$WORK"

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
#
# THE SERIAL LOOP IS THIS LEDGER'S WHOLE COST PROBLEM, AND IT IS NOT INHERENT.
# This phase is `verify`'s own driver set run one at a time; CI runs the same
# set through `task --parallel`. Its current timing belongs to the exact CI run,
# while this measurement's serial timing is recorded in undefended.tsv. The
# serialisation buys profile integrity, not correctness of the drivers, and the
# toolchains already ship the mechanism that would buy both:
#
#   gcc    GCOV_PREFIX per worker gives each driver its own .gcda tree, and
#          `gcov-tool merge dirA dirB -o dirC` combines them. MEASURED: two runs
#          of one binary, each taking a different branch, merge into a profile
#          showing both taken and the unreachable one at 0%. That is the union
#          this needs.
#   clang  ONLY HALF OF THAT WORKS, and the earlier note here was wrong. This
#          builds with `--coverage`, which writes gcda in LLVM's own version of
#          the format. GCOV_PREFIX does isolate them, but `gcov-tool merge`
#          refuses to read them -- "incorrect gcov version 1110520106 vs
#          1110848042" -- and LLVM ships no gcov merge tool. `llvm-profdata`
#          takes `-fprofile-instr-generate` raw profiles, a different
#          instrumentation that measures something else; `LLVM_PROFILE_FILE`
#          and its `%p` pattern belong to that mode and have no effect here.
#          Conflating the two is what made the earlier claim look reasonable.
#
# So the clang half stays serial until something can merge its profiles.
# Per-worker gcov directories plus `gcov-tool merge` could parallelise the gcc
# driver phase, but the pair-wide saving must be measured on one exact tree
# rather than inferred from an older wall-clock run.
#
# Doing it is out of #1408's scope and needs its own evidence -- a parallel run
# and a serial run over the same tree
# must produce the same ledger, and nothing short of that comparison should be
# believed. But it is the concrete answer to "a both-directions ledger is
# unmaintainable when compiler.c takes 51 commits a week", and that answer
# belongs next to the line that causes the problem rather than in a comment
# thread.
KOFUN_STAGE2_COMPILER="$WORK/stage2-cov"
export KOFUN_STAGE2_COMPILER

# Give the latency backstops room, because THIS RUN IS NOT MEASURING LATENCY.
# The binary the drivers exercise is built -O0 --coverage and is several times
# slower than the -O2 one those bounds were calibrated against, and the machine
# is shared. A backstop that fires turns a slow-but-correct gate into a failed
# driver, and a failed driver's unreached branches are reported as undefended --
# a fabricated finding, in the one form that does not reproduce.
#
# Raising a bound cannot make a gate pass that would otherwise fail on its
# assertions; it only stops the clock deciding. Only the knobs the gates
# themselves expose are touched -- no gate script is modified:
#
#   KOFUN_SEMANTIC_TIMEOUT         tests/fuzz/semantic_runner.sh, default 10s
#   KOFUN_VISIBILITY_FUZZ_TIMEOUT  visibility fuzz cases, default 30s
#
# NOT COVERED, and stated because a partial mitigation read as a total one is
# worse than none: `tests/fuzz/grammar.sh:101` uses a hard-coded `timeout 2`,
# `tests/conformance/run.sh:260` a hard-coded `timeout 10`, and
# `tests/lsp/semantic_sidecar_test.mjs` asserts an absolute `hover p95 < 2ms`
# that `roadmap` runs. Those can still fail on a loaded box, and when they do
# the answer is the driver-failure policy's: re-run on a quiet machine. They are
# the reason this mitigation reduces the risk rather than removing it.
KOFUN_SEMANTIC_TIMEOUT=${KOFUN_SEMANTIC_TIMEOUT:-120}
KOFUN_VISIBILITY_FUZZ_TIMEOUT=${KOFUN_VISIBILITY_FUZZ_TIMEOUT:-300}
export KOFUN_SEMANTIC_TIMEOUT KOFUN_VISIBILITY_FUZZ_TIMEOUT

# Attempts per driver before its failure is treated as real. See the retry
# comment in the loop below for why retrying is sound here and does not soften
# the failure policy.
DRIVER_ATTEMPTS=${KOFUN_PAIR_COVERAGE_ATTEMPTS:-4}
phase_start=$(date +%s)
: >"$WORK/driver-results.tsv"
: >"$WORK/driver-retries.tsv"
while IFS= read -r driver; do
    test -n "$driver" || continue
    # RETRY, because the coverage profile ACCUMULATES. A driver that fails on a
    # busy machine and succeeds on a second attempt has contributed its full
    # path, and gcda counters are a union across runs of the same binary, so the
    # retry costs minutes where discarding the run costs hours. Measured on this
    # branch: `roadmap` runs an LSP budget asserting 145ms of CPU for a
    # diagnostic, and a probe under load 20 measured 148.91ms -- 2.7% over, on a
    # machine whose load came from a build in an unrelated repository.
    #
    # This does not weaken the failure policy, it sharpens what the policy is
    # asked to judge. A deterministic failure -- `discovery` under the
    # instrumented-compiler hook -- fails every attempt and still needs a
    # recorded reason. A load failure passes on a retry. The machine makes the
    # distinction rather than my guess about which kind it was.
    attempt=1
    while :; do
        # `</dev/null` is load-bearing: a gate that reads standard input
        # otherwise consumes the rest of THIS loop's input and the loop ends
        # early, exiting 0. `cli-framework` did exactly that, silently running
        # 76 of 138 drivers.
        rc=0
        ( cd "$ROOT" && task "$driver" ) >"$WORK/log.$driver" 2>&1 </dev/null || rc=$?
        test "$rc" -eq 0 && { code=ok; break; }
        code="exit=$rc"
        test "$attempt" -ge "$DRIVER_ATTEMPTS" && break
        cp "$WORK/log.$driver" "$WORK/log.$driver.attempt$attempt"
        printf '%s\t%s\tattempt %s\n' "$driver" "$code" "$attempt" \
            >>"$WORK/driver-retries.tsv"
        # STAGED BACKOFF, because the quantity being waited out moves on the
        # scale of minutes, not seconds. Retrying three times ten seconds apart
        # samples one load condition three times; the machine's load has swung
        # between 3 and 33 today on a timescale of minutes. Each retry should
        # see a genuinely different machine or it is not a retry, it is a
        # repetition -- the same reason a single sample of a load-sensitive
        # quantity tells you where it can be and not where it ranges.
        case $attempt in
            1) sleep 10 ;;
            2) sleep 60 ;;
            *) sleep 180 ;;
        esac
        attempt=$((attempt + 1))
    done
    printf '%s\t%s\n' "$driver" "$code" >>"$WORK/driver-results.tsv"
done <"$WORK/pinned-drivers.txt"

# Retries are recorded rather than silent: a run that needed several is evidence
# about the machine, and the ledger's cost line means less without it.
if test -s "$WORK/driver-retries.tsv"; then
    printf 'measure.sh: %s driver attempt(s) failed and were retried:\n' \
        "$(grep -c . "$WORK/driver-retries.tsv")" >&2
    sed 's/^/    /' "$WORK/driver-retries.tsv" >&2
fi
declared=$(grep -c . "$WORK/pinned-drivers.txt")
attempted=$(grep -c . "$WORK/driver-results.tsv")
test "$declared" -eq "$attempted" || {
    echo "measure.sh: $((declared - attempted)) driver(s) never ran." >&2
    echo "  Refusing to report a basis smaller than the one the ledger names." >&2
    exit 1
}

# ATTEMPTED IS NOT RUN. The count above catches the loop ending early; it says
# nothing about a driver that ran and FAILED, and a failed driver contributes
# the coverage of however far it got. That gap is not academic on this machine:
# `tests/fuzz/semantic_runner.sh` has TIMEOUT_SECONDS=10 and `roadmap` runs the
# LSP sidecar's absolute `hover p95 < 2ms` assertion, so a loaded box can fail
# either one. The measurement would then report the branches that driver did not
# reach as undefended -- inventing exactly the findings this ledger exists to
# make trustworthy, and inventing them in the one way that does not reproduce.
#
# So every non-ok driver must be recorded with a reason, and this fails in BOTH
# directions like every other ledger here: an unrecorded failure is refused, and
# a recorded driver that now succeeds is refused too, so the file shrinks rather
# than accumulating excuses.
check_driver_failures "$WORK/driver-results.tsv" "$HERE/driver-failures.tsv" "$WORK"

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
# The notes basename is DERIVED, not hard-coded, and this is the second half of
# the KOFUN_PAIR_COVERAGE_SOURCE seam. `cc src.c -o out` names its coverage
# files `<out>-<source stem>.gcno`, so `compiler.c` gives `stage2-cov-compiler`
# and a mutated copy gives `stage2-cov-compiler.mutated`. Only the .gcov output
# name below was derived from $SOURCE; this one was written `stage2-cov-compiler`
# and so was correct for exactly one source file -- the one it was developed
# against.
#
# That made the seam work for the build and fail at the read: criterion 4's
# tree-side probe measured for 105 minutes, collected both phases, and then
# found no notes file. gcov reports that as "No executable lines", which parses
# as a coverage result rather than a missing input, and check.sh then refused
# the mutant for having no data at all. The refusal looked like the refusal the
# proof wanted. It was caught only because that proof requires the refusal to
# NAME sl_emit_expr rather than merely occur.
#
# The `.gcno` suffix is load-bearing. gcov's `-o FILE` strips ONE extension from
# what it is given, so `-o stage2-cov-compiler.mutated` becomes a search for
# `stage2-cov-compiler.gcno` -- the original file, silently, which is how the
# hard-coded name looked correct. Handing it the notes path itself round-trips:
# `.gcno` is the extension it strips. Verified against both readers, since
# `llvm-cov gcov` only emulates gcov: gcc and clang both name their notes
# `<output>-<source stem>.gcno`, and both accept `-o <that path>` and emit
# `<source>.gcov`.
GCOV_NOTES="$WORK/stage2-cov-$(basename "$SOURCE" .c).gcno"
# shellcheck disable=SC2086
( cd "$WORK" && $GCOV_TOOL -b -f -o "$GCOV_NOTES" "$SOURCE" ) \
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
