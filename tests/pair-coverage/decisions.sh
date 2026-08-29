#!/bin/sh
# Do both halves of the Stage 2 pair still spell the same DECISIONS? (#1584,
# parent #1401, third sibling of `calls.sh` and `mirror.sh`)
#
# `bootstrap/stage2/compiler.kofun` and `bootstrap/stage2/compiler.c` are the
# same program written twice. Six defects in one week were neither behaviour nor
# control flow but a constant, a set, a table size or a declared arity that the
# two halves spell separately and that nothing compared. The ledger beside this
# file names each such decision, its site in each half, and how many times that
# site must occur; this gate reads both files and refuses a disagreement.
#
#   sh tests/pair-coverage/decisions.sh             check the ledger
#   sh tests/pair-coverage/decisions.sh --count     print the current counts
#   sh tests/pair-coverage/decisions.sh --prove     demonstrate it can refuse
#
# WHAT IT DOES NOT COVER, stated because a partial check read as a total one is
# worse than none -- and because `calls.sh` stating its own boundary is what
# made #1571 findable as a scope cost rather than a surprise:
#
#   - COMPLETENESS. Seven rows is the six known defects plus one adjacent slot.
#     Nothing here enumerates the decisions the two halves spell; a decision
#     with no row is invisible exactly as it was before this gate existed. Rows
#     are added as pairs are found, and this file cannot tell you how many are
#     left.
#   - WHETHER A ROW'S TWO SITES ARE ACTUALLY THE SAME DECISION. That is the
#     human judgement in the `note` column. The gate checks that both sites
#     still occur the pinned number of times; it cannot check that they mean
#     each other.
#   - VALUES THAT AGREE FOR THE WRONG REASON. A row pins occurrences, not
#     semantics. Two halves can both be wrong in step, and this passes.
#   - EXECUTION. Nothing here runs the Kofun half; that is #1483's territory and
#     this gate exists precisely because the half is not executed.
#   - call targets and their arity (`calls.sh`), name introduction
#     (`bindings.sh`), and function counterparts (`mirror.sh`). This is the
#     third member of that family, not a supersession of any of them.
#
# THE LEDGER IS A PIN AND MUST BE RE-PINNED DELIBERATELY. A real edit to either
# half fails this gate until its rows are updated, exactly as `inputs.tsv` and
# `mirror.tsv` do. `--count` prints the current numbers for that purpose. An
# artifact that silently followed the tree would stop being a record of what was
# checked, which is the whole reason these ledgers are committed.
#
# THIS HARNESS IS SHELL, AND THAT IS RECORDED DEBT, like its three neighbours: it
# carries a `shell-build-driver` row in `tooling/forbidden-requirements/census.tsv`.
set -u

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)

# Seams, announced on use. A gate that silently read a file other than the
# committed one would be checking something nobody is looking at.
LEDGER=${KOFUN_PAIR_DECISIONS_LEDGER:-"$ROOT/tests/pair-coverage/decisions.tsv"}
KOFUN_HALF=${KOFUN_PAIR_DECISIONS_KOFUN:-"$ROOT/bootstrap/stage2/compiler.kofun"}
C_HALF=${KOFUN_PAIR_DECISIONS_C:-"$ROOT/bootstrap/stage2/compiler.c"}

for seam_pair in \
    "$LEDGER:$ROOT/tests/pair-coverage/decisions.tsv" \
    "$KOFUN_HALF:$ROOT/bootstrap/stage2/compiler.kofun" \
    "$C_HALF:$ROOT/bootstrap/stage2/compiler.c"
