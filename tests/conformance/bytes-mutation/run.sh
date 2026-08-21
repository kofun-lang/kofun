#!/usr/bin/env sh
# #1321. The bounded mutation surface over #1315's Managed Bytes carrier.
#
# The status and the read carrier are private to the emitted C, so most of
# this gate is a driver compiled against a prelude extracted from a program
# the compiler just emitted -- the shipped bytes, not a copy of them kept in
# step by hand. What a source program can observe is `len` and `capacity`, and
# those are proved by fixtures with goldens.
#
# The operation vocabulary is derived from the compiler pair rather than
# listed here. A name added to the builtin tables and not to the runtime, or
# to one half and not the other, is the failure this repository has already
# had once (`builtin_arity`'s own comment says the three tables have to be
# edited together and nothing cross-checks them); a list written in this file
# would pass on the day that happened.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/bytes-mutation"
WORK=${KOFUN_BYTES_MUTATION_WORK:-"$ROOT/build/bytes-mutation"}
KOFUN=${KOFUN_BYTES_MUTATION_KOFUN:-"$ROOT/bin/kofun"}

fail() {
    printf '%s\n' "FAIL: bytes mutation: $1" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

# ------------------------------------------------------------ source surface
#
# Lower and run one case at both optimisation levels under the sanitizers,
# against its golden. `-O0` and `-O2` are built from the same emitted C and
# must agree: a carrier whose growth depended on an optimisation level would
# satisfy neither.
executes() {
    stem=$1
    label=$2
    "$KOFUN" build "$CASES/$stem.kofun" -o "$WORK/$stem.bin" \
        --emit-c "$WORK/$stem.c" >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr" ||
        fail "$label did not build: $(head -n 1 "$WORK/$stem.stderr")"
    for level in 0 2
    do
        "${CC:-cc}" -std=c11 "-O$level" -g -fsanitize=address,undefined \
            -I "$ROOT/unicode" "$WORK/$stem.c" -o "$WORK/$stem.O$level" \
            2>"$WORK/$stem.cc.O$level" ||
            fail "$label emitted C that does not compile at -O$level"
        ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
            "$WORK/$stem.O$level" >"$WORK/$stem.out.O$level" 2>&1 ||
            fail "$label did not run clean under the sanitizers at -O$level"
        cmp "$CASES/$stem.stdout" "$WORK/$stem.out.O$level" ||
            fail "$label printed unexpected output at -O$level"
    done
}

executes mutation 'the bounded mutation source fixture'
executes borrowed_carrier 'the operations reached through read and edit borrows'

# The borrow crossing, in the emitted C. A `read`/`edit` parameter is already
# the carrier's address, so neither the operations nor a relay to another
# function may prefix `&`. Before #1321 the relay emitted
# `kofun_fn_measure(&k_b1)` on a `const KofunBytesValue *`, and the emitted C
# did not compile -- so this is checked as text, not only by the fact that the
# fixture above builds.
grep -q 'stage2_bytes_len(k_b' "$WORK/borrowed_carrier.c" ||
    fail 'an operation on a borrow takes its address again'
grep -q 'stage2_bytes_assign_zeroed(k_b' "$WORK/borrowed_carrier.c" ||
    fail 'the zeroed producer takes a borrow address again'
grep -q 'stage2_bytes_assign_zeroed(&k_b' "$WORK/borrowed_carrier.c" &&
    fail 'the zeroed producer on a borrow regained a second address-of'
grep -q 'kofun_fn_measure(k_b' "$WORK/borrowed_carrier.c" ||
    fail 'a borrow lent onward takes its address again'
grep -q 'kofun_fn_seed(&k_b' "$WORK/borrowed_carrier.c" ||
    fail 'a local owner is no longer lent by address'
# The rule is about the argument, not the operation, so an owner and a borrow
# in the same slot must lower differently. Asserting only one of the two would
# pass against an emitter that had stopped distinguishing them.
grep -q 'stage2_bytes_assign_zeroed(&k_b' "$WORK/mutation.c" ||
    fail 'an owner reached the producer without its address'
grep -q 'stage2_bytes_assign_zeroed(k_b' "$WORK/mutation.c" &&
    fail 'an owner reached the producer as if it were already a borrow'

# ------------------------------------------------------------ the prelude
#
# Extracted from the program the compiler just emitted, ending at the last
# operation the runtime defines.
prelude_end=$(
    awk '/^static inline KofunBytesStatus stage2_bytes_append_self/ {found = 1}
         found && /^\}$/ {print NR; exit}' "$WORK/mutation.c"
)
test -n "$prelude_end" ||
    fail 'the emitted C carries no stage2_bytes_append_self to extract'
