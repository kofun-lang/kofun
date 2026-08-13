#!/bin/sh
set -eu

# Usability corpus gate for #909.
#
# The corpus is evidence for a UX decision, so the thing that has to be true
# is that the evidence is not stale. Four kinds of drift are checked:
#
#   1. every row labelled executable-today still compiles AND still produces
#      the observations recorded here, named one by one;
#   2. every row labelled blocked-on is still genuinely refused, with the
#      recorded diagnostic — a row that starts compiling fails the gate and
#      has to be relabelled rather than quietly becoming a lie;
#   3. item 7 still only *references* the frozen self-host source, whose
#      digest still matches bootstrap/stage1/SHA256SUMS, and no copy of it
#      has appeared in this directory;
#   4. the rubric still names all seven measures, still excludes character
#      count, and still carries one score row per numbered item.
#
# `sh tests/usability/check.sh --measure` reprints the M3 delimiter counts
# the rubric records, so a reviewer can reproduce them rather than trust them.
#
# Comparison implementations in Go and Rust are compiled and run when those
# toolchains exist. Gleam and Kotlin are not installed in this image; those
# files are reported as skipped by name. A skipped comparison is never
# reported as a pass.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CASES="$ROOT/tests/usability"
MANIFEST="$CASES/manifest.tsv"
RUBRIC="$CASES/rubric.md"
FROZEN="$ROOT/bootstrap/stage1/compiler.kofun"
CC=${CC:-cc}
ASSERT_CONTEXT="usability corpus"
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-usability.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'usability corpus: FAIL: %s\n' "$*" >&2
    exit 1
}

# Non-comment, non-blank manifest rows.
rows() {
    grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$'
}

# ------------------------------------------------------------- M3 measure
#
# The delimiter counts rubric.md records under M3. Kept in the gate rather
# than in a separate script so the rubric's numbers and the corpus cannot
# drift apart without one command showing it.

measure() {
    for source in "$CASES"/0*.kofun "$CASES"/0*.rs "$CASES"/0*.go \
        "$CASES"/0*.kt "$CASES"/0*.gleam
    do
        awk -v name="$(basename "$source")" '
            {
                line = $0
                sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
                if (line == "" || line ~ /^#/ || line ~ /^\/\//) next
                body++
                if (line ~ /^[})\];,]+$/) closers++
                opens = gsub(/\{/, "{", line)
                closes = gsub(/\}/, "}", line)
                depth += opens - closes
                if (depth > maxdepth) maxdepth = depth
            }
            END {
                printf "%-30s body=%-4d depth=%-3d closers=%d\n",
                    name, body, maxdepth, closers
            }
        ' "$source"
    done
}

if test "${1:-}" = "--measure"; then
    measure
    exit 0
fi

# ------------------------------------------------------------ the manifest

assert_regular_file 'the corpus manifest' "$MANIFEST"
assert_regular_file 'the rubric' "$RUBRIC"

rows >"$WORK/rows.tsv"
row_count=$(wc -l <"$WORK/rows.tsv" | tr -d ' ')
assert_num '#624 has eight numbered corpus rows; the manifest' \
    "$row_count" -eq 8

# One row per number, in order, none missing and none doubled.
expected_item=0
while IFS='	' read -r item status owner source comparison language note; do
    expected_item=$((expected_item + 1))
    assert_eq "manifest row $expected_item is out of order or duplicated" \
        "$item" "$expected_item"
    assert_nonempty "row $item has no note column" "$note"
    assert_nonempty "row $item has no language column" "$language"

    assert_regular_file "row $item names a Kofun source that is missing" \
        "$CASES/$source"

    case $status in
        executable-today)
            assert_nonempty "row $item is executable-today with no runner" \
                "$owner"
            ;;
        blocked-on)
            # Exactly one issue number, digits only. "Exactly one" is the
            # acceptance criterion: a row blocked on two things names neither.
            case $owner in
                *[!0-9]*|'')
                    fail "row $item is blocked-on but its owner is not a single issue number: '$owner'"
                    ;;
            esac
            # The source must name its own owner, so the label and the file
            # cannot disagree.
            assert_grep "row $item does not name issue #$owner in its own header" \
                -Fq -- "#$owner" "$CASES/$source"
            ;;
        *)
            fail "row $item has status '$status'; expected executable-today or blocked-on"
            ;;
    esac

    case $comparison in
        -)
            # No comparison is permitted only with a recorded reason, and a
            # dash is not a reason.
            assert_eq "row $item has no comparison and no language marker" \
                "$language" none
            reason_length=$(printf '%s' "$note" | wc -c | tr -d ' ')
            assert_num "row $item has no comparison and no recorded reason" \
                "$reason_length" -gt 40
            ;;
        *)
            assert_regular_file \
                "row $item names a comparison file that is missing" \
                "$CASES/$comparison"
            ;;
    esac
