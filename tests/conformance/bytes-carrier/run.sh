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
    'PASS: every exit of an owning function reclaims in reverse creation order' \
    'PASS: a program that owns no storage carries no carrier, allocator, or reclamation'