do
    seam_now=${seam_pair%%:*}
    seam_default=${seam_pair#*:}
    if test "$seam_now" != "$seam_default"; then
        printf 'NOTE: pair decisions: reading %s, not the committed file.\n' \
            "$seam_now" >&2
    fi
done

TAB=$(printf '\t')
failures=0

refuse() {
    printf 'FAIL: pair decisions: %s\n' "$1" >&2
    failures=$((failures + 1))
}

# Occurrences, not matching lines: a token twice on one line is two. `--` so a
# token that begins with a dash is data rather than an option.
occurrences() {
    grep -o -F -- "$2" "$1" 2>/dev/null | wc -l | tr -d ' '
}

if test "${1:-}" = "--prove"; then
    PROVE=${2:-$(mktemp -d "${TMPDIR:-/tmp}/kofun-pair-decisions.XXXXXX")}
    mkdir -p "$PROVE"
    proved=0
    refused=0

    # The must-not-fire case is FIRST and is not decoration. Every case below
    # refuses; a version of this gate that refused unconditionally would satisfy
    # all of them and be useless. A rule with a false-positive shape has two
    # properties and testing only the one it is named for leaves the other
    # unproved.
    proved=$((proved + 1))
    if sh "$0" >"$PROVE/clean.out" 2>&1; then
        refused=$((refused + 1))
        printf 'PASS [decisions-accepts] clean-tree, as it must\n'
    else
        printf 'FAIL: prove clean-tree: the committed ledger does not pass:\n' >&2
        sed 's/^/      /' "$PROVE/clean.out" >&2
    fi

    # Each case must fail FOR ITS OWN REASON, so the needle is the row id or the
    # exact malformation, never merely a non-zero exit.
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
            refused=$((refused + 1))
            printf 'PASS [decisions-refuses] %s\n' "$case_name"
            return
        fi
        printf 'FAIL: prove %s: refused, but never named it — expected %s\n' \
            "$case_name" "$case_needle" >&2
        sed 's/^/      /' "$PROVE/$case_name.out" >&2
    }

    # A site that stopped existing, in each half in turn. This is the case line
    # numbers cannot have: a moved anchor is loud here and silent there.
    sed 's/is_xid_start/is_xid_absent/g' "$KOFUN_HALF" >"$PROVE/kofun-gone.kofun"
    prove kofun-site-gone 'The site is gone' \
        "KOFUN_PAIR_DECISIONS_KOFUN=$PROVE/kofun-gone.kofun"

    sed 's/sh.len_list_symbol = sh.next_symbol++;/sh.len_list_symbol = 0;/' \
        "$C_HALF" >"$PROVE/c-gone.c"
    prove c-site-gone 'selfhost-len-list-builtin-slot' \
        "KOFUN_PAIR_DECISIONS_C=$PROVE/c-gone.c"

    # And a count that CHANGED rather than vanished, which is the shape every one
    # of the six defects actually had: the site is still there, in fewer or more
    # places than the other half decides.
    awk '{ print } /symbol = count \+ 16/ { print }' "$KOFUN_HALF" \
        >"$PROVE/kofun-doubled.kofun"
    prove kofun-count-changed 'the ledger says 1' \
        "KOFUN_PAIR_DECISIONS_KOFUN=$PROVE/kofun-doubled.kofun"

    # Drop the FIRST occurrence only, leaving the others in place. This is
    # #1570's exact shape and the reason a row pins a count rather than testing
    # presence: `List[Int]` stayed in the annotation list and went missing from
    # the dispatch exclusion sixty lines on, so a presence test passes on the
    # defective file and this does not.
    drop_first() {
        awk -v tok="$1" 'BEGIN { dropped = 0 }
            !dropped && index($0, tok) { dropped = 1; next }
            { print }' "$2" >"$3"
    }
    drop_first 'binding_type != "List[Int]"' "$KOFUN_HALF" \
        "$PROVE/kofun-one-fewer.kofun"
    prove kofun-one-site-of-three 'annotated-binding-list-int-exclusion' \
        "KOFUN_PAIR_DECISIONS_KOFUN=$PROVE/kofun-one-fewer.kofun"

    # The same shape on the C side, and on the row whose two halves spell the
    # SAME token with different counts — the case a shared-count rule would have
    # got wrong, so it is worth proving separately from the others.
    drop_first 'parameter_count(source, declaration)' "$C_HALF" \
        "$PROVE/c-one-fewer.c"
    prove c-one-site-of-five 'declared-parameter-walk' \
        "KOFUN_PAIR_DECISIONS_C=$PROVE/c-one-fewer.c"

    # Ledger malformations. Each is a way a row could look official and check
    # nothing, which is the failure mode `inert-claim` records for claims.
    awk -F'\t' 'BEGIN { OFS = "\t" }
        /^#/ { print; next }
        NF == 6 && ++seen == 1 { $2 = 0 } { print }' \
        "$LEDGER" >"$PROVE/zero-pin.tsv"
    prove zero-pin 'a paired decision has a site in both halves' \
        "KOFUN_PAIR_DECISIONS_LEDGER=$PROVE/zero-pin.tsv"

    { cat "$LEDGER"; grep -v '^#' "$LEDGER" | grep . | sed -n '1p'; } \
        >"$PROVE/duplicate.tsv"
    prove duplicate-id 'occurs more than once' \
        "KOFUN_PAIR_DECISIONS_LEDGER=$PROVE/duplicate.tsv"

    awk -F'\t' 'BEGIN { OFS = "\t" }
        /^#/ { print; next }
        NF == 6 && ++seen == 1 { print $1, $2, $3, $4, $5; next } { print }' \
        "$LEDGER" >"$PROVE/malformed.tsv"
    prove malformed-row 'is malformed' \
        "KOFUN_PAIR_DECISIONS_LEDGER=$PROVE/malformed.tsv"

    grep '^#' "$LEDGER" >"$PROVE/empty.tsv"
    prove empty-ledger 'carries no rows' \
        "KOFUN_PAIR_DECISIONS_LEDGER=$PROVE/empty.tsv"

    printf '%s of %s cases behaved as required\n' "$refused" "$proved"
    test "$refused" -eq "$proved" || exit 1
    exit 0
