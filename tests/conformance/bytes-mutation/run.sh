#!/usr/bin/env sh
# #1321. The bounded mutation surface over #1315's Managed Bytes carrier.
#
# The status is private to the emitted C, so most of this gate is a driver
# compiled against a prelude extracted from a program the compiler just
# emitted -- the shipped bytes, not a copy of them kept in step by hand. What
# a source program can observe is `len`, `capacity`, and (since #1499) the
# byte `byte_at` reads, and those are proved by fixtures with goldens.
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
executes same_name_declarations 'same-name current-file declarations'
executes same_name_lexical 'a same-name lexical callable'

# #1560. The three current-file calls cover ordinary, labelled fixed-slot, and
# mutation-name lowering. Their spelling must survive only behind `kofun_fn_`;
# the undeclared control still reaches the compiler-owned helper. The lexical
# case contains no Bytes value, so even emitting the runtime prelude would be a
# resolution leak visible as allocation machinery.
grep -q 'kofun_fn_stage2_bytes_len(&k_b' \
    "$WORK/same_name_declarations.c" ||
    fail 'a declared stage2_bytes_len did not call its Kofun function'
grep -q 'kofun_fn_stage2_bytes_capacity(kofun_call_arg_' \
    "$WORK/same_name_declarations.c" ||
    fail 'a labelled declared stage2_bytes_capacity used builtin lowering'
grep -q 'kofun_fn_stage2_bytes_append(INT64_C(7))' \
    "$WORK/same_name_declarations.c" ||
    fail 'a mutation-name declaration used the private runtime status'
grep -q 'stage2_bytes_append(&k_b' "$WORK/mutation.c" ||
    fail 'an undeclared mutation builtin stopped using its runtime helper'
if grep -E 'stage2_bytes_(append|len)|malloc|calloc|realloc' \
    "$WORK/same_name_lexical.c" >/dev/null
then
    fail 'a lexical callable spelling reached the Bytes builtin runtime'
fi
executes wrapper_identity 'declared wrapper identity and read/read sharing'
executes parenthesized_carrier 'transparent parenthesized Bytes carriers'

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
grep -q 'kofun_fn_seed(k_b' "$WORK/borrowed_carrier.c" ||
    fail 'an edit borrow lent to edit gained a second address-of'
grep -q 'stage2_bytes_append_range(k_b' "$WORK/borrowed_carrier.c" ||
    fail 'append_range no longer accepts a read source beside an edit destination'
# The rule is about the argument, not the operation, so an owner and a borrow
# in the same slot must lower differently. Asserting only one of the two would
# pass against an emitter that had stopped distinguishing them.
grep -q 'stage2_bytes_assign_zeroed(&k_b' "$WORK/mutation.c" ||
    fail 'an owner reached the producer without its address'
grep -q 'stage2_bytes_assign_zeroed(k_b' "$WORK/mutation.c" &&
    fail 'an owner reached the producer as if it were already a borrow'
grep -q 'stage2_bytes_assign_zeroed(((k_b' "$WORK/parenthesized_carrier.c" ||
    fail 'a parenthesized edit borrow gained a second address-of'
grep -q 'kofun_fn_relay(&((k_b' "$WORK/parenthesized_carrier.c" ||
    fail 'a parenthesized owner was not lent by address'

# ------------------------------------------------------------ the prelude
#
# Extracted from the program the compiler just emitted, ending at the last
# operation the runtime defines.
prelude_end=$(
    awk '/^static inline KofunBytesStatus stage2_bytes_read_file/ {found = 1}
         found && /^\}$/ {print NR; exit}' "$WORK/mutation.c"
)
test -n "$prelude_end" ||
    fail 'the emitted C carries no stage2_bytes_read_file to extract'
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

