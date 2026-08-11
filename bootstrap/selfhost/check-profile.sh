#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

meta=bootstrap/selfhost/profile.meta
profile=bootstrap/selfhost/profile.tsv
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/kofun-selfhost-profile.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

fail() {
    printf '%s\n' "FAIL: self-host profile: $*" >&2
    exit 1
}

# Evidence failures name the row and the evidence class they belong to. A
# manifest with four classes per row is unreadable when the report says only
# that something did not hold.
fail_class() {
    fail_row=$1
    fail_evidence_class=$2
    shift 2
    fail "row $fail_row class $fail_evidence_class: $*"
}

# Optional phase completion gates. The default invocation validates the
# manifest itself and stays green while evidence is still planned; a phase
# gate fails until every cell owned by that phase carries checked-in
# evidence. `--phase frontend` is the #619 completion gate for the typed
# HIR contract in bootstrap/selfhost/hir-v1.md.
phase=
while test "$#" -gt 0; do
    case $1 in
        --phase)
            test "$#" -ge 2 || fail "--phase requires a phase name"
            phase=$2
            shift 2
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done
case $phase in
    ''|frontend|c11-text|c11-control) ;;
    *) fail "unknown phase: $phase (supported: frontend, c11-text, c11-control)" ;;
esac

meta_value() {
    key=$1
    awk -F '|' -v key="$key" '
        $1 == key { value = $2; count += 1 }
        END {
            if (count != 1 || value == "") {
                exit 1
            }
            print value
        }
    ' "$meta"
}

test "$(meta_value schema)" = "kofun.selfhost-profile/v2" ||
    fail "unsupported metadata schema"
source_path=$(meta_value canonical_source) ||
    fail "canonical_source must appear exactly once"
expected_sha=$(meta_value source_sha256) ||
    fail "source_sha256 must appear exactly once"
a1_source=$(meta_value a1_source) ||
    fail "a1_source must appear exactly once"
corpus_root=$(meta_value corpus_root) ||
    fail "corpus_root must appear exactly once"
gate_target=$(meta_value self_application_gate) ||
    fail "self_application_gate must appear exactly once"
test -f "$source_path" || fail "canonical source is missing: $source_path"
test -f "$a1_source" || fail "A1 source is missing: $a1_source"
test -d "$corpus_root" || fail "corpus root is missing: $corpus_root"

actual_sha=$("$repo_root/bin/kofun-digest" "$source_path" | awk '{ print $1 }')
test "$actual_sha" = "$expected_sha" ||
    fail "$source_path changed; review profile rows and update source_sha256"

# v2 splits the single self_compiler column into the four facts it used to
# blur together: that S uses the feature, that A1 accepts a fixture using it,
# that A1 lowers that fixture to the reviewed C, and that A1 compiles S. Each
# is proven by running something; none is proven by a path existing.
expected_header='category|feature|source_evidence|frontend|c11|used_by_s|accepted_by_a1|lowered_by_a1|self_application|positive|negative|differential|status'
header=$(sed -n '1p' "$profile")
test "$header" = "$expected_header" || fail "unexpected profile header"

awk -F '|' '
    NR == 1 { next }
    NF != 13 {
        printf "profile row %d has %d fields, expected 13\n", NR, NF > "/dev/stderr"
        failed = 1
        next
    }
    $1 == "" || $2 == "" {
        printf "profile row %d has an empty key\n", NR > "/dev/stderr"
        failed = 1
    }
    $13 != "missing" && $13 != "partial" && $13 != "complete" {
        printf "profile row %d has invalid status %s\n", NR, $13 > "/dev/stderr"
        failed = 1
    }
    {
        for (field = 3; field <= 12; field += 1) {
            if ($field == "") {
                printf "profile row %d has empty evidence field %d\n", NR, field > "/dev/stderr"
                failed = 1
            }
            if ($13 == "complete" && $field ~ /^planned:/) {
                printf "complete row %d still has planned evidence\n", NR > "/dev/stderr"
                failed = 1
            }
        }
    }
    END { exit failed }
' "$profile" || fail "invalid profile row"

tail -n +2 "$profile" > "$tmp_dir/rows"
LC_ALL=C sort -t '|' -k1,1 -k2,2 -c "$tmp_dir/rows" 2>/dev/null ||
    fail "profile rows must be sorted by category and feature"
