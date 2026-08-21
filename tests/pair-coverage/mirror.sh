#!/bin/sh
# Does the map of "which ledger functions the Kofun half mirrors" still describe
# the tree? (#1514, parent #1401)
#
# `undefended.tsv` is #1401's work-list: per function of
# bootstrap/stage2/compiler.c, how many branches nothing takes. Its usefulness
# rests on both halves implementing the function, and for 24 of the 361 they do
# not -- while 67 more are mirrored under a different name, which is invisible
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
#   sh tests/pair-coverage/mirror.sh --prove     demonstrate it can refuse
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

case ${1:-} in
    ""|--count) test "$#" -le 1 || { echo "usage: mirror.sh [--count|--prove]" >&2; exit 2; } ;;
    --prove) test "$#" -eq 1 || { echo "usage: mirror.sh [--count|--prove]" >&2; exit 2; } ;;
    *) echo "usage: mirror.sh [--count|--prove]" >&2; exit 2 ;;
esac

# This is set only by the outer proof's extra-operand probe. It prevents a
# future accept-but-ignore arity regression from recursively starting complete
# proof suites until processes or temporary space are exhausted. The outer
# proof requires usage exit 2, so reaching this distinct exit still fails it.
if test "${KOFUN_PAIR_PROOF_OPERAND_PROBE:-0}" = 1; then
    echo "mirror.sh: operand probe reached proof setup" >&2
    exit 98
fi

