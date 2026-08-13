#!/bin/sh
set -eu

# #1383. Every declared backend either lowers RFC-0013's eight `Int` bit
# operations or refuses them by name.
#
# `tests/conformance/capabilities.tsv` already has to carry a row for every
# (backend, corpus) pair -- `check-capabilities.sh` fails with `missing entry`
# otherwise, in both directions, so a backend added later cannot go unrun. What
# that mechanism cannot do is check whether an `unsupported` row is *true*: the
# reason column is prose, and a row claiming a refusal that does not happen
# passes forever.
#
# So this gate reads the rows and holds them to what they say. For every
# backend the manifest calls `unsupported` for this corpus, the operation is
# actually compiled through that backend's own adapter and the refusal is
# required. For the two backends whose diagnostics this repository owns, the
# refusal must also *name* the operation -- because before #1383 they did
# refuse, and said:
#
#     native Core print requires one Int or Text
#     unsupported token in wasm32 arithmetic Core
#
# The first names a `print` that is not the problem, about an argument that is
# an `Int` expression. Neither tells a reader that the eight operations are the
# thing this backend does not have.
#
# The eight names are read from RFC-0013's own table rather than written here,
# so a ninth operation added to the RFC fails this gate as uncovered instead of
# being silently omitted from the refusals.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CORPUS=int-bits-lowering
MANIFEST="$ROOT/tests/conformance/capabilities.tsv"
RFC="$ROOT/rfcs/0013-int-bit-operations.md"
ASSERT_CONTEXT='int bits lowering'
. "$ROOT/tests/assertions/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-int-bits-lowering.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

# ---------------------------------------------------------------- vocabulary

sed -n 's/^| `a\.\([a-z_][a-z_]*\)(.*/\1/p' "$RFC" >"$WORK/operations"
operation_count=$(awk 'END { print NR + 0 }' "$WORK/operations")
test "$operation_count" -gt 0 ||
    assert_fail "no operations read from $RFC; its method table moved"

# The RFC's prose states the count in words. Reading both and requiring them to
# agree is what catches a table row added without the sentence being updated,
# or the reverse -- either of which would leave this gate testing a set nobody
# is maintaining.
assert_grep 'the RFC states eight operations in prose' \
    -Fq -- 'eight bit operations' "$RFC"
test "$operation_count" -eq 8 ||
    assert_fail "the RFC table lists $operation_count operations where its prose says eight"

# ------------------------------------------------------------------ sources

# One program per operation, each a minimal use. `print` takes the `Int`
# directly: a backend without a Text surface must still reach the operation,
# or its refusal would be about `to_text` and this gate would record the wrong
# fact about it.
while IFS= read -r operation; do
    case $operation in
        not)      arguments='' ;;
        rotr)     arguments='4, 32' ;;
        wrapping_add) arguments='1, 64' ;;
        *)        arguments='1' ;;
    esac
    {
        printf 'fn main() {\n'
        printf '    let a = 240\n'
        printf '    print(a.%s(%s))\n' "$operation" "$arguments"
        printf '}\n'
    } >"$WORK/$operation.kofun"
done <"$WORK/operations"

# -------------------------------------------------- what "declared" means

# The issue says "every declared backend", and the repository has two lists
# that could mean. `spec/native-toolchain-v1/contract.json` settles it:
# `declared_conformance_targets` is the conformance list, and
# `required_native_targets` is six *output formats* of one native backend
# (linux/windows/macos x x86_64/aarch64), which are not conformance targets at
# all. Deriving the matrix from the second would demand capability rows for
# object formats.
#
# Adopting the first immediately shows something: it names **six** targets and
# `tests/conformance/backends/` holds **five** adapters. `wasm32-hostabi1` is
# declared, is a real `bin/kofun --target`, and is the contract's own
# `required_portable_target` -- and it has no adapter, so `check-capabilities.sh`
# never asks about it and no capability row exists. Nothing in the repository
# compared these two lists before this gate.
#
# It is not covered here because its program surface differs: `print(240 + 15)`
# is refused by that target too, so it observes results by another channel and
# an adapter for it is separate work. Recording that is the point -- an
# unadapted declared target is exactly the "added later and goes unrun" case
# the acceptance criteria are about, and it was already true.
#
# So the ledger below fails in both directions, the way
# `tests/backlog/debt.tsv` does: a newly declared target without an adapter is
# uncovered work, and a listed one that gains an adapter is an improvement that
# has to be recorded rather than silently absorbed.
DECLARED_WITHOUT_ADAPTER='wasm32-hostabi1'

python3 - "$ROOT/spec/native-toolchain-v1/contract.json" \
    >"$WORK/declared" <<'PYTHON' ||