# #1499. The byte read is an `Int`, and the separate read carrier that used to
# hold its three outcomes is gone with it: no declaration, no tags, no
# constructor. The status keeps its declaration order and gains tag 9 for a
# path the file read could not open or read; tags 6..8 still belong to #1322's
# Text bridge, and no mutation operation may reach them.
grep -q '^static inline int64_t stage2_bytes_byte_at(' "$WORK/prelude.h" ||
    fail 'the byte read does not return int64_t'
grep -qE 'Stage2ByteRead|KOFUN_BYTE_VALUE|KOFUN_BYTE_READ_|kofun_byte_read' \
    "$WORK/prelude.h" &&
    fail 'the retired read carrier is still emitted'
test "$(grep -c 'KOFUN_BYTES_SUCCEEDED = 0' "$WORK/prelude.h")" -eq 1 ||
    fail 'the 0..9 status declaration is no longer emitted exactly once'
test "$(grep -c 'KOFUN_BYTES_FILE_UNREADABLE = 9' "$WORK/prelude.h")" -eq 1 ||
    fail 'the status has no unreadable-file tag 9'
test "$(grep -c '} KofunBytesValue;' "$WORK/prelude.h")" -eq 1 ||
    fail 'the carrier is no longer declared exactly once'

# No mutation operation reaches the Text bridge's three tags. Checked over the
# operations' own text rather than the whole prelude, because the status
# declaration legitimately names all ten.
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
#
# #1499. The file read needs files. Prepared here, once, at the sizes the
# bound is stated in: one byte over the ceiling, exactly at it, five bytes,
# none, and a directory. `missing.bin` is the one that must not exist.
KOFUN_BYTES_MUTATION_READ_DIR="$WORK/read"
export KOFUN_BYTES_MUTATION_READ_DIR
mkdir -p "$KOFUN_BYTES_MUTATION_READ_DIR/directory"
head -c 65537 /dev/zero | tr '\0' 'a' >"$KOFUN_BYTES_MUTATION_READ_DIR/over.bin"
head -c 65536 /dev/zero | tr '\0' 'b' >"$KOFUN_BYTES_MUTATION_READ_DIR/exact.bin"
printf 'Hello' >"$KOFUN_BYTES_MUTATION_READ_DIR/small.bin"
: >"$KOFUN_BYTES_MUTATION_READ_DIR/empty.bin"
rm -f "$KOFUN_BYTES_MUTATION_READ_DIR/missing.bin"
test "$(wc -c <"$KOFUN_BYTES_MUTATION_READ_DIR/over.bin" | tr -d ' ')" -eq 65537 ||
    fail 'the over-the-ceiling file is not 65537 bytes'

# Every read refusal the driver provokes is also a named runtime diagnostic
# on stderr, printed once each because the driver resets the flag between
# them. Their order is the driver's, and the list is exact: an extra line is
# a refusal nobody asked for, a missing one is a silent failure.
{
    printf 'error[R025]: bounded Bytes byte read out of range\n'
    printf 'error[R025]: bounded Bytes byte read out of range\n'
    printf 'error[R025]: bounded Bytes byte read out of range\n'
    printf 'error[R025]: bounded Bytes byte read out of range\n'
    printf 'error[R026]: bounded Bytes file read cannot read path\n'
    printf 'error[R026]: bounded Bytes file read cannot read path\n'
    printf 'error[R027]: bounded Bytes file read exceeds 65536 bytes\n'
    printf 'error[R025]: bounded Bytes byte read out of range\n'
} >"$WORK/driver.expected.stderr"
for level in 0 2
do
    "${CC:-cc}" -std=c11 "-O$level" -Wall -Wextra -Werror -pedantic \
        -I "$WORK" -I "$ROOT/unicode" "$CASES/mutation_driver.c" \
        -o "$WORK/driver.O$level" 2>"$WORK/driver.O$level.cc" ||
        fail "the mutation driver did not build at -O$level"
    "$WORK/driver.O$level" >"$WORK/driver.O$level.out" \
        2>"$WORK/driver.O$level.stderr" ||
        fail "the mutation contract failed at -O$level: $(head -n 1 "$WORK/driver.O$level.out")"