sed -n "1,${prelude_end}p" "$WORK/mutation.c" >"$WORK/prelude.h"

# The vocabulary, derived from each half of the pair and from the runtime, and
# required to be the same set three times over.
sed -n '/^fn bytes_mutation_builtin/,/^}$/p' \
    "$ROOT/bootstrap/stage2/compiler.kofun" |
    grep -o 'stage2_bytes_[a-z_]*' | sort -u >"$WORK/vocabulary.kofun"
sed -n '/^static const char \*const kofun_bytes_mutation_operations/,/^};$/p' \
    "$ROOT/bootstrap/stage2/compiler.c" |
    grep -o 'stage2_bytes_[a-z_]*' | sort -u >"$WORK/vocabulary.c"
grep -o '^static inline [A-Za-z0-9_ ]*\*\{0,1\}\(stage2_bytes_[a-z_]*\)(' \
    "$WORK/prelude.h" |
    grep -o 'stage2_bytes_[a-z_]*' |
    grep -v -e '^stage2_bytes_empty$' -e '^stage2_bytes_assign_zeroed$' |
    sort -u >"$WORK/vocabulary.runtime"

test -s "$WORK/vocabulary.kofun" ||
    fail 'no mutation vocabulary could be read from compiler.kofun'
cmp "$WORK/vocabulary.kofun" "$WORK/vocabulary.c" ||
    fail 'the two halves of the pair name different mutation operations'
cmp "$WORK/vocabulary.kofun" "$WORK/vocabulary.runtime" ||
    fail 'the operations the compiler admits and the runtime defines differ'

# Each one is defined exactly once. A second definition is how a Text bridge
# child would silently take ownership of an operation this one owns.
while IFS= read -r operation
do
    defined=$(grep -c "^static inline .*[ *]$operation(" "$WORK/prelude.h")
    test "$defined" -eq 1 ||
        fail "$operation is defined $defined times in the emitted runtime"
done <"$WORK/vocabulary.kofun"

# The read carrier: one declaration, three tags in declaration order 0..2, and
# no consumed tag. The status above it keeps its own 0..8 and is not extended
# here -- tags 6..8 belong to #1322's Text bridge, and no mutation operation
# may reach them.
test "$(grep -c 'Stage2ByteRead;$' "$WORK/prelude.h")" -eq 1 ||
    fail 'the read carrier is not declared exactly once'
grep -q 'KOFUN_BYTE_VALUE = 0' "$WORK/prelude.h" ||
    fail 'the read carrier has no ByteValue tag 0'
grep -q 'KOFUN_BYTE_READ_NEGATIVE_OFFSET = 1' "$WORK/prelude.h" ||
    fail 'the read carrier has no negative-offset tag 1'
grep -q 'KOFUN_BYTE_READ_OUT_OF_BOUNDS = 2' "$WORK/prelude.h" ||
    fail 'the read carrier has no out-of-bounds tag 2'
grep -q 'KOFUN_BYTE_READ_CONSUMED' "$WORK/prelude.h" &&
    fail 'the read carrier declares an impossible consumed tag'