done <"$WORK/rows.tsv"

printf 'usability corpus: eight rows, each labelled and each with a source: PASS\n'

# --------------------------------------------------------- executable rows
#
# Each block runs the row's recorded command and reads the observations one
# at a time, so a failure names the decision that moved rather than only that
# a golden differs.

kofun_check() {
    "$ROOT/bin/kofun" check "$1" >"$WORK/check.stdout" 2>"$WORK/check.stderr" ||
        fail "$(basename "$1") no longer passes \`kofun check\`: $(cat "$WORK/check.stderr")"
}

kofun_build_run() {
    stem=$(basename "$1" .kofun)
    shift
    "$ROOT/bin/kofun" build "$CASES/$stem.kofun" "$@" -o "$WORK/$stem" \
        >"$WORK/$stem.build.stdout" 2>"$WORK/$stem.build.stderr" ||
        fail "$stem checks but no longer builds: $(cat "$WORK/$stem.build.stderr")"
    assert_executable "$stem did not produce a binary" "$WORK/$stem"
    "$WORK/$stem" >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr" ||
        fail "$stem built but exited non-zero: $(cat "$WORK/$stem.stderr")"
}

line() {
    sed -n "$2p" "$1"
}

# --- item 1: pure list pipeline with map / filter / fold -------------------
#
# Runs on the direct native backend; the Stage 2 C11 path does not lower
# List values (tests/conformance/capabilities.tsv). Both halves are asserted:
# the native build runs, and `kofun check` still refuses it. The second is
# what makes the "which backend?" surprise in rubric.md M1 a recorded fact.

kofun_build_run 01_list_pipeline.kofun --target x86_64-linux
assert_eq 'item 1: filter >6, map *2, fold from 0 over [3,12,7,5]' \
    "$(line "$WORK/01_list_pipeline.stdout" 1)" '38'
assert_num 'item 1 prints exactly one line' \
    "$(wc -l <"$WORK/01_list_pipeline.stdout" | tr -d ' ')" -eq 1

if "$ROOT/bin/kofun" check "$CASES/01_list_pipeline.kofun" \
    >"$WORK/i1.check.stdout" 2>"$WORK/i1.check.stderr"
then
    fail 'item 1 now passes `kofun check`; the Stage 2 List boundary moved and rubric.md M1 must be re-scored'
fi
assert_grep 'item 1 is refused by Stage 2 for a new reason' \
    -Fq -- 'unknown Core function `filter`' "$WORK/i1.check.stderr"

printf 'usability corpus: item 1 list pipeline, native backend only: PASS\n'

# --- item 2: parser returning Result through three fallible steps ----------

kofun_check "$CASES/02_parser_result.kofun"
kofun_build_run 02_parser_result.kofun
assert_eq 'item 2: 42 passes all three steps and is scaled by ten' \
    "$(line "$WORK/02_parser_result.stdout" 1)" '420'
assert_eq 'item 2: 1000 fails the range step and returns its negated code' \
    "$(line "$WORK/02_parser_result.stdout" 2)" '-2'

# The three `: ParseResult` annotations are required by `build` and not by
# `check`. rubric.md scores that split as 2.M2 = 0 and 2.M5 = 0; if the split
# closes, both scores are wrong and the gate says so.
sed 's/let digits: ParseResult =/let digits =/' \
    "$CASES/02_parser_result.kofun" >"$WORK/02_stripped.kofun"
"$ROOT/bin/kofun" check "$WORK/02_stripped.kofun" \
    >"$WORK/02_stripped.check.stdout" 2>"$WORK/02_stripped.check.stderr" ||
    fail 'item 2 without its binding annotation is now refused by `check`; rubric.md 2.M5 must be re-scored'
if "$ROOT/bin/kofun" build "$WORK/02_stripped.kofun" \
    -o "$WORK/02_stripped" >"$WORK/02_stripped.build.stdout" \
    2>"$WORK/02_stripped.build.stderr"