cut -d '|' -f 1,2 "$tmp_dir/rows" > "$tmp_dir/expected-inventory"
test "$(wc -l < "$tmp_dir/expected-inventory")" -eq \
     "$(LC_ALL=C sort -u "$tmp_dir/expected-inventory" | wc -l)" ||
    fail "duplicate category/feature key"

# Path existence is still required of the columns that name a reviewed file:
# source evidence, the #619 frontend cell, the #620/#621 c11 cell, and the
# positive/negative/differential fixtures. It is no longer what decides a
# `complete` row — the four evidence classes below are, and each of them runs
# a command.
awk -F '|' '
    NR == 1 { next }
    {
        for (field = 3; field <= 5; field += 1) {
            if ($field !~ /^planned:/) { print $field }
        }
        for (field = 10; field <= 12; field += 1) {
            if ($field !~ /^planned:/) { print $field }
        }
    }
' "$profile" | LC_ALL=C sort -u > "$tmp_dir/evidence-paths"
while IFS= read -r evidence_path; do
    test -e "$evidence_path" ||
        fail "evidence path does not exist: $evidence_path"
done < "$tmp_dir/evidence-paths"

# Ignore comments, then blank the contents of every Text literal, keeping the
# quotes so Text-literal usage is still visible. What remains is the language
# surface of the source: C tokens that occur only inside the emitted-C template
# can no longer be mistaken for Kofun calls or constructs. Skipping lines that
# merely *start* with a quote was not enough once the template is built from
# literals assigned to locals.
#
# v2 applies this to any source, not only to S: the same detector run over a
# driver corpus is what proves a row may claim that corpus as its acceptance
# fixture. A row cannot name a fixture that does not use its feature.
#
# `has` and `keep` stay at this level rather than inside the function: a bare
# silenced `grep` is only exempt from the #814 assertion budget when it is the
# last command of a function body, and tests/assertions/check.sh recognises
# that end by a `}` in the first column.
has() {
    grep -Eq "$1" "$inventory_work/outer-source"
}
keep() {
    printf '%s\n' "$1" >> "$inventory_work/keys"
}
derive_inventory() {
    inventory_source=$1
    inventory_out=$2
    inventory_work=$tmp_dir/inventory-work
    rm -rf "$inventory_work"
    mkdir -p "$inventory_work"

    awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            out = ""
            in_string = 0
            width = length(line)
            for (position = 1; position <= width; position += 1) {
                character = substr(line, position, 1)
                if (in_string) {
                    if (character == "\\") { position += 1; continue }
                    if (character == "\"") { in_string = 0; out = out "\"" }
                    continue
                }
                if (character == "\"") { in_string = 1; out = out "\"" }
                else { out = out character }
            }
            print out
        }
    ' "$inventory_source" > "$inventory_work/outer-source"

    sed -n \
        's/^[[:space:]]*fn[[:space:]]\([A-Za-z_][A-Za-z0-9_]*\)(.*/\1/p' \
        "$inventory_work/outer-source" |
        LC_ALL=C sort -u > "$inventory_work/functions"
    awk '!/^[[:space:]]*fn[[:space:]]/' "$inventory_work/outer-source" |
        grep -Eo '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' |
        sed 's/[[:space:]]*(//' |
        LC_ALL=C sort -u > "$inventory_work/calls"

    LC_ALL=C comm -23 "$inventory_work/calls" "$inventory_work/functions" |
        sed 's/^/builtin|/' > "$inventory_work/keys"

    has '^[[:space:]]*} else if[[:space:]]' && keep 'control|else-if'
    has '^[[:space:]]*for[[:space:]].*[[:space:]]in[[:space:]].*\.\.' &&
        keep 'control|for-range'
    has '^[[:space:]]*if[[:space:]]' && keep 'control|if'
    has '^[[:space:]]*return[[:space:]]+[^[:space:]]' &&
        keep 'control|return-value'
    has '^[[:space:]]*return[[:space:]]*$' && keep 'control|return-void'
    has '^[[:space:]]*while[[:space:]]' && keep 'control|while'

    has '\|\||&&|![^=]' && keep 'expression|boolean-operators'
    has '==|!=|<=|>=|[[:space:]][<>][[:space:]]' && keep 'expression|comparison'
    LC_ALL=C comm -12 "$inventory_work/calls" "$inventory_work/functions" |
        grep -q . && keep 'expression|direct-call'
    has '\[[^]]+\]' && keep 'expression|indexing'
    has '=[^"]*[[:space:]][+-][[:space:]][A-Za-z0-9_(]' &&
        keep 'expression|integer-arithmetic'
    has 'read_text\([^)]*\)[[:space:]]*\+[[:space:]]*"|=[^"]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\+[[:space:]]*"' &&
        keep 'expression|text-concatenation'

    grep -qx 'args' "$inventory_work/calls" && keep 'host|command-line'
    grep -qx 'read_text' "$inventory_work/calls" && keep 'host|file-read'
    grep -qx 'write_text' "$inventory_work/calls" && keep 'host|file-write'
    grep -qx 'print' "$inventory_work/calls" && keep 'host|stdout'

    has '(^|[^A-Za-z0-9_])(true|false)([^A-Za-z0-9_]|$)' && keep 'literal|Bool'
    has '(^|[^A-Za-z0-9_])[0-9]+([^A-Za-z0-9_]|$)' && keep 'literal|Int'
    has '"([^"\\]|\\.)*"' && keep 'literal|Text'

    has '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[^=]' &&
        keep 'statement|assignment'
    has '^[[:space:]]*let[[:space:]]+[A-Za-z_]' &&
        keep 'statement|immutable-local'
    has '^[[:space:]]*let[[:space:]]+mut[[:space:]]' &&
        keep 'statement|mutable-local'
    has '^[[:space:]]*fn[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\([^)]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*[^)]' &&
        keep 'syntax|function-parameter'
    has '^[[:space:]]*fn[[:space:]].*\)[[:space:]]*->[[:space:]]*' &&
        keep 'syntax|function-result'
    test -s "$inventory_work/functions" && keep 'syntax|top-level-function'

    has '(^|[^A-Za-z0-9_])Bool([^A-Za-z0-9_]|$)' && keep 'type|Bool'
    has 'let([[:space:]]+mut)?[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[0-9]+' &&
        keep 'type|Int'
    grep -Eq '^(args|chars)$' "$inventory_work/calls" && keep 'type|List[Text]'
    has '(^|[^A-Za-z0-9_])Text([^A-Za-z0-9_]|$)' && keep 'type|Text'
    has '^[[:space:]]*fn[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\([^)]*\)[[:space:]]*\{' &&
        keep 'type|Void'

    # These constructs are intentionally outside the first profile. If a source
    # starts using one, emit a new inventory key so the manifest comparison
    # fails.
    for construct in import law match module trait type; do
        if has "^[[:space:]]*$construct[[:space:]]"; then
            keep "syntax|$construct"
        fi
    done
    has '\|>' && keep 'expression|pipeline'

    LC_ALL=C sort -u "$inventory_work/keys" > "$inventory_out"
}

