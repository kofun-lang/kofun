#!/bin/sh
# Does every name READ in `bootstrap/stage2/compiler.kofun` resolve to something
# the file introduces? (#1622, parent #1401, sibling of `calls.sh`)
#
# WHY THIS GATE EXISTS, AND WHY `calls.sh` IS NOT IT. Its neighbour resolves
# every CALL target in the Kofun half and says so in its own header: "only
# lowercase-initial call targets are read, which is what `fn` names and builtins
# are". A bare read is not a call. Nothing else covers it either --
# `bootstrap/stage2/check.sh` round-trips the file and byte-compares the
# identity projection, which resolves no names, and the gates that compare the
# halves (`selfhost-generations`, `selfhost-fixed-point`) compare EMITTED C,
# which only the C half emits.
#
# WHAT IT FOUND ON THE DAY IT LANDED, which is why it is not a gate asserting a
# property it cannot fail on:
#
#   lambda_scope   compiler.kofun:13541 and :13556, inside `build_scope_hir_mode`.
#                  The lambda-parameter walk wrote each parameter into the
#                  lambda-parameters scope emitted by the pass above it, and
#                  addressed that scope by a name the file never bound. The C
#                  half opens the same walk with
#                  `hir_scope_id_for_open(hir.data, lambda_open)`.
#
# It survived because the only thing in this repository that resolves a name in
# this file -- `kofun-stage2 --compile-outcome` -- refuses 12,635 lines earlier,
# at line 906, on `E2S35: lexical use limit is 256 per function` (#1483). The
# fix is PR #1621; the ledger beside this file is empty because of it, and
# `--prove` uses that tree's parent as a fixture rather than an invented one.
#
# THE INTRODUCTION FORMS ARE THREE, AND THAT IS MEASURED, NOT ASSUMED.
# `compiler.kofun` has no `for` binding, no `match` arm, and no lambda
# parameter: its 16 `=>` occurrences are all inside string literals or `!=`
# comparisons, and its 52 `match` hits are identifiers like `internal_match` and
# prose in comments. So `fn` names, `fn` parameters, and `let` / `let mut` are
# the whole set, which is why the whole-file question below is answerable
# without lexical scoping. If a fourth form appears, this gate reports its
# bindings as unresolved reads rather than resolving them quietly.
#
#   sh tests/pair-coverage/bindings.sh             check the ledger
#   sh tests/pair-coverage/bindings.sh --count     print current unresolved reads
#   sh tests/pair-coverage/bindings.sh --prove     demonstrate it can refuse
#
# WHAT IT DOES NOT COVER, stated because a partial check read as a total one is
# worse than none:
#   - WHETHER A NAME IS IN SCOPE AT THAT POINT. This asks the weaker whole-file
#     question: is it introduced anywhere? A `let` in one function does resolve
#     a read in another. Lexical scoping is the compiler's job and #1483's; this
#     catches the class the compiler cannot reach, which is a name nothing binds
#     at all.
#   - types and constructors, which are uppercase-initial and are skipped.
#   - field and method reads (`x.name`), which name no local binding.
#   - call targets, which `calls.sh` owns, and their arity, which it also owns.
#   - a binding nothing reads. That is the reverse direction and belongs to a
#     different check.
#   - the C half, whose reads the C compiler resolves on every build, which is
#     exactly the asymmetry this gate narrows.
#
# THIS HARNESS IS SHELL, AND THAT IS RECORDED DEBT, like its four neighbours: it
# carries a `shell-build-driver` row in
# `tooling/forbidden-requirements/census.tsv`, which re-derives from the tree and
# fails in both directions. RFC-0018's direction is that this becomes Kofun;
# #1451 owns that work and #1499 owns the missing piece it needs.
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/pair-coverage"

# The three seams, each ANNOUNCING itself on use: a gate silently reading a file
# other than the committed one reports on something nobody is looking at.
KOFUN_HALF=${KOFUN_PAIR_BINDINGS_SOURCE:-$ROOT/bootstrap/stage2/compiler.kofun}
LEDGER=${KOFUN_PAIR_BINDINGS_LEDGER:-$HERE/unresolved-reads.tsv}
C_HALF=${KOFUN_PAIR_BINDINGS_C_HALF:-$ROOT/bootstrap/stage2/compiler.c}
if test "$KOFUN_HALF" != "$ROOT/bootstrap/stage2/compiler.kofun"; then
    printf 'NOTE: pair bindings: reading %s, not the tree Kofun half.\n' \
        "$KOFUN_HALF" >&2
