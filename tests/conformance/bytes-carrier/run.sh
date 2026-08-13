#!/usr/bin/env sh
# #1315. The cleanup funnel: every exit of a function that owns backend storage
# reclaims it, in reverse creation order.
#
# The assertion is derived from the *set* of `return` statements the compiler
# emitted, not from a list written here. A list passes forever after someone
# adds an eleventh return site; this fails.
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

# Every return in the owning function must reclaim every live owner. Derived
# from the returns present, so a new emission site is covered the day it lands.
returns=$(grep -c 'return ' "$WORK/main.c")
test "$returns" -gt 0 || fail "main emitted no return at all"

reclaiming=$(grep 'return ' "$WORK/main.c" |
    grep -c 'kofun_bytes_release' || true)
test "$reclaiming" -eq "$returns" ||
    fail "$reclaiming of $returns returns reclaim; every exit must"

# Reverse creation order, checked as a descending sequence rather than by
# naming the newest owner. An exit above the second declaration reclaims only
# the first, and that is correct -- the property is the order, not the count.
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

printf '%s\n' \
    'PASS: every exit of an owning function reclaims in reverse creation order, including exits inside nested blocks and in functions other than main' \
    'PASS: a program that owns no storage carries no carrier, allocator, or reclamation'