import json, sys

def find(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "declared_conformance_targets":
                return value
            found = find(value)
            if found is not None:
                return found
    elif isinstance(node, list):
        for item in node:
            found = find(item)
            if found is not None:
                return found
    return None

declared = find(json.load(open(sys.argv[1])))
if not declared:
    raise SystemExit("contract declares no conformance targets")
for name in sorted(declared):
    print(name)
PYTHON
    assert_fail 'the contract declares no conformance targets; its shape moved'

ls "$ROOT"/tests/conformance/backends/*.sh |
    sed 's|.*/||; s|\.sh$||' | LC_ALL=C sort >"$WORK/adapters"
printf '%s\n' "$DECLARED_WITHOUT_ADAPTER" | LC_ALL=C sort >"$WORK/recorded"

# Every adapter must be declared. An adapter the contract does not name is a
# backend nothing agreed to ship.
comm -23 "$WORK/adapters" "$WORK/declared" >"$WORK/undeclared"
test ! -s "$WORK/undeclared" ||
    assert_fail "these adapters are not in the contract's declared_conformance_targets: $(tr '\n' ' ' <"$WORK/undeclared")"

# Every declared target must have an adapter or be recorded above.
comm -23 "$WORK/declared" "$WORK/adapters" >"$WORK/unadapted"
if ! cmp -s "$WORK/unadapted" "$WORK/recorded"; then
    assert_fail "declared targets without a conformance adapter are $(tr '\n' ' ' <"$WORK/unadapted")where this gate records $(tr '\n' ' ' <"$WORK/recorded")"
fi

# ------------------------------------------------------------------- rows

manifest_state() {
    awk -F'\t' -v backend="$1" -v corpus="$2" '
        $1 == backend && $2 == corpus { print $3; found = 1 }
        END { if (!found) exit 1 }
    ' "$MANIFEST"
}

checked_backends=0
for adapter in "$ROOT"/tests/conformance/backends/*.sh; do
    test -f "$adapter" || continue
    backend=$(basename "${adapter%.sh}")
    state=$(manifest_state "$backend" "$CORPUS") ||
        assert_fail "$backend has no $CORPUS row; check-capabilities should have caught this first"
    checked_backends=$((checked_backends + 1))

    if test "$state" = supported; then
        # The differential runner already executes every case for a supported
        # backend and compares observations. Repeating that here would add a
        # second, weaker copy of it.
        continue
    fi
    test "$state" = unsupported ||
        assert_fail "$backend declares $CORPUS as \`$state\`, which is neither supported nor unsupported"

    while IFS= read -r operation; do
        case_work="$WORK/$backend.$operation"
        mkdir -p "$case_work"
        status=0
        (
            KOFUN_ROOT=$ROOT
            export KOFUN_ROOT
            . "$adapter"
            if command -v backend_check_available >/dev/null 2>&1; then
                backend_check_available >/dev/null 2>&1 || exit 125
            fi
            backend_compile \
                "$WORK/$operation.kofun" "$case_work/program" "$case_work"
        ) >"$case_work/stdout" 2>"$case_work/stderr" || status=$?

        test "$status" -ne 0 ||
            assert_fail "$backend declares $CORPUS unsupported but compiled \`.$operation\`"

        # An unusable host is not evidence about the backend's surface. 125
        # from the availability check means this machine cannot run the
        # backend's executables, which says nothing about whether it lowers
        # the operation.
        if test "$status" -eq 125 && test ! -s "$case_work/stderr" &&
           test ! -s "$case_work/stdout"
        then
            continue
        fi

        case $backend in
            native-*|wasm32-*)
                # These two diagnostics are this repository's to write, so the
                # refusal has to name the operation. `c11-stage1` is a frozen
                # seed whose wording is not ours to change; its row records
                # that its refusal points at the declaration instead.
                assert_grep "$backend names \`.$operation\` when it refuses it" \
                    -Fq -- "\`.$operation\` is one of RFC-0013's eight Int bit operations" \
                    "$case_work/stdout" "$case_work/stderr"
                ;;
        esac
    done <"$WORK/operations"
done

test "$checked_backends" -gt 0 ||
    assert_fail 'no backend adapters found; the declared backend list moved'

declared_count=$(awk 'END { print NR + 0 }' "$WORK/declared")
printf '%s\n' \
    "PASS: $checked_backends adapted backends each lower RFC-0013's $operation_count Int bit operations or refuse them, every refusal this repository owns names the operation, and the $declared_count declared conformance targets agree with the adapters up to the recorded gap ($DECLARED_WITHOUT_ADAPTER)"