done
printf 'ok\n' >"$WORK/driver.expected"
for required_level in 0 2
do
    cmp "$WORK/driver.expected" "$WORK/driver.O$required_level.out" ||
        fail "the exact strict -O$required_level driver result is absent"
    cmp "$WORK/driver.expected.stderr" "$WORK/driver.O$required_level.stderr" ||
        fail "the strict -O$required_level driver's read refusals are not exactly the named diagnostics"
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
"$WORK/driver.oom" >"$WORK/driver.oom.out" 2>"$WORK/driver.oom.stderr" ||
    fail "the allocation-failure contract failed: $(head -n 1 "$WORK/driver.oom.out")"
{
    printf 'error[R025]: bounded Bytes byte read out of range\n'
    printf 'error[R028]: bounded Bytes file read cannot allocate\n'
} >"$WORK/driver.oom.expected.stderr"
cmp "$WORK/driver.oom.expected.stderr" "$WORK/driver.oom.stderr" ||
    fail 'the spent-budget file read is not exactly its named diagnostic'

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
    cat "$WORK/$stem.stdout" "$WORK/$stem.stderr" \
        >"$WORK/$stem.reported"
}

refuses same_carrier \
    'error[E2S177]: Stage 2 `stage2_bytes_append_range` needs two distinct Bytes values'
refuses unresolved_carrier \
    'error[E2S177]: Stage 2 bounded Bytes operations need a named carrier binding'
refuses temporary_carrier \
    'error[E2S177]: Stage 2 bounded Bytes operations need a named carrier binding'
refuses parenthesized_same_carrier \
    'error[E2S177]: Stage 2 `stage2_bytes_append_range` needs two distinct Bytes values'
refuses parenthesized_temporary \
    'error[E2S177]: Stage 2 bounded Bytes operations need a named carrier binding'
refuses wrapper_conflict_edit_read \
    'error[E2S180]: Stage 2 Bytes argument slots 1 (edit) and 2 (read) must use distinct owners'
refuses wrapper_conflict_edit_edit \
    'error[E2S180]: Stage 2 Bytes argument slots 1 (edit) and 2 (edit) must use distinct owners'
refuses wrapper_conflict_take_read \
    'error[E2S180]: Stage 2 Bytes argument slots 1 (take) and 2 (read) must use distinct owners'
refuses wrapper_conflict_take_edit \
    'error[E2S180]: Stage 2 Bytes argument slots 1 (take) and 2 (edit) must use distinct owners'
refuses wrapper_conflict_arity \
    'error[E2S17]: Core function `conflict` expects 2 arguments, got 3'
refuses wrapper_conflict_type \
    'error[E2S15]: Core function `conflict` expects Bytes for argument 1, got Int'

# #1517. Each mutating destination owns one exact refusal. Keeping one fixture
# per operation prevents the first failing call in a combined program from
# disguising an unchecked sibling, while the read append_range source remains
# executable in borrowed_carrier above. #1499's `read_file` is the eighth.
for operation in \
    assign_zeroed \
    byte_set \
    clear \
    reserve \
    append \
    append_range \
    append_self \
    read_file
do
    stem=read_to_edit_$operation
    refuses "$stem" \
        "error[E2S178]: Bytes slot \`stage2_bytes_$operation.destination\`: available read, required edit; read-to-edit is forbidden"
done
refuses read_to_edit_ordinary \
    'error[E2S178]: Bytes slot `writes.target`: available read, required edit; read-to-edit is forbidden'
refuses read_to_edit_ordinary_parenthesized \
    'error[E2S178]: Bytes slot `writes.target`: available read, required edit; read-to-edit is forbidden'
refuses read_to_edit_append_parenthesized \
    'error[E2S178]: Bytes slot `stage2_bytes_append.destination`: available read, required edit; read-to-edit is forbidden'
