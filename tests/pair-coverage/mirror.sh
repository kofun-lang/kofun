#!/bin/sh
# Does the map of "which ledger functions the Kofun half mirrors" still describe
# the tree? (#1514, parent #1401)
#
# `undefended.tsv` is #1401's work-list: per function of
# bootstrap/stage2/compiler.c, how many branches nothing takes. Its usefulness
# rests on both halves implementing the function, and for 22 of the 354 they do
# not -- while 64 more are mirrored under a different name, which is invisible
# to anyone reading the ledger. `mirror.tsv` answers that one question per row
# and this gate keeps the answer true.
#
# WHAT IT CHECKS, and deliberately no more:
#
#   every ledger function has exactly one row          a new function with no
#                                                      verdict is unread surface
#   every row names a function the ledger carries      a row for a function that
#                                                      is gone is stale
#   `same-name` / `other-name` counterparts exist      a rename in the Kofun half
#                                                      breaks the map rather than
#                                                      quietly mis-describing it
#   `c-only` functions are NOT defined in the Kofun    the strongest direction:
#   half                                               someone adding the missing
#                                                      counterpart makes the row
#                                                      fail, which is how the row
#                                                      gets retired
#   every non-`same-name` row carries a mark           a verdict with no evidence
#                                                      is a guess
#
# WHAT IT CANNOT CHECK, stated because a gate read as stronger than it is does
# more harm than none: whether two mirrored implementations AGREE. A `same-name`
# row says a function of that name exists, and #1508 found two asymmetries
# inside functions that are mirrored by name. Deciding agreement is the regional
# classification work of #1401's other children, and no name check substitutes
# for it.
#
#   sh tests/pair-coverage/mirror.sh             check the map
#   sh tests/pair-coverage/mirror.sh --count     print the verdict tallies
#   sh tests/pair-coverage/mirror.sh --prove DIR demonstrate it can refuse
#
# THIS HARNESS IS SHELL, AND THAT IS RECORDED DEBT, like its three neighbours:
# it carries a `shell-build-driver` row in
# tooling/forbidden-requirements/census.tsv, which re-derives from the tree and
# fails in both directions. RFC-0018's direction is that this becomes Kofun;
# #1451 owns that, and #1499 owns the missing piece it needs.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/pair-coverage"

# The three seams, each ANNOUNCING itself on use: a gate silently reading a file
# other than the committed one reports on something nobody is looking at.
MAP=${KOFUN_PAIR_MIRROR_MAP:-$HERE/mirror.tsv}
LEDGER=${KOFUN_PAIR_MIRROR_LEDGER:-$HERE/undefended.tsv}
KOFUN_HALF=${KOFUN_PAIR_MIRROR_SOURCE:-$ROOT/bootstrap/stage2/compiler.kofun}
if test "$MAP" != "$HERE/mirror.tsv"; then
    printf 'NOTE: pair mirror: checking %s, not the committed map.\n' "$MAP" >&2
fi
if test "$LEDGER" != "$HERE/undefended.tsv"; then
    printf 'NOTE: pair mirror: reading %s, not the committed ledger.\n' "$LEDGER" >&2
fi
if test "$KOFUN_HALF" != "$ROOT/bootstrap/stage2/compiler.kofun"; then
    printf 'NOTE: pair mirror: resolving against %s, not the tree Kofun half.\n' \
        "$KOFUN_HALF" >&2
fi