derive_inventory "$source_path" "$tmp_dir/actual-inventory"
if ! cmp -s "$tmp_dir/expected-inventory" "$tmp_dir/actual-inventory"; then
    diff -u "$tmp_dir/expected-inventory" "$tmp_dir/actual-inventory" >&2 || :
    fail "canonical source feature inventory changed"
fi

# ------------------------------------------------------------------ evidence
# A1 is the compiler produced from S. It is built once from the reviewed C
# evidence for S; that file's correspondence to the canonical source is the
# self-compile gate's property, not this one's, so this gate reads it rather
# than re-deriving it. KOFUN_SELFHOST_A1 lets a caller that already built the
# same binary hand it over, in the shape of bootstrap/stage2/build.sh.
if command -v cc >/dev/null 2>&1; then
    host_compiler=cc
elif command -v clang >/dev/null 2>&1; then
    host_compiler=clang
elif command -v gcc >/dev/null 2>&1; then
    host_compiler=gcc
else
    fail "a C11 compiler is required to execute per-class evidence"
fi

a1=$tmp_dir/a1
if test -n "${KOFUN_SELFHOST_A1:-}"; then
    test -x "$KOFUN_SELFHOST_A1" ||
        fail "KOFUN_SELFHOST_A1 is not executable: $KOFUN_SELFHOST_A1"
    cp "$KOFUN_SELFHOST_A1" "$a1"