refuses read_to_edit_assign_zeroed_parenthesized \
    'error[E2S178]: Bytes slot `stage2_bytes_assign_zeroed.destination`: available read, required edit; read-to-edit is forbidden'
refuses read_to_edit_long_slot \
    'error[E2S178]: Bytes slot `writes_bytes_targe...on_for_width.target`: available read, required edit; read-to-edit is forbidden'
refuses read_to_edit_labelled_hold \
    'error[E2S158]: labelled-call ABI lowering is owned by #882; fixed-slot checked HIR is available'
refuses read_to_edit_pipeline_hold \
    'error[E2S158]: a pipeline subject whose slot 0 carrier is outside the call-arguments v1 matrix is not checked'
# #1559. Every private carrier operation is legal as the complete expression
# of a discarded statement (the executable fixtures above contain all eight),
# and illegal in every source-value context. The first loop makes the
# operation vocabulary explicit at the boundary: a predicate that forgets one
# operation accepts that row and commits C. The second loop holds the contexts
# independently, including comparison, whose enclosing expression is Bool and
# therefore cannot be caught by changing only builtin return inference.
#
# #1499 moved `byte_at` out of this set and `read_file` into it, so the set is
# still eight, and the context matrix now rides on `reserve`. The first matrix
# also proves the other direction for `byte_at`: a binding of it is accepted
# and prints the byte.
refuses_private_generated() {
    stem=$1
    operation=$2
    source_file="$WORK/$stem.kofun"
    c_file="$WORK/$stem.private.c"
    bin_file="$WORK/$stem.private.bin"
    if "$ROOT/bin/kofun" build "$source_file" -o "$bin_file" \
        --emit-c "$c_file" >"$WORK/$stem.private.stdout" \
        2>"$WORK/$stem.private.stderr"
    then
        fail "$stem was accepted as a source value"
    fi
    grep -qF "error[E2S179]: Stage 2 \`$operation\` does not produce a source value" \
        "$WORK/$stem.private.stdout" "$WORK/$stem.private.stderr" ||
        fail "$stem did not report its private-result E2S179"
    test ! -e "$c_file" || fail "$stem committed C"
    test ! -e "$bin_file" || fail "$stem committed a binary"
    reported=$(sed -n '1p' "$WORK/$stem.private.stdout")
    if test -z "$reported"
    then
        reported=$(sed -n '1p' "$WORK/$stem.private.stderr")
    fi
    width=$(printf '%s\n' "$reported" | wc -c)
    test "$width" -lt 160 ||
        fail "$stem's E2S179 detail exceeds the typed-sidecar bound"
}

while IFS='|' read -r operation call
do
    stem="private-operation-$operation"
    {
        printf '%s\n' \
            'fn main() -> Int {' \
            '    let bytes = stage2_bytes_empty()' \
            '    let other = stage2_bytes_empty()' \
            "    let private_value = $call" \
            '    print(private_value)' \
            '    return 0' \
            '}'
    } >"$WORK/$stem.kofun"
    refuses_private_generated "$stem" "$operation"
done <<'EOF'
stage2_bytes_assign_zeroed|stage2_bytes_assign_zeroed(bytes, 4)
stage2_bytes_read_file|stage2_bytes_read_file(bytes, "missing.bin")
stage2_bytes_byte_set|stage2_bytes_byte_set(bytes, 0, 1)
stage2_bytes_clear|stage2_bytes_clear(bytes)
stage2_bytes_reserve|stage2_bytes_reserve(bytes, 4)
stage2_bytes_append|stage2_bytes_append(bytes, 1)
stage2_bytes_append_range|stage2_bytes_append_range(bytes, other, 0, 0)
stage2_bytes_append_self|stage2_bytes_append_self(bytes, 0, 0)
EOF