test "$(grep -c 'KOFUN_BYTES_SUCCEEDED = 0' "$WORK/prelude.h")" -eq 1 ||
    fail 'the 0..8 status declaration is no longer emitted exactly once'
test "$(grep -c '} KofunBytesValue;' "$WORK/prelude.h")" -eq 1 ||
    fail 'the carrier is no longer declared exactly once'

# No mutation operation reaches the Text bridge's three tags. Checked over the
# operations' own text rather than the whole prelude, because the status
# declaration legitimately names all nine.
sed -n "/^static inline .*stage2_bytes_len(/,\$p" "$WORK/prelude.h" \
    >"$WORK/operations.c"
if grep -qE 'KOFUN_BYTES_(INVALID_UTF8|TEXT_CONTAINS_NUL|TEXT_LIMIT_EXCEEDED)' \
    "$WORK/operations.c"
then
    fail 'a mutation operation emits a Text-bridge status tag'
fi
# ------------------------------------------------------------ the driver
#
# Values, ranges, growth, precedence, and transactionality. Built with the
# ordinary allocator and again with the Nth allocation made to fail, because
# the injected-failure edge is where a transactional helper stops being one.
for level in 0 2
do
    "${CC:-cc}" -std=c11 "-O$level" -Wall -Wextra -Werror -pedantic \
        -I "$WORK" -I "$ROOT/unicode" "$CASES/mutation_driver.c" \
        -o "$WORK/driver.O$level" 2>"$WORK/driver.O$level.cc" ||
        fail "the mutation driver did not build at -O$level"
    "$WORK/driver.O$level" >"$WORK/driver.O$level.out" 2>&1 ||
        fail "the mutation contract failed at -O$level: $(head -n 1 "$WORK/driver.O$level.out")"
done
printf 'ok\n' >"$WORK/driver.expected"
for required_level in 0 2
do
    cmp "$WORK/driver.expected" "$WORK/driver.O$required_level.out" ||
        fail "the exact strict -O$required_level driver result is absent"
done

# The pointer assertion is executable, not merely present in the driver. This
# build swaps in byte-identical storage after a refusal and must be caught by
# pointer identity alone.
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_BYTES_PROVE_POINTER_WITNESS=1 \
    -I "$WORK" -I "$ROOT/unicode" "$CASES/mutation_driver.c" \
    -o "$WORK/driver.pointer-proof" 2>"$WORK/driver.pointer-proof.cc" ||
    fail 'the pointer-witness proof driver did not build'
if "$WORK/driver.pointer-proof" >"$WORK/driver.pointer-proof.out" 2>&1
then
    fail 'the pointer-witness proof mutation was accepted'
fi
grep -q 'reserve negative: the carrier pointer changed' \
    "$WORK/driver.pointer-proof.out" ||
    fail 'the pointer-witness proof did not name the changed pointer'

"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_BYTES_INJECT_ALLOC_BUDGET=1 \
    -I "$WORK" -I "$ROOT/unicode" "$CASES/mutation_driver.c" \
    -o "$WORK/driver.oom" 2>"$WORK/driver.oom.cc" ||
    fail 'the allocation-failure driver did not build'
"$WORK/driver.oom" >"$WORK/driver.oom.out" 2>&1 ||
    fail "the allocation-failure contract failed: $(head -n 1 "$WORK/driver.oom.out")"

# The append_range OOM result and both carrier witnesses are meaningful only
# if the real operation ran. Omit that call in a proof build; the counter,
# incremented only after the operation returns, must name the missing attempt.
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_BYTES_INJECT_ALLOC_BUDGET=1 \
    -DKOFUN_BYTES_PROVE_RANGE_ATTEMPT_OMISSION=1 \
    -I "$WORK" -I "$ROOT/unicode" "$CASES/mutation_driver.c" \
    -o "$WORK/driver.range-attempt-proof" \
    2>"$WORK/driver.range-attempt-proof.cc" ||
    fail 'the append_range OOM-attempt proof driver did not build'
