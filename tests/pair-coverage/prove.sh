#!/bin/sh
# Proof that `tests/pair-coverage/check.sh` refuses, in all four directions.
# (#1408 acceptance criterion 4)
#
# A gate that has not been shown to fail is not accepted here. This shows each
# direction SEPARATELY, because a single mutation proves only the branch it
# happens to reach: the other three would ship as assertions nobody had
# demonstrated could fail. That is not hypothetical -- #1379 shipped six budget
# assertions with one proved, because the first failure threw before the rest
# were evaluated.
#
#   sh tests/pair-coverage/prove.sh WORK_DIR          the four ledger directions
#   sh tests/pair-coverage/prove.sh WORK_DIR --tree   also the tree-side mutation
#
# The four directions below mutate the MEASUREMENT, which is what distinguishes
# them from each other cheaply. `--tree` additionally does what criterion 4
# asks literally: add a branch to `bootstrap/stage2/compiler.c` that no pinned
# input reaches, measure for real, and require the gate to refuse it. That costs
# a full measuring run, which is why it is separate rather than skipped -- a
# criterion satisfied only by a cheap analogue is not satisfied.
#
# The tree-side mutation edits the canonical pair, so it is applied to a COPY of
# `compiler.c` compiled into a scratch directory, never to the file in the tree.
# A crash here cannot leave the pair modified.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
WORK=${1:?usage: prove.sh WORK_DIR}
mkdir -p "$WORK"

LEDGER="$ROOT/tests/pair-coverage/undefended.tsv"
MEASURED="$WORK/baseline.tsv"

pass=0
fail=0

# Each case supplies a ledger and a measurement, runs the gate against them, and
# requires refusal WITH a message naming the right function. "It failed" is not
# enough: a gate that refuses everything for one reason would satisfy a
# does-it-fail check while reporting the wrong subject.
expect_refusal() {
    label=$1; ledger=$2; measured=$3; want=$4
    if KOFUN_PAIR_COVERAGE_MEASURED="$measured" \
        sh "$ROOT/tests/pair-coverage/check.sh" >"$WORK/out.$label" 2>&1
    then
        printf 'FAIL: %s was ACCEPTED; the gate does not refuse it\n' "$label" >&2
        fail=$((fail + 1))
        return
    fi
    if grep -q "$want" "$WORK/out.$label"; then
        printf 'ok   %-28s refused, naming %s\n' "$label" "$want"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s refused but did not name %s:\n' "$label" "$want" >&2
        sed 's/^/      /' "$WORK/out.$label" >&2
        fail=$((fail + 1))
    fi
}

test -s "$LEDGER" || { echo "prove.sh: no ledger at $LEDGER" >&2; exit 1; }
grep -v '^#' "$LEDGER" | grep -v '^[[:space:]]*$' | sort -k3,3 >"$MEASURED"

# The honest baseline: ledger against itself must PASS. Without this the four
# refusals below prove only that the gate is capable of failing, not that it
# distinguishes.
if KOFUN_PAIR_COVERAGE_MEASURED="$MEASURED" \
    sh "$ROOT/tests/pair-coverage/check.sh" >"$WORK/out.baseline" 2>&1
then
    printf 'ok   %-28s accepted, as it must be\n' "baseline"
    pass=$((pass + 1))
else
    printf 'FAIL: the unmutated ledger was REFUSED; every result below is void:\n' >&2
    sed 's/^/      /' "$WORK/out.baseline" >&2
    exit 1
fi

# Each case targets a DIFFERENT function on purpose. Pointing all of them at
# the same row would pass even if the gate always reported the first entry
# regardless of which one changed -- the message would name the right function
# by coincidence. Distinct subjects are what make "refused, naming X" evidence
# that the gate read X rather than guessed it.
first=$(head -1 "$MEASURED" | cut -f3)
last=$(tail -1 "$MEASURED" | cut -f3)
middle=$(awk -F'\t' 'NR==2 {print $3}' "$MEASURED")
test -n "$middle" || middle=$last
if test "$first" = "$last"; then
    echo "prove.sh: the ledger has one row; the distinct-subject cases below" >&2
    echo "  cannot distinguish a gate that always names it. Refusing." >&2
    exit 1
fi

# 1. more untaken than recorded -- a branch stopped being reached
awk -F '\t' -v f="$first" 'BEGIN{OFS="\t"} $3==f {$1=$1+1} {print}' \
    "$MEASURED" >"$WORK/m.grew"
expect_refusal "untaken-count-grew" "$LEDGER" "$WORK/m.grew" "$first"

# 2. fewer untaken than recorded -- an improvement nobody wrote down
awk -F '\t' -v f="$middle" 'BEGIN{OFS="\t"} $3==f {$1=$1-1} $1>0 {print}' \
    "$MEASURED" >"$WORK/m.shrank"