while IFS='|' read -r context body
do
    stem="private-context-$context"
    {
        printf '%s\n' \
            'fn identity(value: Int) -> Int {' \
            '    return value' \
            '}' \
            '' \
            'fn main() -> Int {' \
            '    let bytes = stage2_bytes_empty()'
        printf '    %b\n' "$body"
        printf '%s\n' '    return 0' '}'
    } >"$WORK/$stem.kofun"
    refuses_private_generated "$stem" stage2_bytes_reserve
done <<'EOF'
inferred-binding|let value = stage2_bytes_reserve(bytes, 4)
multiline-binding|let value =\nstage2_bytes_reserve(bytes, 4)
annotated-binding|let value: Int = stage2_bytes_reserve(bytes, 4)
print|print(stage2_bytes_reserve(bytes, 4))
return|return stage2_bytes_reserve(bytes, 4)
argument|print(identity(stage2_bytes_reserve(bytes, 4)))
arithmetic|print(stage2_bytes_reserve(bytes, 4) + 1)
condition|if stage2_bytes_reserve(bytes, 4) {\n        print(1)\n    }
multiline-condition|if\nstage2_bytes_reserve(bytes, 4) {\n        print(1)\n    }
comparison|print(stage2_bytes_reserve(bytes, 4) == stage2_bytes_reserve(bytes, 4))
EOF

final_stem=private-context-final-expression
{
    printf '%s\n' \
        'fn private_final(edit bytes: Bytes) -> Int {' \
        '    stage2_bytes_reserve(bytes, 4)' \
        '}' \
        '' \
        'fn main() -> Int {' \
        '    let bytes = stage2_bytes_empty()' \
        '    print(private_final(bytes))' \
        '    return 0' \
        '}'
} >"$WORK/$final_stem.kofun"
refuses_private_generated "$final_stem" stage2_bytes_reserve

# #1499. The same binding shape that refuses every private operation accepts
# the byte read, in every context the matrix above refuses, and the program
# prints the byte. Generated beside the refusals so the two directions of one
# predicate are held by one file.
value_stem=byte-at-source-value
{
    printf '%s\n' \
        'fn identity(value: Int) -> Int {' \
        '    return value' \
        '}' \
        '' \
        'fn last(read bytes: Bytes) -> Int {' \
        '    stage2_bytes_byte_at(bytes, stage2_bytes_len(bytes) - 1)' \
        '}' \
        '' \
        'fn main() -> Int {' \
        '    let bytes = stage2_bytes_empty()' \
        '    stage2_bytes_append(bytes, 7)' \
        '    stage2_bytes_append(bytes, 200)' \
        '    let value = stage2_bytes_byte_at(bytes, 0)' \
        '    let annotated: Int = stage2_bytes_byte_at(bytes, 1)' \
        '    print(value)' \
        '    print(annotated)' \
        '    print(identity(stage2_bytes_byte_at(bytes, 1)) + 1)' \
        '    if stage2_bytes_byte_at(bytes, 0) == 7 {' \
        '        print(1)' \
        '    }' \
        '    print(last(bytes))' \
        '    return 0' \
        '}'
} >"$WORK/$value_stem.kofun"
"$ROOT/bin/kofun" build "$WORK/$value_stem.kofun" -o "$WORK/$value_stem.bin" \
    --emit-c "$WORK/$value_stem.c" >"$WORK/$value_stem.stdout" \
    2>"$WORK/$value_stem.stderr" ||
    fail "a byte_at source value was refused: $(head -n 1 "$WORK/$value_stem.stderr")"
"$WORK/$value_stem.bin" >"$WORK/$value_stem.out" 2>&1 ||
    fail 'the byte_at source-value program did not run'
printf '7\n200\n201\n1\n200\n' >"$WORK/$value_stem.expected"
cmp "$WORK/$value_stem.expected" "$WORK/$value_stem.out" ||
    fail 'the byte_at source-value program printed the wrong bytes'