if "$WORK/driver.range-attempt-proof" \
    >"$WORK/driver.range-attempt-proof.out" 2>&1
then
    fail 'the append_range OOM-attempt proof mutation was accepted'
fi
grep -q 'append_range OOM attempt count: got 0, want 1' \
    "$WORK/driver.range-attempt-proof.out" ||
    fail 'the append_range OOM-attempt proof did not name the missing call'

# Both sides of the two-carrier OOM witness are live too. Give the two carriers
# deliberately different bytes, then copy each peer's saved bytes over the
# other after refusal; either missing assertion leaves a named proof line
# absent below.
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -DKOFUN_BYTES_INJECT_ALLOC_BUDGET=1 \
    -DKOFUN_BYTES_PROVE_RANGE_SOURCE_WITNESS=1 \
    -DKOFUN_BYTES_PROVE_RANGE_DESTINATION_WITNESS=1 \
    -I "$WORK" -I "$ROOT/unicode" "$CASES/mutation_driver.c" \
    -o "$WORK/driver.range-oom-proof" \
    2>"$WORK/driver.range-oom-proof.cc" ||
    fail 'the append_range OOM-witness proof driver did not build'
if "$WORK/driver.range-oom-proof" \
    >"$WORK/driver.range-oom-proof.out" 2>&1
then
    fail 'the append_range OOM-witness proof mutation was accepted'
fi
grep -q 'append_range source under OOM: the carrier bytes changed' \
    "$WORK/driver.range-oom-proof.out" ||
    fail 'the append_range source-witness proof did not name changed bytes'
grep -q 'append_range destination under OOM: the carrier bytes changed' \
    "$WORK/driver.range-oom-proof.out" ||
    fail 'the append_range destination-witness proof did not name changed bytes'

"${CC:-cc}" -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined \
    -I "$WORK" -I "$ROOT/unicode" "$CASES/mutation_driver.c" \
    -o "$WORK/driver.asan" 2>"$WORK/driver.asan.cc" ||
    fail 'the mutation driver did not build under the sanitizers'
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/driver.asan" >"$WORK/driver.asan.out" 2>&1 ||
    fail "the mutation surface is not sanitizer-clean: $(head -n 1 "$WORK/driver.asan.out")"

# ------------------------------------------------------------ the refusal
#
# `append_range` copies between two carriers with `memcpy`. Two distinct
# BindingIds are what proves the two carriers are different values, so one
# value in both positions -- and an identity the typed HIR could not resolve
# -- are refused before any C is emitted.
refuses() {
    stem=$1
    expected=$2
    # Stale artifacts make the cleanup assertions non-vacuous: removing the
    # pre-build cleanup leaves one behind even though the refusal emits none.
    printf 'stale\n' >"$WORK/$stem.c"
    printf 'stale\n' >"$WORK/$stem.bin"
    rm -f "$WORK/$stem.c" "$WORK/$stem.bin"
    if "$KOFUN" build "$CASES/$stem.kofun" -o "$WORK/$stem.bin" \
        --emit-c "$WORK/$stem.c" >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    then
        fail "$stem was accepted"
    fi
    grep -qF "$expected" "$WORK/$stem.stdout" "$WORK/$stem.stderr" ||
        fail "$stem did not report: $expected"
    test ! -e "$WORK/$stem.c" ||
        fail "$stem committed C"
    test ! -e "$WORK/$stem.bin" ||
        fail "$stem committed a binary"
}

refuses same_carrier \
    'error[E2S177]: Stage 2 `stage2_bytes_append_range` needs two distinct Bytes values'
refuses unresolved_carrier \
    'error[E2S177]: Stage 2 bounded Bytes operations need a named carrier binding'
refuses temporary_carrier \
    'error[E2S177]: Stage 2 bounded Bytes operations need a named carrier binding'