fi
if test "$LEDGER" != "$HERE/unresolved-reads.tsv"; then
    printf 'NOTE: pair bindings: checking %s, not the committed ledger.\n' \
        "$LEDGER" >&2
fi
if test "$C_HALF" != "$ROOT/bootstrap/stage2/compiler.c"; then
    printf 'NOTE: pair bindings: resolving against %s, not the tree C half.\n' \
        "$C_HALF" >&2
fi

case ${1:-} in
    ""|--count) test "$#" -le 1 || {
        echo "usage: bindings.sh [--count|--prove]" >&2; exit 2; } ;;
    --prove) test "$#" -eq 1 || {
        echo "usage: bindings.sh [--count|--prove]" >&2; exit 2; } ;;
    *) echo "usage: bindings.sh [--count|--prove]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# The proof. A gate nobody has watched fail is not evidence, and this one is
# green on the tree it ships with, so "it passes" says nothing on its own. Each
# case mutates a COPY, runs this same script through the seams above, and
# requires the refusal to NAME the thing it was given. Requiring the name is the
# part that matters: a proof that only asserted "it failed" would pass on a gate
# that failed for an unrelated reason.
# ---------------------------------------------------------------------------
if test "${1:-}" = "--prove"; then
    PROVE=$(mktemp -d "${TMPDIR:-/tmp}/pair-bindings-prove.XXXXXX") || {
        echo "bindings.sh: could not create private proof scratch" >&2
        exit 1
    }
    test -d "$PROVE" && test ! -L "$PROVE" || {
        echo "bindings.sh: mktemp did not return a proof directory" >&2
        exit 1
    }
    cleanup_prove() { rm -rf "$PROVE"; }
    trap cleanup_prove EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    passed=0
    failed=0

    # prove_case NAME WANT_STATUS SOURCE LEDGER C_HALF WANT_TEXT
    prove_case() {
        pc_name=$1
        pc_want=$2
        pc_src=$3
        pc_ledger=$4
        pc_c=$5
        pc_text=$6
        set +e
        KOFUN_PAIR_BINDINGS_SOURCE=$pc_src \
        KOFUN_PAIR_BINDINGS_LEDGER=$pc_ledger \
        KOFUN_PAIR_BINDINGS_C_HALF=$pc_c \
            sh "$HERE/bindings.sh" >"$PROVE/$pc_name.out" 2>&1
        pc_got=$?
        set -e
        if test "$pc_got" -ne "$pc_want"; then
            printf 'FAIL: proof case %s exited %s, wanted %s\n' \
                "$pc_name" "$pc_got" "$pc_want" >&2
            sed 's/^/      /' "$PROVE/$pc_name.out" >&2
            failed=$((failed + 1))
            return 0
        fi
        if test -n "$pc_text" && ! grep -qF -- "$pc_text" "$PROVE/$pc_name.out"
        then
            printf 'FAIL: proof case %s did not name %s\n' \
                "$pc_name" "$pc_text" >&2
            sed 's/^/      /' "$PROVE/$pc_name.out" >&2
            failed=$((failed + 1))
            return 0
        fi
        passed=$((passed + 1))
    }

    : >"$PROVE/empty-ledger.tsv"

    # 1. The tree as committed passes. Without this the cases below could all be
    # failing for a reason that has nothing to do with what they inject.
    prove_case baseline 0 "$KOFUN_HALF" "$LEDGER" "$C_HALF" ""

    # 2. THE DEFECT THIS GATE WAS FILED FOR. A read of a name the file never
    # binds must be refused and named.
    cp "$KOFUN_HALF" "$PROVE/unbound.kofun"
    printf 'fn prove_unbound_zz() -> Text {\n    return prove_absent_zz\n}\n' \
        >>"$PROVE/unbound.kofun"
    prove_case unbound 1 "$PROVE/unbound.kofun" "$PROVE/empty-ledger.tsv" \
        "$C_HALF" "prove_absent_zz"

    # 3. THE REPORTED LINE IS THE REAL LINE. This case exists because the
    # first version of this gate was off by 44 on every line it printed: the
    # classifier reads two files and used awk's `NR`, which is cumulative
    # across them, so the offset was the size of the derived keyword set and
    # would have moved whenever the C half's table did. A wrong line number
    # looks exactly like a right one.
    prove_line=$(grep -n 'prove_absent_zz' "$PROVE/unbound.kofun" | \
        head -1 | cut -d: -f1)
    prove_case reported-line 1 "$PROVE/unbound.kofun" \
        "$PROVE/empty-ledger.tsv" "$C_HALF" \
        "prove_absent_zz	unbound.kofun:$prove_line"

    # 4. The ledger is exact in both directions. A row whose read now resolves
    # is an improvement nobody recorded, and it must fail rather than be
    # ignored.
    printf 'prove_stale_zz\tinvented\tno such read exists in the tree\n' \
        >"$PROVE/stale-ledger.tsv"
    prove_case stale-ledger 1 "$KOFUN_HALF" "$PROVE/stale-ledger.tsv" \
        "$C_HALF" "prove_stale_zz"

    # 5. A recorded read is tolerated, which is what makes 4 a real direction
    # rather than "any ledger content fails".
    cp "$PROVE/unbound.kofun" "$PROVE/recorded.kofun"
    printf 'prove_absent_zz\tproof-fixture\tinjected by --prove\n' \
        >"$PROVE/recorded-ledger.tsv"
    prove_case recorded 0 "$PROVE/recorded.kofun" \
        "$PROVE/recorded-ledger.tsv" "$C_HALF" ""

    # 6. The distinction between this gate and a naive pattern: the file carries
    # the whole emitted C runtime as string literals, and names inside a string
    # or a comment are not reads.
    cp "$KOFUN_HALF" "$PROVE/in-string.kofun"
    printf 'fn prove_text_zz() -> Text {\n    return "prove_absent_zz"\n}\n' \
        >>"$PROVE/in-string.kofun"
    prove_case in-string 0 "$PROVE/in-string.kofun" "$PROVE/empty-ledger.tsv" \
        "$C_HALF" ""

    cp "$KOFUN_HALF" "$PROVE/in-comment.kofun"
    printf '# prove_absent_zz named in a comment is not a read\n' \
        >>"$PROVE/in-comment.kofun"
    prove_case in-comment 0 "$PROVE/in-comment.kofun" \
        "$PROVE/empty-ledger.tsv" "$C_HALF" ""

    # 7. A call target is not a read: `calls.sh` owns those, and reporting them
    # here would make one defect two findings in two ledgers.
    cp "$KOFUN_HALF" "$PROVE/call-only.kofun"
    printf 'fn prove_call_zz() -> Int {\n    return prove_absent_zz(1)\n}\n' \
        >>"$PROVE/call-only.kofun"
    prove_case call-only 0 "$PROVE/call-only.kofun" \
        "$PROVE/empty-ledger.tsv" "$C_HALF" ""

    # 8. The assumption behind the scanner: a Kofun string does not span a line.
    # If that stops holding the gate must say so rather than count what it
    # guessed.
    cp "$KOFUN_HALF" "$PROVE/unterminated.kofun"
    printf 'fn prove_unterminated_zz() -> Text {\n    return "never closed\n}\n' \
        >>"$PROVE/unterminated.kofun"
    prove_case unterminated 1 "$PROVE/unterminated.kofun" "$LEDGER" \
        "$C_HALF" "ends inside a string literal"

    # 9. The keyword set is DERIVED from the C half, so a table that moves must
    # make this gate FAIL. Resolving nothing would report `mut` and every
    # keyword-adjacent name as unresolved; resolving nothing quietly is the
    # failure that looks like a result.
    sed 's/^static bool keyword_token(/static bool keyword_token_moved(/' \
        "$C_HALF" >"$PROVE/moved-table.c"
    prove_case moved-table 1 "$KOFUN_HALF" "$LEDGER" "$PROVE/moved-table.c" \
        "read no keywords"

    printf '%s of %s proof cases behaved as required\n' \
        "$passed" "$((passed + failed))"
    test "$failed" -eq 0 || exit 1
    exit 0