fi

for required in "$LEDGER" "$KOFUN_HALF" "$C_HALF"
do
    if ! test -s "$required"; then
        printf 'FAIL: pair decisions: %s is missing or empty\n' "$required" >&2
        exit 1
    fi
done

rows=$(grep -v '^#' "$LEDGER" | grep -c . || true)
# An empty ledger and a ledger the reader could not parse look identical from
# here, so refusing is the only honest answer to either.
if test "$rows" -eq 0; then
    printf 'FAIL: pair decisions: %s carries no rows. An empty ledger and a\n' \
        "$LEDGER" >&2
    printf '      ledger nothing could read are the same picture from here.\n' >&2
    exit 1
fi

mode=${1:-check}
seen_ids=""
checked=0
sites=0

while IFS= read -r row_line
do
    case "$row_line" in ''|'#'*) continue ;; esac

    # The field count is measured, not inferred from an empty variable: `read`
    # assigns a short row's fields to the wrong names and leaves only the LAST
    # one empty, so a five-field row reads as a six-field row with no note and
    # checks the wrong two things quietly.
    field_count=$(printf '%s\n' "$row_line" | awk -F"$TAB" '{ print NF }')
    id=$(printf '%s\n' "$row_line" | cut -f1)
    if test "$field_count" -ne 6; then
        refuse "row '$id' is malformed: $field_count tab-separated field(s), expected 6"
        continue
    fi
    kofun_count=$(printf '%s\n' "$row_line" | cut -f2)
    kofun_token=$(printf '%s\n' "$row_line" | cut -f3)
    c_count=$(printf '%s\n' "$row_line" | cut -f4)
    c_token=$(printf '%s\n' "$row_line" | cut -f5)
    case " $seen_ids " in
        *" $id "*) refuse "row id '$id' occurs more than once" ; continue ;;
    esac
    seen_ids="$seen_ids $id"

    for pin_pair in "kofun:$kofun_count" "c:$c_count"
    do
        pin_half=${pin_pair%%:*}
        pin_value=${pin_pair#*:}
        case "$pin_value" in
            ''|*[!0-9]*)
                refuse "row '$id' pins a non-numeric $pin_half count '$pin_value'"
                continue 2 ;;
        esac
        # Zero is refused rather than allowed. A paired decision has a site in
        # both halves by definition, and a row pinned at 0 could never fail when
        # its site vanished -- which is the failure this whole family exists to
        # remove.
        if test "$pin_value" -eq 0; then
            refuse "row '$id' pins the $pin_half half at 0; a paired decision has a site in both halves"
            continue 2
        fi
    done

    actual_kofun=$(occurrences "$KOFUN_HALF" "$kofun_token")
    actual_c=$(occurrences "$C_HALF" "$c_token")
    checked=$((checked + 1))
    sites=$((sites + 2))

    if test "$actual_kofun" -ne "$kofun_count"; then
        refuse "row '$id': the Kofun half spells its site $actual_kofun time(s), the ledger says $kofun_count"
        printf '      token: %s\n' "$kofun_token" >&2
        if test "$actual_kofun" -eq 0; then
            printf '      The site is gone, not merely changed. Re-anchor the row or retire it.\n' >&2
        fi
    fi
    if test "$actual_c" -ne "$c_count"; then
        refuse "row '$id': the C half spells its site $actual_c time(s), the ledger says $c_count"
        printf '      token: %s\n' "$c_token" >&2
        if test "$actual_c" -eq 0; then
            printf '      The site is gone, not merely changed. Re-anchor the row or retire it.\n' >&2
        fi
    fi

    if test "$mode" = "--count"; then
        printf '%s\t%s\t%s\n' "$id" "$actual_kofun" "$actual_c"
    fi
done <<LEDGER_ROWS
$(grep -v '^#' "$LEDGER" | grep .)
LEDGER_ROWS

if test "$mode" = "--count"; then
    printf '# %s row(s), current occurrence counts as id/kofun/c\n' "$checked"
fi

if test "$failures" -eq 0; then
    printf 'PASS: %s paired decision(s) agree across both halves, %s sites read\n' \
        "$checked" "$sites"
    exit 0
fi
printf '\n%s disagreement(s). Print the current numbers with: sh %s --count\n' \
    "$failures" "tests/pair-coverage/decisions.sh" >&2
exit 1