if test "${1:-}" = "--prove"; then
    # Do not let `mktemp` choose what cleanup may delete. First establish an
    # invocation-owned private parent through mkdir's exclusive-create result;
    # cleanup is permanently scoped to that exact parent. The mktemp child is
    # useful scratch, but never deletion authority on its own.
    PROVE_PARENT_PREFIX=${TMPDIR:-/tmp}/kofun-pair-mirror-parent.$$.
    PROVE_PARENT=
    PROVE_PARENT_OWNED=0
    cleanup_prove() {
        if test "$PROVE_PARENT_OWNED" = 1; then
            case $PROVE_PARENT in
                "$PROVE_PARENT_PREFIX"[0-9]|"$PROVE_PARENT_PREFIX"[0-9][0-9])
                    PROVE_PARENT_OWNED=0
                    rm -rf "$PROVE_PARENT"
                    ;;
                *)
                    echo "mirror.sh: refusing to clean an unvalidated proof parent" >&2
                    ;;
            esac
        fi
    }
    prove_parent_attempt=0
    while test "$prove_parent_attempt" -lt 100; do
        prove_parent_candidate=$PROVE_PARENT_PREFIX$prove_parent_attempt
        if (umask 077 && mkdir "$prove_parent_candidate") 2>/dev/null; then
            PROVE_PARENT=$prove_parent_candidate
            PROVE_PARENT_OWNED=1
            break
        fi
        prove_parent_attempt=$((prove_parent_attempt + 1))
    done
    test "$PROVE_PARENT_OWNED" = 1 || {
        echo "mirror.sh: could not create private proof parent" >&2
        exit 1
    }
    trap cleanup_prove EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    PROVE_PREFIX=$PROVE_PARENT/proof.
    PROVE=$(mktemp -d "${PROVE_PREFIX}XXXXXX") || {
        echo "mirror.sh: could not create private proof scratch" >&2
        exit 1
    }
    case $PROVE in
        "$PROVE_PREFIX"*) PROVE_SUFFIX=${PROVE#"$PROVE_PREFIX"} ;;
        *)
            echo "mirror.sh: mktemp returned an unexpected proof path" >&2
            exit 1
            ;;
    esac
    case $PROVE_SUFFIX in
        ??????) ;;
        *)
            echo "mirror.sh: mktemp returned an unexpected proof suffix" >&2
            exit 1
            ;;
    esac
    case $PROVE_SUFFIX in
        */*)
            echo "mirror.sh: mktemp returned a non-child proof path" >&2
            exit 1
            ;;
    esac
    test -d "$PROVE" && test ! -L "$PROVE" || {
        echo "mirror.sh: mktemp did not return a proof directory" >&2
        exit 1
    }

    # This injection is scoped to the outer suite's first-write regression.
    # Stop at the first fixture mkdir rather than recursively starting another
    # full proof suite under the fake mkdir.
    if test "${KOFUN_PAIR_PROOF_FIRST_WRITE_PROBE:-0}" = 1; then
        mkdir "$PROVE/caller-owned"
        echo "mirror.sh: first-write probe unexpectedly succeeded" >&2
        exit 98
    fi

    # The public proof interface must never accept an existing caller-owned
    # directory. Keep the sentinel inside this invocation-owned scratch so the
    # regression itself remains harmless if the refusal is broken.
    mkdir "$PROVE/caller-owned"
    printf 'must survive\n' >"$PROVE/expected-sentinel"
    cp "$PROVE/expected-sentinel" "$PROVE/caller-owned/sentinel"
    operand_exit=0
    KOFUN_PAIR_PROOF_OPERAND_PROBE=1 sh "$0" --prove "$PROVE/caller-owned" \
        >"$PROVE/caller-operand.out" 2>"$PROVE/caller-operand.err" || operand_exit=$?
    if test "$operand_exit" -ne 2 ||
       ! cmp -s "$PROVE/expected-sentinel" "$PROVE/caller-owned/sentinel"; then
        echo "FAIL: pair mirror: --prove accepted or modified a caller-owned path" >&2
        exit 1
    fi
    printf '  prove caller-path-operand: refused and untouched\n'

    mkdir "$PROVE/fake-mktemp-fail"
    printf '%s\n' '#!/bin/sh' 'exit 73' >"$PROVE/fake-mktemp-fail/mktemp"
    chmod +x "$PROVE/fake-mktemp-fail/mktemp"
    setup_exit=0
    PATH="$PROVE/fake-mktemp-fail:$PATH" sh "$0" --prove \
        >"$PROVE/mktemp-fail.out" 2>"$PROVE/mktemp-fail.err" || setup_exit=$?
    test "$setup_exit" -eq 1 || {
        echo "FAIL: pair mirror: mktemp failure did not refuse" >&2
        exit 1
    }
    printf '  prove mktemp-failure: refused\n'

    mkdir "$PROVE/fake-mktemp-path" "$PROVE/attack-tmp"
    attack_victim=$PROVE/attack-tmp/kofun-pair-mirror-proof.ABCDEF
    mkdir "$attack_victim"
    cp "$PROVE/expected-sentinel" "$attack_victim/sentinel"
    printf '%s\n' '#!/bin/sh' \
        'printf "%s\n" "$KOFUN_FAKE_MKTEMP_RESULT"' \
        >"$PROVE/fake-mktemp-path/mktemp"
    chmod +x "$PROVE/fake-mktemp-path/mktemp"
    setup_exit=0
    KOFUN_FAKE_MKTEMP_RESULT="$attack_victim" \
    TMPDIR="$PROVE/attack-tmp" \
    PATH="$PROVE/fake-mktemp-path:$PATH" sh "$0" --prove \
        >"$PROVE/mktemp-path.out" 2>"$PROVE/mktemp-path.err" || setup_exit=$?
    if test "$setup_exit" -ne 1 ||
       ! test -d "$attack_victim" ||
       ! cmp -s "$PROVE/expected-sentinel" "$attack_victim/sentinel" ||
       test -e "$attack_victim/caller-owned"; then
        echo "FAIL: pair mirror: existing mktemp path was accepted or cleaned" >&2
        exit 1
    fi
    printf '  prove existing-mktemp-path: refused and untouched\n'

    mkdir "$PROVE/fake-mktemp-slash" "$PROVE/slash-tmp"
    cp "$PROVE/expected-sentinel" "$PROVE/slash-tmp/sentinel"
    printf '%s\n' '#!/bin/sh' \
        'for arg do template=$arg; done' \
        'prefix=${template%XXXXXX}' \
        'mkdir "$prefix" || exit 76' \
        'printf "%s/../..\n" "$prefix"' \
        >"$PROVE/fake-mktemp-slash/mktemp"
    chmod +x "$PROVE/fake-mktemp-slash/mktemp"
    setup_exit=0
    TMPDIR="$PROVE/slash-tmp" PATH="$PROVE/fake-mktemp-slash:$PATH" \
        sh "$0" --prove >"$PROVE/mktemp-slash.out" \
        2>"$PROVE/mktemp-slash.err" || setup_exit=$?
    if test "$setup_exit" -ne 1 ||
       ! cmp -s "$PROVE/expected-sentinel" "$PROVE/slash-tmp/sentinel" ||
       test -e "$PROVE/slash-tmp/caller-owned"; then
        echo "FAIL: pair mirror: slash-suffix mktemp path was accepted" >&2
        exit 1
    fi
    printf '  prove mktemp-slash-suffix: refused and untouched\n'

    mkdir "$PROVE/fake-mktemp-symlink" "$PROVE/symlink-victim"
    cp "$PROVE/expected-sentinel" "$PROVE/symlink-victim/sentinel"
    printf '%s\n' '#!/bin/sh' \
        'for arg do result=$arg; done' \
        'result=${result%XXXXXX}ABCDEF' \
        'ln -s "$KOFUN_FAKE_MKTEMP_TARGET" "$result" || exit 75' \
        'printf "%s\n" "$result"' \
        >"$PROVE/fake-mktemp-symlink/mktemp"
    chmod +x "$PROVE/fake-mktemp-symlink/mktemp"
    setup_exit=0
    KOFUN_FAKE_MKTEMP_TARGET="$PROVE/symlink-victim" \
    PATH="$PROVE/fake-mktemp-symlink:$PATH" sh "$0" --prove \
        >"$PROVE/mktemp-symlink.out" 2>"$PROVE/mktemp-symlink.err" || setup_exit=$?
    if test "$setup_exit" -ne 1 ||
       ! cmp -s "$PROVE/expected-sentinel" "$PROVE/symlink-victim/sentinel" ||
       test -e "$PROVE/symlink-victim/caller-owned"; then
        echo "FAIL: pair mirror: mktemp symlink was accepted or followed" >&2
        exit 1
    fi
    printf '  prove mktemp-symlink: refused and untouched\n'

    mkdir "$PROVE/fake-first-write" "$PROVE/child-tmp"
    KOFUN_PAIR_REAL_MKDIR=$(command -v mkdir)
    export KOFUN_PAIR_REAL_MKDIR
    printf '%s\n' '#!/bin/sh' \
        'case ${1##*/} in' \
        '    kofun-pair-mirror-parent.*) exec "$KOFUN_PAIR_REAL_MKDIR" "$@" ;;' \
        '    *) exit 74 ;;' \
        'esac' >"$PROVE/fake-first-write/mkdir"
    chmod +x "$PROVE/fake-first-write/mkdir"
    setup_exit=0
    KOFUN_PAIR_PROOF_FIRST_WRITE_PROBE=1 TMPDIR="$PROVE/child-tmp" \
    PATH="$PROVE/fake-first-write:$PATH" \
        sh "$0" --prove >"$PROVE/first-write.out" \
        2>"$PROVE/first-write.err" || setup_exit=$?
    first_write_leak=$(find "$PROVE/child-tmp" -mindepth 1 -print -quit)
    if test "$setup_exit" -ne 74 || test -n "$first_write_leak"; then
        printf 'FAIL: pair mirror: first proof write exit %s; leftover %s\n' \
            "$setup_exit" "${first_write_leak:-none}" >&2
        exit 1
    fi
    printf '  prove first-write-failure: refused and cleaned\n'

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
    #
    #    The name here must be one the Kofun half is not about to gain. This
    #    case used to append `ends_with`, and #1508 then wrote that function --
    #    so the proof started passing where it should have refused, and this
    #    harness caught its own stale assumption. `buffer_format` is the durable
    #    choice: it is varargs formatting into a growable buffer, and the
    #    bootstrap subset has neither `va_list` nor a `Buffer` type.
    cp "$SRC" "$PROVE/now-mirrored.kofun"
    printf '\nfn buffer_format(target: Text, value: Text) -> Text {\n    return target + value\n}\n' \
        >>"$PROVE/now-mirrored.kofun"
    prove_case now-mirrored 1 "$HERE/mirror.tsv" "$PROVE/now-mirrored.kofun" \
        buffer_format

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