then
    fail 'item 2 without its binding annotation now builds; the annotation is no longer required and rubric.md 2.M2 must be re-scored'
fi

printf 'usability corpus: item 2 Result through three steps, and the check/build split: PASS\n'

# --- item 3: read / edit / take, with no use-after-move --------------------
#
# `read` and `take` parameters are understood by the bounded record frontend
# and by nothing else, so this row runs there. Three things are asserted: the
# positive program runs, `edit` is still refused by DD-021, and the
# use-after-move fixture already in the tree is still refused.

command -v "$CC" >/dev/null 2>&1 ||
    fail "a C11 compiler is required to build the record frontend"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$ROOT/bootstrap/stage2/record_frontend.c" -o "$WORK/record-frontend" \
    >"$WORK/frontend.build.stdout" 2>"$WORK/frontend.build.stderr" ||
    fail "record frontend did not build: $(cat "$WORK/frontend.build.stderr")"

"$WORK/record-frontend" "$CASES/03_ownership_modes.kofun" \
    "$WORK/03.ir" "$WORK/03.layout" "$WORK/03.run" \
    >"$WORK/03.stdout" 2>"$WORK/03.stderr" ||
    fail "item 3 no longer passes the record frontend: $(cat "$WORK/03.stderr")"
assert_grep 'item 3: two borrowed reads of one session, neither consuming it' \
    -Fq -- 'call|function=lifecycle|result=14' "$WORK/03.run"

# `edit` is refused by design, not by omission. DD-021 makes records
# immutable and #909 does not reopen it, so this refusal is part of the row.
# The record frontend reports diagnostics on stdout, so both streams are
# captured together and the assertion reads the pair.
if "$WORK/record-frontend" "$ROOT/tests/conformance/records/edit_parameter.kofun" \
    "$WORK/edit.ir" "$WORK/edit.layout" "$WORK/edit.run" \
    >"$WORK/edit.output" 2>&1
then
    fail '`edit` on a record is now accepted; DD-021 changed and item 3 must be rewritten to show all three modes'
fi
assert_grep 'the `edit` refusal changed its reason' -Fq -- \
    'error[E2S121]: `edit` access to a record is unsupported in v1' \
    "$WORK/edit.output"

# The use-after-move proof is the fixture already in the tree; this corpus
# references it rather than checking in a second copy.
if "$WORK/record-frontend" "$ROOT/tests/conformance/records/use_after_move.kofun" \
    "$WORK/uam.ir" "$WORK/uam.layout" "$WORK/uam.run" \
    >"$WORK/uam.output" 2>&1
then
    fail 'use-after-move is no longer refused; item 3 rests on that refusal'
fi
assert_grep 'the use-after-move refusal changed its reason' -Fq -- \
    'error[E2S123]: `token` was moved by `take` and cannot be used again' \
    "$WORK/uam.output"

printf 'usability corpus: item 3 read and take run, edit and use-after-move refused: PASS\n'

# --- item 4: ADT + record + exhaustive match ------------------------------

kofun_check "$CASES/04_adt_record_match.kofun"
kofun_build_run 04_adt_record_match.kofun
assert_eq 'item 4: Circle(5) doubles its radius through a filled extent' \
    "$(line "$WORK/04_adt_record_match.stdout" 1)" '10'
assert_eq 'item 4: Square(7) keeps its side' \
    "$(line "$WORK/04_adt_record_match.stdout" 2)" '7'
assert_eq 'item 4: an unfilled extent describes as zero' \
    "$(line "$WORK/04_adt_record_match.stdout" 3)" '0'

# Exhaustiveness is the property this row exists to show. Dropping an arm
# must stay a compile error that names the missing constructor.
sed '/Empty => { width = 0 },/d' "$CASES/04_adt_record_match.kofun" \
    >"$WORK/04_inexhaustive.kofun"
if "$ROOT/bin/kofun" check "$WORK/04_inexhaustive.kofun" \
    >"$WORK/04_inexhaustive.stdout" 2>"$WORK/04_inexhaustive.stderr"
then
    fail 'a match missing the `Empty` arm now passes check; exhaustiveness is the point of item 4'
fi
assert_grep 'the exhaustiveness diagnostic no longer names the missing constructor' \
    -Fq -- "missing constructors \`Empty\`" "$WORK/04_inexhaustive.stderr"