if test "${1:-}" = "--prove"; then
    PROVE=${2:?usage: mirror.sh --prove DIR}
    rm -rf "$PROVE"
    mkdir -p "$PROVE"
    passed=0
    failed=0
    prove_case() {
        case_name=$1
        want_exit=$2
        case_map=$3
        case_source=$4
        case_needle=$5
        got=0
        KOFUN_PAIR_MIRROR_MAP="$case_map" \
        KOFUN_PAIR_MIRROR_SOURCE="$case_source" \
            sh "$0" >"$PROVE/$case_name.out" 2>"$PROVE/$case_name.err" || got=$?
        if test "$got" -ne "$want_exit"; then
            printf 'FAIL: prove %s: exit %s, expected %s\n' \
                "$case_name" "$got" "$want_exit" >&2
            sed 's/^/      /' "$PROVE/$case_name.err" >&2
            failed=$((failed + 1))
            return
        fi
        if test -n "$case_needle" &&
           ! grep -qF "$case_needle" "$PROVE/$case_name.err" &&
           ! grep -qF "$case_needle" "$PROVE/$case_name.out"; then
            printf 'FAIL: prove %s: the message never names %s\n' \
                "$case_name" "$case_needle" >&2
            sed 's/^/      /' "$PROVE/$case_name.err" >&2
            failed=$((failed + 1))
            return
        fi
        printf '  prove %s: %s\n' "$case_name" \
            "$(test "$want_exit" -eq 0 && echo accepted || echo refused)"
        passed=$((passed + 1))
    }

    SRC="$ROOT/bootstrap/stage2/compiler.kofun"

    # 1. A ledger function nobody gave a verdict.
    grep -v '^lower_body	' "$HERE/mirror.tsv" >"$PROVE/missing-row.tsv"
    prove_case missing-row 1 "$PROVE/missing-row.tsv" "$SRC" lower_body

    # 2. A verdict for a function the ledger does not carry.
    cp "$HERE/mirror.tsv" "$PROVE/extra-row.tsv"
    printf 'prove_absent_zz\tc-only\t-\tA row for a function this ledger does not have.\n' \
        >>"$PROVE/extra-row.tsv"
    prove_case extra-row 1 "$PROVE/extra-row.tsv" "$SRC" prove_absent_zz

    # 3. A counterpart that is not there. This is the rename case: the map must
    #    break rather than keep pointing at a name the Kofun half dropped.
    sed 's/^sh_parse_stmt\tother-name\tselfhost_statement\t/sh_parse_stmt\tother-name\tselfhost_statement_zz\t/' \
        "$HERE/mirror.tsv" >"$PROVE/bad-counterpart.tsv"
    prove_case bad-counterpart 1 "$PROVE/bad-counterpart.tsv" "$SRC" \
        selfhost_statement_zz

    # 4. The direction that retires a row: someone writes the missing
    #    counterpart, and the `c-only` verdict must stop being true.
    cp "$SRC" "$PROVE/now-mirrored.kofun"
    printf '\nfn ends_with(value: Text, suffix: Text) -> Bool {\n    return false\n}\n' \
        >>"$PROVE/now-mirrored.kofun"
    prove_case now-mirrored 1 "$HERE/mirror.tsv" "$PROVE/now-mirrored.kofun" \
        ends_with

    # 5. A verdict with no evidence.
    sed 's/^c_identifier_name\tc-only\t-\t.*/c_identifier_name\tc-only\t-\t/' \
        "$HERE/mirror.tsv" >"$PROVE/no-mark.tsv"
    prove_case no-mark 1 "$PROVE/no-mark.tsv" "$SRC" c_identifier_name

    # 6. The committed map against the committed tree, which must pass -- a
    #    proof harness that only ever refuses would pass on a gate that refuses
    #    everything.
    prove_case committed 0 "$HERE/mirror.tsv" "$SRC" ""

    printf '%s of %s proof cases behaved as required\n' \
        "$passed" "$((passed + failed))"
    test "$failed" -eq 0 || exit 1
    exit 0
fi