fi

test -f "$KOFUN_HALF" || { echo "bindings.sh: missing $KOFUN_HALF" >&2; exit 1; }
test -f "$C_HALF" || { echo "bindings.sh: missing $C_HALF" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pair-bindings.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# Strip strings and comments, keeping line numbers. Same character loop as
# `calls.sh`, and for the same reason: this file carries the emitted C runtime
# as string literals, so any pattern that does not know where a string ends
# reports findings that are all artefacts of its own scanner.
# ---------------------------------------------------------------------------
awk '
{
    line = $0
    out = ""
    in_string = 0
    i = 1
    n = length(line)
    while (i <= n) {
        ch = substr(line, i, 1)
        if (in_string) {
            if (ch == "\\") { i += 2; continue }
            if (ch == "\"") { in_string = 0 }
            i++
            continue
        }
        if (ch == "\"") { in_string = 1; i++; continue }
        if (ch == "#") break
        out = out ch
        i++
    }
    if (in_string) {
        printf "bindings.sh: line %d ends inside a string literal.\n", NR \
            > "/dev/stderr"
        printf "  This scanner assumes a Kofun string does not span a line;\n" \
            > "/dev/stderr"
        printf "  refusing to report counts taken under an assumption that\n" \
            > "/dev/stderr"
        printf "  just stopped holding.\n" > "/dev/stderr"
        bad = 1
    }
    print out
}
END { if (bad) exit 1 }
' "$KOFUN_HALF" >"$WORK/code.txt"

require_nonempty() {
    test -s "$2" || {
        printf 'bindings.sh: read no %s out of the C half.\n' "$1" >&2
        printf '  The table it comes from moved or was renamed. Refusing to\n' >&2
        printf '  classify names against a set the tree does not have.\n' >&2
        exit 1
    }
}

# `keyword_token`'s table, read out of the C half at run time and never restated
# here. It is load-bearing twice over: `let` and `mut` are what make a `let mut
# name` introduction distinguishable from a read, so a gate that lost this table
# would misread every mutable binding in the file.
awk '
/^static bool keyword_token\(/ { inside = 1; next }
inside && /^}/ { inside = 0 }
inside && /"/ {
    line = $0
    while (match(line, /"[a-z_][A-Za-z0-9_]*"/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
    }
}
' "$C_HALF" | sort -u >"$WORK/keywords.txt"
require_nonempty "keywords" "$WORK/keywords.txt"

# `builtin_arity` and `int_bit_method_arity`: names the language supplies. They
# are almost always call targets and so never reach the read classification, but
# a bare one must resolve rather than be reported.
awk '
/^static int64_t builtin_arity\(/ { inside = 1; next }
inside && /^}/ { inside = 0 }
inside && /\{"/ {
    line = $0
    while (match(line, /\{"[a-z_][A-Za-z0-9_]*"/)) {
        print substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, RSTART + RLENGTH)
    }
}
' "$C_HALF" | sort -u >"$WORK/builtins.txt"
require_nonempty "builtin names" "$WORK/builtins.txt"

sort -u "$WORK/keywords.txt" "$WORK/builtins.txt" >"$WORK/language.txt"

# ---------------------------------------------------------------------------
# One pass over the stripped code, classifying every lowercase-initial
# identifier as a declaration, a read, or neither.
#
# The classification is deferred until the next non-space character is known,
# because that character is what separates a call from a read and a parameter
# from a use, and it may be on a later line -- `fn` parameter lists in this file
# routinely span six.
# ---------------------------------------------------------------------------
awk '
FILENAME == ARGV[1] { language[$1] = 1; next }

function finalize(name, line) {
    prev2 = prev1
    prev1 = name
}

function classify(name, line, nextch) {
    if (name in language) { finalize(name, line); return }
    if (prev1 == ".") { finalize(name, line); return }
    if (nextch == "(") {
        if (prev1 == "fn") { print "decl\t" name; want_params = 1 }
        finalize(name, line)
        return
    }
    if (prev1 == "fn" || prev1 == "let" ||
        (prev1 == "mut" && prev2 == "let")) {
        print "decl\t" name
        finalize(name, line)
        return
    }
    if (in_params == 1 && paren_depth == 1 && nextch == ":") {
        print "decl\t" name
        finalize(name, line)
        return
    }
    if (prev1 == ":" || prev1 == ">") { finalize(name, line); return }
    if (name ~ /^[A-Z]/) { finalize(name, line); return }
    print "read\t" name "\t" line
    finalize(name, line)
}

{
    line = $0
    n = length(line)
    i = 1
    while (i <= n) {
        ch = substr(line, i, 1)
        if (ch == " " || ch == "\t") { i++; continue }
        if (ch ~ /[A-Za-z_]/) {
            j = i
            while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_]/) j++
            name = substr(line, i, j - i)
            if (pending != "") {
                classify(pending, pending_line, substr(line, i, 1))
                pending = ""
            }
            pending = name
            pending_line = FNR
            i = j
            continue
        }
        if (pending != "") {
            classify(pending, pending_line, ch)
            pending = ""
        }
        if (ch == "(") {
            if (want_params == 1) { in_params = 1; want_params = 0 }
            if (in_params == 1) paren_depth++
        } else if (ch == ")") {
            if (in_params == 1) {
                paren_depth--
                if (paren_depth <= 0) { in_params = 0; paren_depth = 0 }
            }
        }
        prev2 = prev1
        prev1 = ch
        i++
    }
}
END {
    if (pending != "") classify(pending, pending_line, "")
}
' "$WORK/language.txt" "$WORK/code.txt" >"$WORK/classified.tsv"