# The two reasons are distinct sentences. One reason for both shapes would let
# a later change to either stop being visible.
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
for reported in same_carrier unresolved_carrier temporary_carrier \
    parenthesized_same_carrier parenthesized_temporary \
    wrapper_conflict_edit_read wrapper_conflict_edit_edit \
    wrapper_conflict_take_read wrapper_conflict_take_edit \
    wrapper_conflict_arity wrapper_conflict_type
do
    width=$(head -n 1 "$WORK/$reported.reported" | wc -c)
    test "$width" -lt 160 ||
        fail "the $reported refusal is $width bytes; the sidecar truncates at 160"
done

for stem in read_to_edit_ordinary read_to_edit_ordinary_parenthesized \
    read_to_edit_append_parenthesized \
    read_to_edit_assign_zeroed_parenthesized read_to_edit_long_slot
do
    printf 'stale\n' >"$WORK/$stem.repeat.c"
    printf 'stale\n' >"$WORK/$stem.repeat.bin"
    rm -f "$WORK/$stem.repeat.c" "$WORK/$stem.repeat.bin"
    "$ROOT/bin/kofun" build "$CASES/$stem.kofun" \
        -o "$WORK/$stem.repeat.bin" \
        --emit-c "$WORK/$stem.repeat.c" \
        >"$WORK/$stem.repeat" 2>&1 || true
    cmp "$WORK/$stem.reported" "$WORK/$stem.repeat" ||
        fail "$stem reported differently on a second run"
    width=$(head -n 1 "$WORK/$stem.reported" | wc -c)
    test "$width" -lt 160 ||
        fail "$stem refusal is $width bytes; the sidecar truncates at 160"
    test ! -e "$WORK/$stem.repeat.c" ||
        fail "$stem committed C on its repeat"
    test ! -e "$WORK/$stem.repeat.bin" ||
        fail "$stem committed a binary on its repeat"
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
# requested binary behind only after refusal 1 (ordinary), 26 (first repeat), or
# 27 (second repeat). Each child must stop at its selected assertion and name
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
    # #1499 added one refusal (`read_to_edit_read_file`) ahead of the repeat
    # loop, so the first repeated refusal is the 27th build the child sees.
    prove_binary_assertion 27 first-repeat \
        'the first repeated refusal committed a binary'
    prove_binary_assertion 28 second-repeat \
        'the second repeated refusal committed a binary'
fi
for operation in \
    assign_zeroed \
    byte_set \
    clear \
    reserve \
    append \
    append_range \
    append_self \
    read_file
do
    stem=read_to_edit_$operation
    printf 'stale\n' >"$WORK/$stem.repeat.c"
    printf 'stale\n' >"$WORK/$stem.repeat.bin"
    rm -f "$WORK/$stem.repeat.c" "$WORK/$stem.repeat.bin"
    "$ROOT/bin/kofun" build "$CASES/$stem.kofun" \
        -o "$WORK/$stem.repeat.bin" --emit-c "$WORK/$stem.repeat.c" \
        >"$WORK/$stem.repeat" 2>&1 || true
    cat "$WORK/$stem.stdout" "$WORK/$stem.stderr" \
        >"$WORK/$stem.reported"
    cmp "$WORK/$stem.reported" "$WORK/$stem.repeat" ||
        fail "$stem reported differently on a second run"
    width=$(head -n 1 "$WORK/$stem.reported" | wc -c)
    test "$width" -lt 160 ||
        fail "$stem refusal is $width bytes; the sidecar truncates at 160"
    test ! -e "$WORK/$stem.repeat.c" ||
        fail "$stem committed C on its repeat"
    test ! -e "$WORK/$stem.repeat.bin" ||
        fail "$stem committed a binary on its repeat"
