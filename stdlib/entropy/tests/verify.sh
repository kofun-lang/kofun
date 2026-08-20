#!/bin/sh
set -eu

# #1511. The secure-randomness boundary.
#
# Three instruments, because the canonical adapter cannot be compiled or run:
# `bin/kofun check` on any file in stdlib/linux_x86_64 stops at its first
# `import`, and `trusted intrinsic` is refused at top level in both pipelines,
# so `raw_getrandom` is unreachable from any compilable program.
#
#   1. source properties on the adapter -- the rules a reader must be able to
#      confirm by looking, asserted so they cannot quietly stop being true;
#   2. an executable Int-Core projection of the loop, driven by a scripted
#      sequence of syscall returns, against a golden;
#   3. an independent C11 oracle over the same scripts, compared byte for byte,
#      so a wrong loop has to be written twice to pass.
#
# What this does NOT prove is stated rather than implied: that the real
# `getrandom(2)` is called with the right arguments. That is the same gap the
# file adapter has, and it is closed the same way -- by a committed native image
# -- which this gate does not add.

entropy_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$entropy_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-entropy-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'entropy boundary: FAIL: %s\n' "$*" >&2
    exit 1
}

adapter="$entropy_dir/linux_x86_64.kofun"
test -f "$adapter" || fail 'the Linux entropy adapter is missing'

# ------------------------------------------------------------ source properties

grep -Fq 'fn entropy_fill(edit destination: Bytes) -> Result[Void, EntropyError]' \
    "$adapter" ||
    fail 'entropy_fill does not have the complete-or-error signature'

grep -Fq 'Err(error) if error.errno == EINTR' "$adapter" ||
    fail 'the fill loop does not retry EINTR'

grep -Fq 'abi_bytes_edit_address(destination, offset)' "$adapter" ||
    fail 'the fill loop does not continue from the offset already filled'

grep -Fq 'raw_getrandom(address, total - offset, 0)' "$adapter" ||
    fail 'the fill loop does not request exactly the bytes still missing with flags 0'

grep -Fq 'while offset < total' "$adapter" ||
    fail 'the loop condition is not the zero-length case'

grep -Fq 'return Err(EntropyImpossibleCount(received))' "$adapter" ||
    fail 'a count of zero or one past the remaining space is not refused'

grep -Fq 'if received <= 0 || received > total - offset' "$adapter" ||
    fail 'the impossible-count guard does not cover both directions'

# One entropy call in the file, and no second source of nondeterminism. A
# fallback is the failure this capability exists to make impossible, so it is
# checked by absence rather than trusted to a comment.
[ "$(grep -c 'raw_getrandom(' "$adapter")" -eq 1 ] ||
    fail 'the adapter does not obtain entropy at exactly one point'
# `if` rather than `grep … && fail`: a `for` loop whose last command exits 1 is
# a standalone failing command under `set -e`, so the convenient spelling would
# end this gate silently at the first name that is correctly absent.
for forbidden in urandom clock_gettime raw_time random_next process_id getpid
do
    if grep -Fq "$forbidden" "$adapter"; then
        fail "the adapter names a fallback source: $forbidden"
    fi
done

# The seeding adapter keeps its own rule. #1511 lives outside stdlib/random
# precisely so that assertion is not weakened, so the assertion itself is
# checked here rather than only being left alone.
grep -Fq "fail 'system entropy must remain in one explicit adapter'" \
    "$repo_dir/stdlib/random/tests/verify.sh" ||
    fail 'the one-explicit-adapter assertion in stdlib/random is missing or reworded'
[ "$(grep -c 'raw_getrandom(' "$repo_dir/stdlib/random/linux_x86_64.kofun")" -eq 0 ] ||
    fail 'stdlib/random obtained entropy directly instead of through process.kofun'

# The documentation sentence this capability exists to make true.
grep -Fq 'entropy_fill' "$repo_dir/stdlib/random/README.md" ||
    fail 'stdlib/random/README.md still sends security-sensitive callers nowhere'

printf 'entropy adapter source properties: PASS\n'

# --------------------------------------------------------------- the projection

"$repo_dir/bin/kofun" run "$entropy_dir/tests/checkpoint.kofun" \
    >"$work/checkpoint.stdout"
cmp "$entropy_dir/tests/checkpoint.stdout" "$work/checkpoint.stdout" ||
    fail 'the projected fill loop differs from its golden'

# Named cases, so a golden that changes shape is not silently re-blessed.
[ "$(sed -n '14p' "$work/checkpoint.stdout")" -eq 2 ] ||
    fail 'an EINTR was surfaced instead of retried'
[ "$(sed -n '24p' "$work/checkpoint.stdout")" -eq 0 ] ||
    fail 'an empty destination called the syscall'
[ "$(sed -n '27p' "$work/checkpoint.stdout")" -eq 1 ] ||
    fail 'a zero-byte return did not end as an impossible count'
[ "$(sed -n '33p' "$work/checkpoint.stdout")" -eq 22 ] ||
    fail 'a hard error did not carry its errno'
[ "$(sed -n '40p' "$work/checkpoint.stdout")" -eq 3 ] ||
    fail 'an over-long return did not preserve the offset already filled'
[ "$(sed -n '44p' "$work/checkpoint.stdout")" -eq 4 ] ||
    fail 'repeated EINTR did not cost one call each'

printf 'entropy fill loop against its golden: PASS\n'

# --------------------------------------------------------------- the C11 oracle

cc=${CC:-cc}
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    "$entropy_dir/tests/entropy_reference.c" -o "$work/entropy-reference"
"$work/entropy-reference" >"$work/reference.stdout"
cmp "$entropy_dir/tests/checkpoint.stdout" "$work/reference.stdout" ||
    fail 'the independent C11 oracle differs'

printf 'entropy C11 differential oracle: PASS\n'

# ------------------------------------------------------------- the oracle bound

# The oracle is evidence only while it mirrors the source it claims to. Binding
# both digests means a change to either one fails here until a person re-reads
# them together, which is the point: an oracle that drifts silently is worse
# than none, because it still prints PASS.
binding="$entropy_dir/tests/oracle-binding.json"
adapter_hash=$("$repo_dir/bin/kofun-digest" "$adapter" | awk '{ print $1 }')
oracle_hash=$("$repo_dir/bin/kofun-digest" \
    "$entropy_dir/tests/entropy_reference.c" | awk '{ print $1 }')
grep -Fq "\"adapter_sha256\": \"$adapter_hash\"" "$binding" ||
    fail 'the oracle binding does not name the current adapter'
grep -Fq "\"oracle_sha256\": \"$oracle_hash\"" "$binding" ||
    fail 'the oracle binding does not name the current oracle'
grep -Fq '"syscall_executed": false' "$binding" ||
    fail 'the oracle binding does not disclaim executing getrandom(2)'

printf 'entropy oracle bound to the source it mirrors: PASS\n'