awk -F'\t' '$1 == "decl" { print $2 }' "$WORK/classified.tsv" | sort -u \
    >"$WORK/introduced.txt"
test -s "$WORK/introduced.txt" || {
    echo "bindings.sh: no introductions found in $KOFUN_HALF." >&2
    echo "  A compiler that binds no names is a broken read, not a clean" >&2
    echo "  result." >&2
    exit 1
}

awk -F'\t' '$1 == "read" { print $2 "\t" $3 }' "$WORK/classified.tsv" \
    >"$WORK/reads.tsv"
test -s "$WORK/reads.tsv" || {
    echo "bindings.sh: no reads found in $KOFUN_HALF." >&2
    echo "  Every name in the file being a declaration or a call is a broken" >&2
    echo "  read, not a clean result." >&2
    exit 1
}

cut -f1 "$WORK/reads.tsv" | sort -u >"$WORK/read-names.txt"
comm -23 "$WORK/read-names.txt" "$WORK/introduced.txt" >"$WORK/unresolved.txt"

if test "${1:-}" = "--count"; then
    while IFS= read -r name; do
        test -n "$name" || continue
        first=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' \
            "$WORK/reads.tsv")
        printf '%s\t%s:%s\n' "$name" "$(basename "$KOFUN_HALF")" "$first"
    done <"$WORK/unresolved.txt"
    exit 0