else
    "$host_compiler" -std=c11 -O2 -Wall -Wextra -Werror \
        -I unicode "$a1_source" -o "$a1"
fi

# self_application, run once: A1 compiles the canonical source it was derived
# from into a nonempty C2. Determinism, path independence, the audited
# hand-port differential and the strict-C11 host boundary stay with the gate
# named by every row, which this script does not re-implement.
mkdir -p "$tmp_dir/self"
cp "$source_path" "$tmp_dir/self/S.kofun"
( cd "$tmp_dir/self" && "$a1" S.kofun C2.c >stdout.txt 2>stderr.txt ) ||
    fail "A1 could not compile the canonical source"
test -s "$tmp_dir/self/C2.c" || fail "A1 produced an empty C2"

# The gate a row names must exist as a task target, must run the self-compile
# script, and must be part of the aggregate verification. A row pointing at a
# target nobody runs is the path-shaped evidence v2 exists to remove.
awk -v target="$gate_target" '
    $0 ~ "^  " target ":" { in_target = 1; next }
    in_target && /^  [a-z0-9-]+:/ { in_target = 0 }
    in_target && /check-compiler-driver\.sh/ { found = 1 }
    END { exit found ? 0 : 1 }
' Taskfile.yml ||
    fail "task target $gate_target does not run the self-compile gate"
grep -Eq "^[[:space:]]+${gate_target}[[:space:]]*\\\\\$" Taskfile.yml ||
    fail "task target $gate_target is not part of the aggregate verification"

# Each distinct corpus is compiled once. Both acceptance and lowering read the
# same run: acceptance is that A1 exited zero with no diagnostic, lowering is
# that its emitted C is the reviewed evidence byte for byte.
prepared=$tmp_dir/prepared
: > "$prepared"
prepare_corpus() {
    corpus_stem=$1
    corpus_row=$2
    corpus_class=$3
    if grep -qxF "$corpus_stem" "$prepared"; then
        return 0
    fi
    corpus_source=$corpus_root/$corpus_stem.kofun
    corpus_evidence=$corpus_root/$corpus_stem.c
    test -f "$corpus_source" ||
        fail_class "$corpus_row" "$corpus_class" \
            "corpus source is missing: $corpus_source"
    test -f "$corpus_evidence" ||
        fail_class "$corpus_row" "$corpus_class" \
            "corpus C evidence is missing: $corpus_evidence"
    corpus_work=$tmp_dir/corpus-$corpus_stem
    mkdir -p "$corpus_work"
    cp "$corpus_source" "$corpus_work/input.kofun"
    ( cd "$corpus_work" &&
        "$a1" input.kofun output.c >stdout.txt 2>stderr.txt ) ||
        fail_class "$corpus_row" "$corpus_class" \
            "A1 refused $corpus_stem.kofun"
    derive_inventory "$corpus_source" "$tmp_dir/corpus-keys-$corpus_stem"
    printf '%s\n' "$corpus_stem" >> "$prepared"
}

executed=0
skipped=0
while IFS='|' read -r category feature source_evidence frontend c11 \
    used_by_s accepted_by_a1 lowered_by_a1 self_application \
    positive negative differential status
