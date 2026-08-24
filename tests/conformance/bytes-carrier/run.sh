#!/usr/bin/env sh
# #1315. The cleanup funnel over the tracked owner fixtures: every selected
# emitted return contains a release, and released ids in the straight-line
# two-owner fixture descend.
#
# The return set is derived from emitted C rather than copied into this script,
# so a new selected return must carry a release. This does not derive the full
# set of live owners at each return or prove that every one is released.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CASES="$ROOT/tests/conformance/bytes-carrier"
WORK=${KOFUN_BYTES_CARRIER_WORK:-"$ROOT/build/bytes-carrier"}

fail() {
    printf '%s\n' "FAIL: bytes carrier: $1" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"

"$ROOT/bin/kofun" build "$CASES/owner.kofun" -o "$WORK/owner.bin" \
    --emit-c "$WORK/owner.c" >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    fail "the two-owner program did not build: $(head -1 "$WORK/build.stderr")"

"$WORK/owner.bin" >"$WORK/owner.stdout" 2>&1 ||
    fail "the two-owner program did not run"
cmp "$CASES/owner.stdout" "$WORK/owner.stdout" ||
    fail "the two-owner program printed unexpected output"

# The owning function is the one whose body declares the carrier.
awk '/^int main\(void\) \{/,/^\}/' "$WORK/owner.c" >"$WORK/main.c"
grep -q 'KofunBytesValue k_b' "$WORK/main.c" ||
    fail "main declares no Bytes carrier; the fixture no longer owns storage"

owners=$(grep -c 'KofunBytesValue k_b[0-9]* = ' "$WORK/main.c")
test "$owners" -eq 2 ||
    fail "expected two owning locals, found $owners"

# Every selected return in this owning fixture must contain a release. Derived
# from the returns present, so a new emission site is covered the day it lands;
# the complete live-owner set is not derived here.
returns=$(grep -c 'return ' "$WORK/main.c")
test "$returns" -gt 0 || fail "main emitted no return at all"

reclaiming=$(grep 'return ' "$WORK/main.c" |
    grep -c 'kofun_bytes_release' || true)
test "$reclaiming" -eq "$returns" ||
    fail "$reclaiming of $returns selected returns contain a release"

# Descending released ids are checked without naming the newest owner. This
# checks the order of ids present on a line, not whether every live owner is
# present.
grep 'return ' "$WORK/main.c" | while IFS= read -r line; do
    ids=$(printf '%s\n' "$line" |
        grep -o 'k_b[0-9]*' | sed 's/k_b//')
    previous=""
    for id in $ids; do
        if [ -n "$previous" ] && [ "$id" -ge "$previous" ]; then
            fail "an exit released k_b$previous before k_b$id; reclamation must descend"
        fi
        previous=$id
    done
done

# ------------------------------------------------ exits below the top level
#
# #1315. The straight-line fixture above cannot distinguish a correct emitter
# from one that reclaims only at statement-level returns in `main`. Two real
# defects hid behind exactly that gap and both are fixtures now:
#
#   1. `lower_body` recurses for an `if`/`else`/`while` body and for a match
#      arm, and restarted the funnel empty, so a `return` inside one released
#      nothing.
#   2. `compiler.c` dropped `bytes_cleanup` on the non-`main` value return
#      while `compiler.kofun` emitted it on both sides -- the pair had
#      diverged, and `bin/kofun` runs the C half.
#
# Neither is visible without an owning function that is not `main` and whose
# exits are not all at the top level. The assertions are the same ones; only
# the data is new.
"$ROOT/bin/kofun" build "$CASES/branching_owner.kofun" \
    -o "$WORK/branching.bin" --emit-c "$WORK/branching.c" >/dev/null 2>&1 ||
    fail "the branching owner did not build"
"$WORK/branching.bin" >"$WORK/branching.stdout" ||
    fail "the branching owner did not run"
cmp "$CASES/branching_owner.stdout" "$WORK/branching.stdout" ||
    fail "the branching owner printed the wrong value"

sed -n '/^static int64_t kofun_fn_classify(int64_t k_b0) {$/,/^}$/p' \
    "$WORK/branching.c" >"$WORK/classify.c"
grep -q 'KofunBytesValue k_b' "$WORK/classify.c" ||
    fail "classify declares no Bytes carrier; the fixture no longer owns storage"

branch_returns=$(grep -c 'return ' "$WORK/classify.c")
test "$branch_returns" -gt 4 ||
    fail "expected several exits in classify, found $branch_returns"
branch_reclaiming=$(grep 'return ' "$WORK/classify.c" |
    grep -c 'kofun_bytes_release' || true)
test "$branch_reclaiming" -eq "$branch_returns" ||
    fail "$branch_reclaiming of $branch_returns exits in a non-main owning function reclaim; every exit must"

# The composition case: `if` -> enum match arm -> `while` -> `return`, three
# nested inheritances of the funnel rather than one. `lower_enum_match` recurses
# into `lower_body` for an arm body, so the arm is a fourth recursion site and
# the only one the fixtures above do not reach. Measured correct before this
# fixture existed, so this is a regression guard and is labelled as one.
"$ROOT/bin/kofun" build "$CASES/nested_match_owner.kofun" \
    -o "$WORK/nested.bin" --emit-c "$WORK/nested.c" >/dev/null 2>&1 ||
    fail "the nested match owner did not build"
"$WORK/nested.bin" >"$WORK/nested.stdout" ||
    fail "the nested match owner did not run"
cmp "$CASES/nested_match_owner.stdout" "$WORK/nested.stdout" ||
    fail "the nested match owner printed the wrong value"

sed -n '/^static int64_t kofun_fn_classify/,/^}$/p' "$WORK/nested.c" \
    >"$WORK/nested_classify.c"
nested_returns=$(grep -c 'return ' "$WORK/nested_classify.c")
test "$nested_returns" -gt 8 ||
    fail "expected many exits in the nested owner, found $nested_returns"
nested_reclaiming=$(grep 'return ' "$WORK/nested_classify.c" |
    grep -c 'kofun_bytes_release' || true)
test "$nested_reclaiming" -eq "$nested_returns" ||
    fail "$nested_reclaiming of $nested_returns exits three levels deep reclaim; every exit must"

# A source that owns nothing must be untouched by any of this: no allocator, no
# carrier, no reclamation. That is what keeps the funnel from taxing every
# program, and what tests/conformance/call-arguments/run.sh refuses.
printf 'fn main() -> Int {\n    print(0)\n    return 0\n}\n' >"$WORK/plain.kofun"
"$ROOT/bin/kofun" build "$WORK/plain.kofun" -o "$WORK/plain.bin" \
    --emit-c "$WORK/plain.c" >/dev/null 2>&1 ||
    fail "the ownerless program did not build"
if grep -qE 'KofunBytesValue|kofun_bytes_release|stdlib\.h' "$WORK/plain.c"
then
    fail "a program owning no storage still carries the Bytes prelude"
fi

# #1556. Seventy-one owners crossed the seed's private 2048-byte release-list
# boundary and borrowed E2S170 from an unrelated carrier-crossing rule. The
# Kofun half always used growable Text. Generate the exact old boundary here,
# compile it, and count the releases so accepting by dropping cleanup cannot
# satisfy the test.
many_source="$WORK/many_owners.kofun"
printf 'fn main() -> Int {\n' >"$many_source"
many_index=0
while [ "$many_index" -lt 71 ]; do
    printf '    let b%s = stage2_bytes_empty()\n' "$many_index" \
        >>"$many_source"
    many_index=$((many_index + 1))
done
printf '    return 0\n}\n' >>"$many_source"
"$ROOT/bin/kofun" build "$many_source" -o "$WORK/many_owners.bin" \
    --emit-c "$WORK/many_owners.c" >"$WORK/many_owners.stdout" \
    2>"$WORK/many_owners.stderr" ||
    fail "seventy-one Bytes owners did not build: $(head -1 "$WORK/many_owners.stderr")"
"$WORK/many_owners.bin" >/dev/null 2>"$WORK/many_owners.run.stderr" ||
    fail 'seventy-one Bytes owners did not run'
test ! -s "$WORK/many_owners.run.stderr" ||
    fail 'seventy-one Bytes owners wrote runtime stderr'
many_releases=$(grep 'return ' "$WORK/many_owners.c" | tail -1 |
    grep -o 'kofun_bytes_release' | wc -l | tr -d ' ')
test "$many_releases" -eq 71 ||
    fail "the final exit releases $many_releases of 71 Bytes owners"

# ---------------------------------------------------------------------------
# #1315. The transactional producer, the three parameter crossings, and the
# nine refusal reasons.

# Lower and run one case under the sanitizers, against its golden. `-O0` and
# `-O2` are both built from the same emitted C and must agree: the criterion
# asks for identical execution, and a carrier whose reclamation depended on an
# optimisation level would satisfy neither.
executes() {
    stem=$1
    label=$2
    "$ROOT/bin/kofun" build "$CASES/$stem.kofun" -o "$WORK/$stem.bin" \
        --emit-c "$WORK/$stem.c" >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr" ||
        fail "$label did not build: $(head -1 "$WORK/$stem.stderr")"
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

# #1569. The typed-return arms. `branching_owner` above proves the funnel for
# `Int` returns; the six typed arms are a separate code path, and three of them
# -- `List[Int]`, `Int?` and a concrete enum -- hard-coded the zero constant
# into the trap guard where their neighbours interpolated `failure_result`. The
# two `let` guards released, the success path released, only the return trap
# did not. `Text` was already right, which is why it is here as the control:
# a fix that changed all six would pass a test that only checked the three.
#
# Derived from the returns present, like every other assertion in this file, so
# a seventh arm is covered the day it lands.
"$ROOT/bin/kofun" build "$CASES/typed_return_owner.kofun" \
    -o "$WORK/typed.bin" --emit-c "$WORK/typed.c" >/dev/null 2>&1 ||
    fail "the typed-return owner did not build"
"$WORK/typed.bin" >"$WORK/typed.stdout" ||
    fail "the typed-return owner did not run"
cmp "$CASES/typed_return_owner.stdout" "$WORK/typed.stdout" ||
    fail "the typed-return owner printed unexpected output"

for owner in as_enum as_list as_optional as_text
do
    sed -n "/^static .* kofun_fn_$owner(.*) {\$/,/^}\$/p" "$WORK/typed.c" \
        >"$WORK/typed.$owner.c"
    grep -q 'KofunBytesValue k_b' "$WORK/typed.$owner.c" ||
        fail "$owner declares no Bytes carrier; the fixture no longer owns storage"
    typed_returns=$(grep -c 'return ' "$WORK/typed.$owner.c")
    test "$typed_returns" -gt 0 || fail "$owner emitted no return at all"
    typed_reclaiming=$(grep 'return ' "$WORK/typed.$owner.c" |
        grep -c 'kofun_bytes_release' || true)
    test "$typed_reclaiming" -eq "$typed_returns" ||
        fail "$owner reclaims at $typed_reclaiming of $typed_returns exits; every typed return must"
done

executes zeroed_lengths 'the four zeroed lengths and empty'
executes transferred_owner 'a take transfer of real storage'
executes produced_owner 'a proven-fresh producer and a relayed one'

# The status lives in the emitted C, so it is proved there. The prelude is
# extracted from a program the compiler just emitted rather than restated
# here, so this measures the shipped bytes.
prelude_end=$(
    awk '/^static inline KofunBytesStatus stage2_bytes_assign_zeroed/ {found = 1}
         found && /^\}$/ {print NR; exit}' "$WORK/zeroed_lengths.c"
)
test -n "$prelude_end" ||
    fail 'the emitted C carries no stage2_bytes_assign_zeroed to extract'
sed -n "1,${prelude_end}p" "$WORK/zeroed_lengths.c" >"$WORK/prelude.h"
grep -q 'KOFUN_BYTES_TEXT_LIMIT_EXCEEDED = 8' "$WORK/prelude.h" ||
    fail 'the extracted prelude is missing the 0..8 status declaration'
test "$(grep -c 'KOFUN_BYTES_SUCCEEDED = 0' "$WORK/prelude.h")" -eq 1 ||
    fail 'the 0..8 status declaration is not emitted exactly once'
grep -q 'KOFUN_BYTES_CONSUMED' "$WORK/prelude.h" &&
    fail 'the status declaration carries an impossible consumed tag'

for budget in none 1
do
    if test "$budget" = none
    then inject=
    else inject="-DKOFUN_BYTES_INJECT_ALLOC_BUDGET=$budget"
    fi
    # shellcheck disable=SC2086
    "${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic $inject \
        -I "$WORK" -I "$ROOT/unicode" "$CASES/status_driver.c" \
        -o "$WORK/status.$budget" 2>"$WORK/status.$budget.cc" ||
        fail "the status driver did not build (allocation budget $budget)"
    "$WORK/status.$budget" >"$WORK/status.$budget.out" 2>&1 ||
        fail "status/detail or destination preservation failed (budget $budget): $(head -1 "$WORK/status.$budget.out")"
done

# The criterion asks for the transfer to be *visible*, not merely correct. A
# transfer that reclaimed correctly by some other means would satisfy the
# sanitizers and leave nothing for a reader to find, so the emitted C is
# checked for the move itself.
grep -q 'kofun_bytes_take(&' "$WORK/transferred_owner.c" ||
    fail 'the take crossing does not move the fields; the caller slot is never emptied'
grep -q 'KofunBytesValue kofun_result = kofun_bytes_take(&' \
    "$WORK/produced_owner.c" ||
    fail 'the terminal return does not take before it releases'
# Take, then release, then return -- in that order on one line of emitted C.
# The reverse order frees the storage the return is handing to the caller, and
# it is the order that reads more naturally, so it is worth pinning.
tr -d '\n' <"$WORK/produced_owner.c" |
    grep -qE 'kofun_result = kofun_bytes_take\(&[A-Za-z0-9_]+\);.*kofun_bytes_release\(&[A-Za-z0-9_]+\); *return kofun_result;' ||
    fail 'the terminal return does not take, then release, then return'

# The injected-failure edge under the sanitizers as well as under -Werror. The
# criterion names ASan/LSan/UBSan across every exit *including* injected
# allocation failure, and the -Werror build above proves the values, not the
# memory.
"${CC:-cc}" -std=c11 -O1 -g -fsanitize=address,undefined \
    -DKOFUN_BYTES_INJECT_ALLOC_BUDGET=1 -I "$WORK" -I "$ROOT/unicode" \
    "$CASES/status_driver.c" -o "$WORK/status.asan" \
    2>"$WORK/status.asan.cc" ||
    fail 'the status driver did not build under the sanitizers'
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$WORK/status.asan" >"$WORK/status.asan.out" 2>&1 ||
    fail "the injected allocation failure edge is not sanitizer-clean: $(head -1 "$WORK/status.asan.out")"

# Every refusal names its own reason. Sharing one reason across seven shapes
# would let a slice that admits one silently change what the others report.
refuses() {
    stem=$1
    expected=$2
    rm -f "$WORK/$stem.c"
    if "$ROOT/bin/kofun" build "$CASES/$stem.kofun" -o "$WORK/$stem.bin" \
        --emit-c "$WORK/$stem.c" >"$WORK/$stem.stdout" 2>"$WORK/$stem.stderr"
    then
        fail "$stem was accepted"
    fi
    grep -qF "$expected" "$WORK/$stem.stdout" "$WORK/$stem.stderr" ||
        fail "$stem did not report: $expected"
    test ! -e "$WORK/$stem.c" ||
        fail "$stem committed C"
}

refuses alias_initializer \
    'alias for `alias` (alias initializer)'
refuses branch_owner \
    'alias for `inside` (branch mismatch)'
refuses loop_owner \
    'alias for `carried` (loop-carried storage)'
refuses recursive_producer \
    'alias for `owned` (recursive summary)'
refuses conditional_producer \
    'alias for `owned` (branch mismatch)'
refuses escaping_return \
    'alias for `escaped` (escaping return)'
refuses copied_parameter \
    'alias for `b` (backend limitation)'

# A refusal must say the same thing twice. A message built from a walk that
# depends on iteration order, or on a buffer reused between runs, drifts
# between invocations and the first reading looks like a real change.
"$ROOT/bin/kofun" build "$CASES/alias_initializer.kofun" \
    -o "$WORK/repeat.bin" >"$WORK/repeat.1" 2>&1 || true
"$ROOT/bin/kofun" build "$CASES/alias_initializer.kofun" \
    -o "$WORK/repeat.bin" >"$WORK/repeat.2" 2>&1 || true
cmp "$WORK/repeat.1" "$WORK/repeat.2" ||
    fail 'the same refusal reported differently on a second run'

# Two of the nine reasons have no source program that reaches them, and this
# records which rule gets there first. `escaping store` and `escaping capture`
# would need `Bytes` to be an admitted record field type and a capturable
# binding; both are refused earlier, under messages that name the actual rule
# rather than a backend limit.
#
# Asserting E2S170 for either would have produced a fixture that passes today
# against a compiler that never implements that reason.
printf 'type Box = { held: Bytes }\nfn main() -> Int {\n    print(0)\n    return 0\n}\n' \
    >"$WORK/stored.kofun"
"$ROOT/bin/kofun" build "$WORK/stored.kofun" -o "$WORK/stored.bin" \
    >"$WORK/stored.stdout" 2>"$WORK/stored.stderr" &&
    fail 'a Bytes record field was accepted'
grep -q 'E2S32' "$WORK/stored.stdout" "$WORK/stored.stderr" ||
    fail 'a Bytes record field no longer stops at E2S32; escaping store may now be reachable'

printf 'fn apply(v: Int, f: Int -> Int) -> Int {\n    return f(v)\n}\nfn peek(read b: Bytes) -> Int {\n    return 1\n}\nfn main() -> Int {\n    let owned = stage2_bytes_empty()\n    print(apply(1, (x) => peek(owned)))\n    return 0\n}\n' \
    >"$WORK/captured.kofun"
"$ROOT/bin/kofun" build "$WORK/captured.kofun" -o "$WORK/captured.bin" \
    >"$WORK/captured.stdout" 2>"$WORK/captured.stderr" &&
    fail 'a captured Bytes owner was accepted'
grep -q 'E2S96' "$WORK/captured.stdout" "$WORK/captured.stderr" ||
    fail 'a captured Bytes owner no longer stops at E2S96; escaping capture may now be reachable'

printf '%s\n' \
    'PASS: every selected owning-function exit contains a release; released ids descend in the straight-line two-owner fixture, and nested and non-main cleanup paths execute' \
    'PASS: a function returning List[Int], Int?, a concrete enum or Text reclaims its owner on the failure path of the return trap as well as on the let guards and the success path' \
    'PASS: a program that owns no storage carries no carrier, allocator, or reclamation' \
    'PASS: empty and zeroed 1/255/16384/65536 execute identically at -O0 and -O2 under ASan/UBSan; 65537, a negative length, and an injected allocation failure return their exact tag and detail, leave destination storage non-null, and preserve its asserted length, capacity, and marker byte' \
    'PASS: a take transfer and a proven-fresh producer reclaim exactly once with no leak, use-after-free, or double free' \
    'PASS: the 0..8 status declaration is emitted once and carries no consumed tag' \
    'PASS: the take crossing and the terminal return are visible in the emitted C as take-then-release-then-return, and the injected allocation failure edge is sanitizer-clean' \
    'PASS: a refusal reports identically on a second run' \
    'PASS: seven refusal shapes each report their own E2S170 reason and commit no C; escaping store and escaping capture are refused earlier, by E2S32 and E2S96'