# The two reasons are distinct sentences. One reason for both shapes would let
# a later change to either stop being visible.
cat "$WORK/same_carrier.stdout" "$WORK/same_carrier.stderr" \
    >"$WORK/same_carrier.reported"
cat "$WORK/unresolved_carrier.stdout" "$WORK/unresolved_carrier.stderr" \
    >"$WORK/unresolved_carrier.reported"
cat "$WORK/temporary_carrier.stdout" "$WORK/temporary_carrier.stderr" \
    >"$WORK/temporary_carrier.reported"
if cmp -s "$WORK/same_carrier.reported" "$WORK/unresolved_carrier.reported"
then
    fail 'both refusal shapes report the same sentence'
fi

# Every refusal fits the typed sidecar's frozen 160-byte detail field. The
# semantic producer copies a diagnostic into `char detail[160]` and truncates
# silently, so a longer sentence reaches an author through the compiler and a
# different, shorter one through every consumer of the event stream. Nothing
# had reached the bound before: the longest Stage 2 golden was 142 bytes, and
# the first draft of this refusal was 185. `task stage2-events` catches it,
# but only as a `cmp` failure between the producer and the authority, so the
# bound is stated here where the sentence is chosen.
for reported in same_carrier unresolved_carrier temporary_carrier
do
    width=$(head -n 1 "$WORK/$reported.reported" | wc -c)
    test "$width" -lt 160 ||
        fail "the $reported refusal is $width bytes; the sidecar truncates at 160"
done

printf 'stale\n' >"$WORK/repeat.c"
printf 'stale\n' >"$WORK/repeat.bin"
rm -f "$WORK/repeat.c" "$WORK/repeat.bin"
"$KOFUN" build "$CASES/same_carrier.kofun" \
    -o "$WORK/repeat.bin" --emit-c "$WORK/repeat.c" \
    >"$WORK/repeat.1" 2>&1 || true
test ! -e "$WORK/repeat.c" ||
    fail 'the first repeated refusal committed C'
test ! -e "$WORK/repeat.bin" ||
    fail 'the first repeated refusal committed a binary'
printf 'stale\n' >"$WORK/repeat.c"
printf 'stale\n' >"$WORK/repeat.bin"
rm -f "$WORK/repeat.c" "$WORK/repeat.bin"
"$KOFUN" build "$CASES/same_carrier.kofun" \
    -o "$WORK/repeat.bin" --emit-c "$WORK/repeat.c" \
    >"$WORK/repeat.2" 2>&1 || true
test ! -e "$WORK/repeat.c" ||
    fail 'the second repeated refusal committed C'
test ! -e "$WORK/repeat.bin" ||
    fail 'the second repeated refusal committed a binary'
cmp "$WORK/repeat.1" "$WORK/repeat.2" ||
    fail 'the same refusal reported differently on a second run'

# The three binary checks above are executable, not merely present beside the
# C checks. Run this gate through a defective builder three times, leaving the
# requested binary behind only after refusal 1 (ordinary), 4 (first repeat), or
# 5 (second repeat). Each child must stop at its selected assertion and name
# that artifact. Removing any one assertion lets its child reach the end, and
# the outer proof refuses that false green.
if test "${KOFUN_BYTES_MUTATION_BINARY_PROOF_CHILD:-0}" != 1; then
    binary_proof_builder="$WORK/binary-artifact-builder"
    cat >"$binary_proof_builder" <<'EOF'
#!/usr/bin/env sh
set -eu

output=
previous=
for argument
do
    if test "$previous" = -o; then
        output=$argument
    fi
    previous=$argument
done