test -f "$MAP" || { echo "mirror.sh: missing $MAP" >&2; exit 1; }
test -f "$LEDGER" || { echo "mirror.sh: missing $LEDGER" >&2; exit 1; }
test -f "$KOFUN_HALF" || { echo "mirror.sh: missing $KOFUN_HALF" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pair-mirror.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

strip() { grep -v '^#' "$1" | grep -v '^[[:space:]]*$'; }

strip "$LEDGER" | cut -f3 | sort >"$WORK/ledger.txt"
strip "$MAP" >"$WORK/map-rows.txt"
cut -f1 "$WORK/map-rows.txt" | sort >"$WORK/mapped.txt"
awk '/^fn [a-z_][A-Za-z0-9_]*\(/ { n = $2; sub(/\(.*/, "", n); print n }' \
    "$KOFUN_HALF" | sort -u >"$WORK/kofun-fns.txt"

test -s "$WORK/ledger.txt" || {
    echo "mirror.sh: read no functions out of $LEDGER." >&2
    exit 1
}
test -s "$WORK/kofun-fns.txt" || {
    echo "mirror.sh: read no function definitions out of the Kofun half." >&2
    echo "  Refusing to resolve counterparts against an empty set." >&2
    exit 1
}

bad=0
note() {
    if test "$bad" -eq 0; then
        echo "FAIL: pair mirror: tests/pair-coverage/mirror.tsv no longer" >&2
        echo "  describes the tree:" >&2
    fi
    printf '    %s\n' "$1" >&2
    bad=$((bad + 1))
}

while IFS= read -r name; do
    test -n "$name" || continue
    grep -qxF "$name" "$WORK/mapped.txt" ||
        note "$name is in the ledger and has no row. A function nobody gave a verdict is unread surface."
done <"$WORK/ledger.txt"

while IFS= read -r name; do
    test -n "$name" || continue
    grep -qxF "$name" "$WORK/ledger.txt" ||
        note "$name has a row and is not in the ledger. Remove it: the map describes the ledger, not the file."
done <"$WORK/mapped.txt"

duplicates=$(uniq -d "$WORK/mapped.txt")
test -z "$duplicates" || note "more than one row for: $duplicates"

same=0
other=0
conly=0
while IFS='	' read -r name verdict counterpart mark; do
    case $name in ''|'#'*) continue ;; esac
    case $verdict in
        same-name)
            test "$counterpart" = "$name" ||
                note "$name is same-name and column 3 says $counterpart"
            grep -qxF "$name" "$WORK/kofun-fns.txt" ||
                note "$name is same-name and compiler.kofun defines no such fn"
            same=$((same + 1))
            ;;
        other-name)
            test -n "$mark" ||
                note "$name is other-name with no mark. A verdict with no evidence is a guess."
            case $counterpart in
                "("*)
                    # Inlined, or a language builtin: there is no `fn` to find,
                    # and the mark is the whole of the evidence.
                    ;;
                *)
                    grep -qxF "$counterpart" "$WORK/kofun-fns.txt" ||
                        note "$name names counterpart $counterpart, which compiler.kofun does not define"
                    ;;
            esac
            other=$((other + 1))
            ;;
        c-only)
            test "$counterpart" = "-" ||
                note "$name is c-only and column 3 says $counterpart"
            test -n "$mark" ||
                note "$name is c-only with no mark. A verdict with no evidence is a guess."
            if grep -qxF "$name" "$WORK/kofun-fns.txt"; then
                note "$name is recorded c-only and compiler.kofun now defines it. Retire the row -- that is what the row was waiting for."
            fi
            conly=$((conly + 1))
            ;;
        *)
            note "$name carries verdict '$verdict', which is not one of same-name, other-name, c-only"
            ;;
    esac
done <"$WORK/map-rows.txt"

test "$bad" -eq 0 || exit 1

if test "${1:-}" = "--count"; then
    printf 'same-name\t%d\nother-name\t%d\nc-only\t%d\n' "$same" "$other" "$conly"
    exit 0
fi

# Reach, not only hits: the branch totals are what make the tallies mean
# something to someone deciding where to spend a region's reading.
conly_branches=$(awk -F'\t' '
NR == FNR { if ($0 !~ /^#/ && NF >= 3 && $2 == "c-only") conly[$1] = 1; next }
$0 ~ /^#/ { next }
NF >= 3 && ($3 in conly) { total += $1 }
END { print total + 0 }
' "$MAP" "$LEDGER")
all_branches=$(strip "$LEDGER" | awk -F'\t' '{ total += $1 } END { print total + 0 }')
mapped=$((same + other + conly))
printf 'PASS: %d of %d ledger functions carry a mirror verdict\n' \
    "$mapped" "$(grep -c . "$WORK/ledger.txt")"
printf '      %d same-name, %d other-name, %d C-only; the C-only rows hold %d of %d untaken branches\n' \
    "$same" "$other" "$conly" "$conly_branches" "$all_branches"