printf 'usability corpus: item 4 ADT, record, and enforced exhaustiveness: PASS\n'

# --- item 7: the frozen self-host profile ---------------------------------
#
# The reviewed program is bootstrap/stage1/compiler.kofun. This row must
# reference it and must not copy it.

assert_regular_file 'the frozen self-host source' "$FROZEN"
kofun_check "$FROZEN"

frozen_digest=$("$ROOT/bin/kofun-sha256" "$FROZEN" | cut -d' ' -f1)
recorded_digest=$(awk '$2 == "compiler.kofun" { print $1 }' \
    "$ROOT/bootstrap/stage1/SHA256SUMS")
assert_eq 'the frozen self-host source no longer matches its recorded digest' \
    "$frozen_digest" "$recorded_digest"

# No copy of the frozen source may live in this directory. Compare digests
# rather than names, so a renamed copy is caught too.
for candidate in "$CASES"/*.kofun; do
    candidate_digest=$("$ROOT/bin/kofun-sha256" "$candidate" | cut -d' ' -f1)
    assert_ne "a copy of the frozen self-host source is checked in as $(basename "$candidate")" \
        "$candidate_digest" "$frozen_digest"
done

assert_grep 'item 7 no longer references the frozen source by path' \
    -Fq -- 'bootstrap/stage1/compiler.kofun' \
    "$CASES/07_self_host_profile.kofun"

kofun_check "$CASES/07_self_host_profile.kofun"
kofun_build_run 07_self_host_profile.kofun
frozen_lines=$(wc -l <"$FROZEN" | tr -d ' ')
assert_eq 'item 7 records a line count the frozen source no longer has' \
    "$(line "$WORK/07_self_host_profile.stdout" 1)" "$frozen_lines"
assert_eq 'item 7 records a profile builtin count that MVP_IMPLEMENTED.md no longer states' \
    "$(line "$WORK/07_self_host_profile.stdout" 2)" '15'
assert_grep 'MVP_IMPLEMENTED.md no longer states the 15-builtin profile' \
    -Fq -- '15 typed profile builtins' "$ROOT/docs/MVP_IMPLEMENTED.md"

printf 'usability corpus: item 7 references the frozen profile and agrees with its digest: PASS\n'

# ------------------------------------------------------------ blocked rows
#
# A blocked row is only honest while it is still blocked. Each is refused,
# for the recorded reason. If one starts compiling, this gate fails and the
# row must be relabelled executable-today and re-scored in rubric.md.

expect_refused() {
    stem=$1
    reason=$2
    if "$ROOT/bin/kofun" check "$CASES/$stem.kofun" \
        >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    then
        fail "$stem now compiles; relabel its manifest row executable-today and re-score it in rubric.md"
    fi
    assert_grep "$stem is still refused, but for a new reason" \
        -Fq -- "$reason" "$WORK/$stem.stderr"
    printf 'usability corpus: %s still refused: %s: PASS\n' "$stem" "$reason"
}

expect_refused 05_higher_order \
    'error[E2S17]: Core function `accumulate` expects 3 arguments, got -1'
expect_refused 06_monad_laws \
    'error[E2S02]: expected top-level `fn`, `type`, or `let`'
expect_refused 08_stream_pipeline \
    'error[E2S35]: malformed parameter head at byte 2141'

# ------------------------------------------------------------- the rubric

for measure in \
    'M1 Semantic surprises' \
    'M2 Required annotations' \
    'M3 Delimiter and indentation load' \
    'M4 Hidden control flow and allocation' \
    'M5 Diagnostic quality' \
    'M6 Formatter stability' \
    'M7 Beginner readability'
do
    assert_grep "the rubric lost a measure #624 names: $measure" \
        -Fq -- "$measure" "$RUBRIC"
done

assert_grep 'the rubric no longer excludes character count' \
    -Fq -- '## Character count is not a metric' "$RUBRIC"
assert_not_grep 'the rubric reintroduced a character-count column' \
    -qE -- '^\|.*[Cc]haracter count.*\|' "$RUBRIC"

# One score row per numbered item in each of the two score tables. A score
# row is a table row whose first cell is the item number and which carries
# eight further cells — the subject plus all seven measures. The 0-3 anchor
# tables above have two cells, so they cannot match.
for item in 1 2 3 4 5 6 7 8; do
    score_rows=$(grep -cE "^\| $item \|([^|]*\|){8}\$" "$RUBRIC" || true)
    assert_num "the rubric is missing a Kofun or comparison score row for item $item" \
        "$score_rows" -eq 2
done

printf 'usability corpus: rubric names seven measures, excludes character count, scores eight rows twice: PASS\n'

# ------------------------------------------------- comparison implementations
#
# Go and Rust are compiled and run. Gleam and Kotlin are not installed here;
# those files are reported skipped by name and are never counted as passing.

if command -v rustc >/dev/null 2>&1; then
    rustc -O "$CASES/02_parser_result.rs" -o "$WORK/rs02" \
        >"$WORK/rs02.build.stdout" 2>"$WORK/rs02.build.stderr" ||
        fail "02_parser_result.rs did not compile: $(cat "$WORK/rs02.build.stderr")"
    "$WORK/rs02" >"$WORK/rs02.stdout" 2>"$WORK/rs02.stderr" ||
        fail "02_parser_result.rs did not run: $(cat "$WORK/rs02.stderr")"
    # The comparison is only a comparison if both programs answer the same
    # question. They must agree observation for observation.
    cmp "$WORK/02_parser_result.stdout" "$WORK/rs02.stdout" ||
        fail 'the Rust parser no longer produces the same observations as the Kofun parser'

    rustc -O "$CASES/03_ownership_modes.rs" -o "$WORK/rs03" \
        >"$WORK/rs03.build.stdout" 2>"$WORK/rs03.build.stderr" ||
        fail "03_ownership_modes.rs did not compile: $(cat "$WORK/rs03.build.stderr")"
    "$WORK/rs03" >"$WORK/rs03.stdout" 2>"$WORK/rs03.stderr" ||
        fail "03_ownership_modes.rs did not run: $(cat "$WORK/rs03.stderr")"
    assert_eq 'the Rust ownership comparison no longer agrees with the Kofun lifecycle result' \
        "$(line "$WORK/rs03.stdout" 1)" '14'

    rustc --test "$CASES/06_monad_laws.rs" -o "$WORK/rs06" \
        >"$WORK/rs06.build.stdout" 2>"$WORK/rs06.build.stderr" ||
        fail "06_monad_laws.rs did not compile: $(cat "$WORK/rs06.build.stderr")"
    "$WORK/rs06" >"$WORK/rs06.stdout" 2>"$WORK/rs06.stderr" ||
        fail "06_monad_laws.rs law tests failed: $(cat "$WORK/rs06.stdout")"
    assert_grep 'the three monad laws and the domain-completeness check no longer all pass' \
        -Fq -- '4 passed; 0 failed' "$WORK/rs06.stdout"
    printf 'usability corpus: Rust comparisons for items 2, 3, and 6 compile and agree: PASS\n'
else
    printf 'usability corpus: SKIP: no rustc; items 2, 3, and 6 comparisons not run\n'
fi

if command -v go >/dev/null 2>&1; then
    GOCACHE="$WORK/go-cache"
    export GOCACHE
    go run "$CASES/08_stream_pipeline.go" >"$WORK/go08.stdout" \
        2>"$WORK/go08.stderr" ||
        fail "08_stream_pipeline.go did not run: $(cat "$WORK/go08.stderr")"
    assert_eq 'the Go pipeline no longer takes exactly three values before cancelling' \
        "$(line "$WORK/go08.stdout" 4)" 'cancelled after 3'
    assert_eq 'the Go pipeline no longer filters and doubles in order' \
        "$(line "$WORK/go08.stdout" 1) $(line "$WORK/go08.stdout" 2) $(line "$WORK/go08.stdout" 3)" \
        '24 14 40'
    printf 'usability corpus: Go comparison for item 8 compiles and cancels deterministically: PASS\n'
else
    printf 'usability corpus: SKIP: no go toolchain; item 8 comparison not run\n'
fi

for skipped in 01_list_pipeline.gleam 04_adt_record_match.kt 05_higher_order.kt
do
    assert_regular_file "a comparison file went missing: $skipped" \
        "$CASES/$skipped"
    printf 'usability corpus: SKIP: no toolchain for %s; read, not run\n' \
        "$skipped"
done

printf 'usability corpus: eight rows, four executable, three refused as recorded, one referenced: PASS\n'