status=0
"$KOFUN_BYTES_MUTATION_REAL_KOFUN" "$@" || status=$?
if test "$status" -ne 0 && test -n "$output"; then
    refusal_count=0
    if test -f "$KOFUN_BYTES_MUTATION_REFUSAL_COUNT"; then
        refusal_count=$(cat "$KOFUN_BYTES_MUTATION_REFUSAL_COUNT")
    fi
    refusal_count=$((refusal_count + 1))
    printf '%s\n' "$refusal_count" >"$KOFUN_BYTES_MUTATION_REFUSAL_COUNT"
    if test "$refusal_count" -eq "$KOFUN_BYTES_MUTATION_BINARY_PROOF_TARGET"; then
        printf 'proof binary artifact\n' >"$output"
    fi
fi
exit "$status"
EOF
    chmod +x "$binary_proof_builder"
    prove_binary_assertion() {
        proof_target=$1
        proof_name=$2
        proof_expected=$3
        proof_work="$WORK/binary-artifact-proof-$proof_name"
        proof_output="$WORK/binary-artifact-proof-$proof_name.out"
        binary_proof_status=0
        KOFUN_BYTES_MUTATION_WORK="$proof_work" \
        KOFUN_BYTES_MUTATION_KOFUN="$binary_proof_builder" \
        KOFUN_BYTES_MUTATION_REAL_KOFUN="$KOFUN" \
        KOFUN_BYTES_MUTATION_BINARY_PROOF_TARGET="$proof_target" \
        KOFUN_BYTES_MUTATION_REFUSAL_COUNT="$proof_work/refusal-count" \
        KOFUN_BYTES_MUTATION_BINARY_PROOF_CHILD=1 \
            sh "$0" >"$proof_output" 2>&1 || binary_proof_status=$?
        test "$binary_proof_status" -ne 0 ||
            fail "the $proof_name binary-artifact proof mutation was accepted"
        grep -qF "FAIL: bytes mutation: $proof_expected" "$proof_output" ||
            fail "the $proof_name binary-artifact proof did not name its binary"
    }
    prove_binary_assertion 1 ordinary \
        'same_carrier committed a binary'
    prove_binary_assertion 4 first-repeat \
        'the first repeated refusal committed a binary'
    prove_binary_assertion 5 second-repeat \
        'the second repeated refusal committed a binary'
fi

# A refusal raised by a statement must be reported, not emitted. Both arms of
# the expression-statement lowering used to concatenate the refusal into the
# C, so `same_carrier` reported an undeclared `error` from the host compiler
# at a byte offset in generated code. The stdout above proves the diagnostic;
# this proves nothing generated leaked out with it.
if grep -q 'E2S177' "$WORK/repeat.1" && grep -q 'undeclared' "$WORK/repeat.1"
then
    fail 'the refusal reached the host compiler instead of the author'
fi

printf '%s\n' \
    'PASS: emitted source fixtures execute identically under ASan/UBSan at -O0/-O2; the full mutation driver passes strict -O0/-O2 and an ASan/UBSan build' \
    'PASS: the operations, the zeroed producer, a relay, and an edit-to-read widening all reach a borrow without a second address-of, while a local owner is still lent by address' \
    'PASS: the operations the two halves of the pair admit and the ones the emitted runtime defines are one set, each defined exactly once' \
    'PASS: the read carrier is declared once with tags 0..2 and no consumed tag; the 0..8 status and the carrier are still declared once each' \
    'PASS: no mutation operation reaches a Text-bridge status tag' \
    'PASS: exact bytes 0x00/0x7f/0x80/0xff are append-attempted at lengths 0, 1, 255, 16384, and 65536 under strict O0/O2 and ASan/UBSan, succeeding below the ceiling and preserving it on refusal; every named range, byte, and capacity refusal preserves the named carrier pointers and bytes' \
    'PASS: growth 0->16, every doubling edge, the ceiling, one over it, reserve, and clear-capacity preservation hold; the injected-OOM append_range call is live-proved and preserves pointer and bytes for source and destination too' \
    'PASS: one value in both positions of append_range, an unresolved identity, and a temporary in a carrier slot are refused as E2S177, commit no C and are mutation-proved to commit no binary, fit the sidecar detail bound, and the same-carrier refusal reports identically on a second run'