fi

# ---------------------------------------------------------------------------
# The ledger, exact in both directions, like `unresolved-calls.tsv` and
# `tests/assertions/budget.tsv`: an unlisted unresolved read is new drift, and a
# listed one that now resolves is a fix nobody recorded.
# ---------------------------------------------------------------------------
if test -f "$LEDGER"; then
    grep -v '^#' "$LEDGER" | grep -v '^[[:space:]]*$' | cut -f1 | sort -u \
        >"$WORK/recorded.txt"
else
    : >"$WORK/recorded.txt"
fi

comm -23 "$WORK/unresolved.txt" "$WORK/recorded.txt" >"$WORK/new.txt"
comm -13 "$WORK/unresolved.txt" "$WORK/recorded.txt" >"$WORK/stale.txt"

status=0
if test -s "$WORK/new.txt"; then
    echo "FAIL: pair bindings: a name is read and never introduced:" >&2
    while IFS= read -r name; do
        test -n "$name" || continue
        first=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' \
            "$WORK/reads.tsv")
        printf '    %s\t%s:%s\n' "$name" "$(basename "$KOFUN_HALF")" "$first" >&2
    done <"$WORK/new.txt"
    echo "  The Kofun half is never semantically compiled, so nothing else in" >&2
    echo "  this repository would say so. Fix it, or record it in" >&2
    echo "  tests/pair-coverage/unresolved-reads.tsv with the reasoning." >&2
    status=1
fi
if test -s "$WORK/stale.txt"; then
    echo "FAIL: pair bindings: a recorded read now resolves:" >&2
    sed 's/^/    /' "$WORK/stale.txt" >&2
    echo "  That is an improvement nobody wrote down. Delete the row in the" >&2
    echo "  same change that fixed it, so the ledger shrinks instead of" >&2
    echo "  accumulating excuses." >&2
    status=1
fi
test "$status" -eq 0 || exit 1

# Reach, not only hits: a count with no denominator cannot tell a rule that held
# from a rule that reached nothing.
read_count=$(grep -c . "$WORK/read-names.txt")
unresolved_count=$(grep -c . "$WORK/unresolved.txt" || true)
resolved_count=$((read_count - unresolved_count))
printf 'PASS: %d of %d names read in %s are introduced by it\n' \
    "$resolved_count" "$read_count" "$(basename "$KOFUN_HALF")"
printf '      %d reads over %d introductions, %d recorded in unresolved-reads.tsv\n' \
    "$(grep -c . "$WORK/reads.tsv")" \
    "$(grep -c . "$WORK/introduced.txt")" \
    "$unresolved_count"