done
printf 'stale\n' >"$WORK/wrapper-repeat.c"
printf 'stale\n' >"$WORK/wrapper-repeat.bin"
rm -f "$WORK/wrapper-repeat.c" "$WORK/wrapper-repeat.bin"
"$ROOT/bin/kofun" build "$CASES/wrapper_conflict_edit_read.kofun" \
    -o "$WORK/wrapper-repeat.bin" --emit-c "$WORK/wrapper-repeat.c" \
    >"$WORK/wrapper-repeat.1" 2>&1 || true
test ! -e "$WORK/wrapper-repeat.c" ||
    fail 'the first repeated wrapper refusal committed C'
test ! -e "$WORK/wrapper-repeat.bin" ||
    fail 'the first repeated wrapper refusal committed a binary'
printf 'stale\n' >"$WORK/wrapper-repeat.c"
printf 'stale\n' >"$WORK/wrapper-repeat.bin"
rm -f "$WORK/wrapper-repeat.c" "$WORK/wrapper-repeat.bin"
"$ROOT/bin/kofun" build "$CASES/wrapper_conflict_edit_read.kofun" \
    -o "$WORK/wrapper-repeat.bin" --emit-c "$WORK/wrapper-repeat.c" \
    >"$WORK/wrapper-repeat.2" 2>&1 || true
test ! -e "$WORK/wrapper-repeat.c" ||
    fail 'the second repeated wrapper refusal committed C'
test ! -e "$WORK/wrapper-repeat.bin" ||
    fail 'the second repeated wrapper refusal committed a binary'
cmp "$WORK/wrapper-repeat.1" "$WORK/wrapper-repeat.2" ||
    fail 'the wrapper identity refusal reported differently on a second run'

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
    'PASS: the operations, the zeroed producer, a relay, and edit-to-read/edit lending all reach a borrow without a second address-of, while a local owner is still lent by address' \
    'PASS: read/read sharing and distinct owners through one- and two-level wrappers execute, while edit/read, edit/edit, take/read, and take/edit sharing refuse as E2S180 without C or binary artifacts; arity diagnostics retain precedence' \
    'PASS: complete nested parentheses preserve one named Bytes BindingId through mutation builtins and a declared relay; the direct same-owner reason remains E2S177 and parenthesized temporaries remain unnamed' \
    'PASS: the operations the two halves of the pair admit and the ones the emitted runtime defines are one set, each defined exactly once' \
    'PASS: the byte read returns int64_t and the retired read carrier is not emitted; the 0..9 status and the carrier are still declared once each' \
    'PASS: every byte_at refusal, missing, unreadable, and over-the-ceiling file read is exactly one named runtime diagnostic with the carrier preserved; small, ceiling-sized, and empty files replace the bytes, and a spent budget refuses the read whole' \
    'PASS: no mutation operation reaches a Text-bridge status tag' \
    'PASS: current-file declarations and lexical callables named stage2_bytes_* outrank special builtin lowering, while undeclared controls retain it' \
    'PASS: exact bytes 0x00/0x7f/0x80/0xff are append-attempted at lengths 0, 1, 255, 16384, and 65536 under strict O0/O2 and ASan/UBSan, succeeding below the ceiling and preserving it on refusal; every named range, byte, and capacity refusal preserves the named carrier pointers and bytes' \
    'PASS: growth 0->16, every doubling edge, the ceiling, one over it, reserve, and clear-capacity preservation hold; the injected-OOM append_range call is live-proved and preserves pointer and bytes for source and destination too' \
    'PASS: one value in both positions of append_range, an unresolved identity, and a temporary in a carrier slot are refused as E2S177, commit no C and are mutation-proved to commit no binary, fit the sidecar detail bound, and the same-carrier refusal reports identically on a second run' \
    'PASS: read-to-edit is refused as E2S178 for all eight mutating destinations before C or binary publication, with bounded deterministic detail; append_range still accepts its read source' \
    'PASS: all eight compiler-private Bytes outcomes are accepted only as complete discarded expression statements; every operation and value context refuses as E2S179 with no C or binary artifact, while byte_at is accepted in each of those contexts and prints the byte'