expect_refusal "untaken-count-shrank" "$LEDGER" "$WORK/m.shrank" "$middle"

# 3. recorded, now absent -- the function is gone or fully covered
awk -F '\t' -v f="$last" '$3 != f' "$MEASURED" >"$WORK/m.absent"
expect_refusal "recorded-now-absent" "$LEDGER" "$WORK/m.absent" "$last"

# 4. present, not recorded -- new undefended surface with no entry
{ cat "$MEASURED"; printf '3\t3\tkofun_prove_sh_unrecorded_function\n'; } \
    | sort -k3,3 >"$WORK/m.extra"
expect_refusal "present-not-recorded" "$LEDGER" "$WORK/m.extra" \
    "kofun_prove_sh_unrecorded_function"

# Criterion 4, literally: a branch added to compiler.c that no pinned input
# reaches must make the gate fail. This measures for real, so it costs a full
# run; the four cases above are analogues that distinguish the directions, and
# an analogue is not the criterion.
if test "${2:-}" = "--tree"; then
    printf '\n--- tree-side mutation (real measurement, minutes) ---\n'
    # Mutate a COPY of compiler.c and point the harness at it. Copying the
    # whole tree was tried first and was wrong: the pinned inputs also live
    # under examples/, stdlib/ and spec/, so a partial copy would have measured
    # a smaller corpus and reported a larger untaken set -- inventing exactly
    # the undefended branches this proof is meant to detect.
    # The mutant must sit where compiler.c's own relative includes resolve:
    # `#include "../../unicode/kofun_unicode.c"` and `#include "decimal_v1.c"`
    # are relative to the SOURCE FILE's directory, so a copy in a scratch dir
    # fails to compile with "No such file or directory" -- which would read as a
    # broken probe rather than a misplaced one. Mirror the two directory levels
    # and symlink the siblings instead of copying the tree.
    mkdir -p "$WORK/mirror/bootstrap/stage2"
    ln -sfn "$ROOT/unicode" "$WORK/mirror/unicode"
    for sibling in "$ROOT"/bootstrap/stage2/*.c "$ROOT"/bootstrap/stage2/*.h; do
        test -e "$sibling" || continue
        ln -sfn "$sibling" "$WORK/mirror/bootstrap/stage2/$(basename "$sibling")"
    done
    MUTANT="$WORK/mirror/bootstrap/stage2/compiler.mutated.c"
    rm -f "$MUTANT"
    # ANCHOR: inside `sl_emit_expr`, not `main`.
    #
    # The probe belongs in a region the REJECTED basis would have misreported.
    # `sl_emit_expr` is reached only when the generation chain compiles
    # `compiler.kofun`: the union basis leaves 16 of its branches untaken, the
    # corpus-only basis 118. A probe in `main` would be caught by any basis and
    # would prove nothing about the one this ledger uses; a probe here is caught
    # only because the drivers are part of the basis.
    #
    # `node_id` is a non-negative node index, so this branch exists, compiles,
    # and is taken by nothing.
    awk '
    /^static void sl_emit_expr\(SlFn \*fn, SlDoc \*doc, int64_t node_id, Buffer \*out\) \{$/ && !done {
        print
        print "    /* #1408 prove.sh probe: a branch no driver and no input reaches. */"
        print "    if (node_id == INT64_C(-987654)) { fputs(\"unreachable\\n\", stderr); }"
        done = 1
        next
    }
    { print }
    ' "$ROOT/bootstrap/stage2/compiler.c" >"$MUTANT"

    if cmp -s "$MUTANT" "$ROOT/bootstrap/stage2/compiler.c"; then
        printf 'FAIL: the tree probe did not apply; its anchor moved.\n' >&2
        printf '      Criterion 4 is UNPROVEN rather than satisfied.\n' >&2
        exit 1
    fi
    printf 'probe applied to a copy; the pair in the tree is untouched:\n'
    ( cd "$ROOT" && git status --porcelain bootstrap/stage2/compiler.c | grep . \
        && echo "  WARNING: the real compiler.c is dirty" \
        || echo "  bootstrap/stage2/compiler.c clean" )

    if KOFUN_PAIR_COVERAGE_SOURCE="$MUTANT" \
        sh "$ROOT/tests/pair-coverage/check.sh" >"$WORK/out.tree" 2>&1; then
        printf 'FAIL: tree-side mutation was ACCEPTED; the gate misses a new\n' >&2
        printf '      unreachable branch, which is the thing it exists to catch.\n' >&2
        fail=$((fail + 1))
    else
        printf 'ok   %-28s refused a real unreachable branch\n' "tree-side-mutation"
        pass=$((pass + 1))
    fi
fi

printf '\n%s case(s) passed, %s failed\n' "$pass" "$fail"
test "$fail" -eq 0 || exit 1
printf 'PASS: the ledger gate refuses every direction it claims to\n'