do
    row="$category|$feature"

    # used_by_s is proven for every row, whatever its status: the feature must
    # appear in the inventory derived from the pinned canonical source above.
    test "$used_by_s" = "inventory:S" ||
        fail_class "$row" used_by_s "unknown prover: $used_by_s"
    grep -qxF "$row" "$tmp_dir/actual-inventory" ||
        fail_class "$row" used_by_s \
            "the inventory derived from $source_path does not contain it"

    # self_application holds for an incomplete row too: A1 compiles the whole
    # canonical source, so a row that cannot yet name a fixture still carries
    # this class. Its spelling is therefore checked on every row.
    case $self_application in
        gate:?*) named_gate=${self_application#gate:} ;;
        *) fail_class "$row" self_application \
            "unknown prover: $self_application" ;;
    esac
    test "$named_gate" = "$gate_target" ||
        fail_class "$row" self_application \
            "names $named_gate, but the profile declares $gate_target"

    if test "$status" != complete; then
        skipped=$((skipped + 1))
        continue
    fi

    case $accepted_by_a1 in
        a1-accept:?*) accept_stem=${accepted_by_a1#a1-accept:} ;;
        *) fail_class "$row" accepted_by_a1 \
            "unknown prover: $accepted_by_a1" ;;
    esac
    case $lowered_by_a1 in
        a1-lower:?*) lower_stem=${lowered_by_a1#a1-lower:} ;;
        *) fail_class "$row" lowered_by_a1 "unknown prover: $lowered_by_a1" ;;
    esac

    prepare_corpus "$accept_stem" "$row" accepted_by_a1
    grep -qxF "$row" "$tmp_dir/corpus-keys-$accept_stem" ||
        fail_class "$row" accepted_by_a1 \
            "$accept_stem.kofun does not use this feature"
    test ! -s "$tmp_dir/corpus-$accept_stem/stderr.txt" ||
        fail_class "$row" accepted_by_a1 \
            "A1 reported a diagnostic for $accept_stem.kofun"

    prepare_corpus "$lower_stem" "$row" lowered_by_a1
    grep -qxF "$row" "$tmp_dir/corpus-keys-$lower_stem" ||
        fail_class "$row" lowered_by_a1 \
            "$lower_stem.kofun does not use this feature"
    cmp -s "$tmp_dir/corpus-$lower_stem/output.c" \
        "$corpus_root/$lower_stem.c" ||
        fail_class "$row" lowered_by_a1 \
            "A1 emission for $lower_stem differs from the reviewed evidence"

    executed=$((executed + 1))
done < "$tmp_dir/rows"

corpus_count=$(wc -l < "$prepared" | tr -d ' ')

printf '%s\n' \
    "PASS: first self-host profile pins $source_path ($actual_sha)" \
    "PASS: $(wc -l < "$tmp_dir/actual-inventory") source features have explicit coverage rows" \
    "PASS: A1 compiled the canonical source into a nonempty C2" \
    "PASS: $executed complete rows ran A1 against $corpus_count reviewed corpora" \
    "PASS: $skipped rows are not complete and claim no fixture evidence"

if test -z "$phase" || test "$phase" = frontend; then
    awk -F '|' '
        NR == 1 { next }
        $4 ~ /^planned:/ {
            printf "PENDING: %s|%s frontend %s\n", $1, $2, $4
        }
    ' "$profile" > "$tmp_dir/frontend-pending"
    pending_count=$(wc -l < "$tmp_dir/frontend-pending" | tr -d ' ')
    total_count=$(($(wc -l < "$profile" | tr -d ' ') - 1))
    if test "$pending_count" -gt 0; then
        cat "$tmp_dir/frontend-pending"
        fail "$pending_count of $total_count frontend cells still await #619 evidence"
    fi
    printf '%s\n' \
        "PASS: all $total_count frontend cells carry checked-in typed-HIR evidence"
fi

# The c11 phase gates are per-issue completion checks: each fails while
# any c11 cell owned by its issue is still planned, and reports how many
# c11 cells carry checked-in evidence overall. Cells owned by later
# phases stay planned until their own gates.
c11_phase_gate() {
    owner=$1
    awk -F '|' -v owner="planned:$owner" '
        NR == 1 { next }
        $5 == owner {
            printf "PENDING: %s|%s c11 %s\n", $1, $2, $5
        }
    ' "$profile" > "$tmp_dir/c11-pending"
    pending_count=$(wc -l < "$tmp_dir/c11-pending" | tr -d ' ')
    evidence_count=$(awk -F '|' '
        NR > 1 && $5 !~ /^planned:/ { count += 1 }
        END { print count + 0 }
    ' "$profile")
    if test "$pending_count" -gt 0; then
        cat "$tmp_dir/c11-pending"
        fail "$pending_count c11 cells still await $owner evidence"
    fi
    printf '%s\n' \
        "PASS: no c11 cells await $owner evidence ($evidence_count carry checked-in paths)"
}
if test -z "$phase" || test "$phase" = c11-text; then
    c11_phase_gate '#620'
fi
if test -z "$phase" || test "$phase" = c11-control; then
    c11_phase_gate '#621'
fi
