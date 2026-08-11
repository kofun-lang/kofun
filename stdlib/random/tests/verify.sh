#!/bin/sh
set -eu

random_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$random_dir/../.." && pwd)
work=${TMPDIR:-/tmp}/kofun-random-verify.$$
mkdir -p "$work"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'random checkpoint: FAIL: %s\n' "$*" >&2
    exit 1
}

if find "$random_dir" -type f \( -name '*.py' -o -name '*.kf' \) |
    grep -q .
then
    fail 'forbidden Python or .kf source found'
fi

source_file="$random_dir/random.kofun"
for declaration in \
    'let RANDOM_ALGORITHM_VERSION = 1' \
    'type Random = {' \
    'type RandomError =' \
    'fn random_seeded(' \
    'fn random_next(' \
    'fn random_below(' \
    'fn random_fill_bytes(' \
    'fn random_shuffle_int(' \
    'fn random_sample_int('
do
    grep -Fq "$declaration" "$source_file" ||
        fail "missing canonical declaration: $declaration"
done

grep -Fq 'RANDOM_MULTIPLIER * low - RANDOM_REMAINDER * high' \
    "$source_file" || fail 'Schrage state transition is missing'
grep -Fq 'RANDOM_DOMAIN - RANDOM_DOMAIN % upper_exclusive' \
    "$source_file" || fail 'small-bound rejection limit is missing'
grep -Fq 'InvalidUpperBound(upper_exclusive)' "$source_file" ||
    fail 'invalid bounds do not have a typed error'
grep -Fq 'UpperBoundTooLarge(upper_exclusive, RANDOM_DOMAIN)' \
    "$source_file" || fail 'bounds above the exact domain are not rejected'
grep -Fq 'InvalidSampleSize(count, len(values))' "$source_file" ||
    fail 'invalid sample sizes do not have a typed error'

[ "$(grep -R -l 'random_fill(seed_bytes, 0)' "$random_dir"/*.kofun | wc -l)" -eq 1 ] ||
    fail 'system entropy must remain in one explicit adapter'
grep -Fq 'fn random_from_system()' "$random_dir/linux_x86_64.kofun" ||
    fail 'Linux system-seeding adapter is missing'
grep -Fq 'Err(error) if error.errno == EINTR' \
    "$random_dir/linux_x86_64.kofun" ||
    fail 'system-seeding adapter does not retry EINTR'
grep -Fq 'never keys, nonces, tokens' "$source_file" ||
    fail 'deterministic byte security boundary is missing'

set +e
"$repo_dir/bin/kofun" check "$source_file" \
    >"$work/canonical.check.stdout" 2>"$work/canonical.check.stderr"
canonical_status=$?
set -e
[ "$canonical_status" -ne 0 ] ||
    fail 'canonical record/ADT source unexpectedly claimed executable codegen'
grep -Fq 'error[E2S02]: expected top-level `fn`, `type`, or `let`' \
    "$work/canonical.check.stderr" ||
    fail 'canonical API did not expose the documented compiler boundary'

"$repo_dir/bin/kofun" run "$random_dir/tests/checkpoint.kofun" \
    >"$work/checkpoint.stdout"
cmp "$random_dir/tests/checkpoint.stdout" "$work/checkpoint.stdout" ||
    fail 'Kofun deterministic vectors differ'

cc=${CC:-cc}
"$cc" -std=c11 -O2 -Wall -Wextra -Werror \
    "$random_dir/tests/random_reference.c" -o "$work/random-reference"
"$work/random-reference" >"$work/reference.stdout"
cmp "$random_dir/tests/checkpoint.stdout" "$work/reference.stdout" ||
    fail 'independent C11 oracle differs'

[ "$(sed -n '22p' "$work/checkpoint.stdout")" -eq 4 ] ||
    fail 'deterministic retry probe did not consume four transitions'
[ "$(sed -n '24p' "$work/checkpoint.stdout")" -eq 21 ] ||
    fail 'toy rejection model did not check all 21 residue cases'
[ "$(sed -n '25p' "$work/checkpoint.stdout")" -eq 0 ] &&
[ "$(sed -n '26p' "$work/checkpoint.stdout")" -eq 1 ] &&
[ "$(sed -n '27p' "$work/checkpoint.stdout")" -eq 2 ] ||
    fail 'bounded-integer error statuses differ'
[ "$(sed -n '28p' "$work/checkpoint.stdout")" -eq 0 ] &&
[ "$(sed -n '29p' "$work/checkpoint.stdout")" -eq 1 ] &&
[ "$(sed -n '30p' "$work/checkpoint.stdout")" -eq 0 ] ||
    fail 'sample-size error statuses differ'
[ "$(sed -n '39p' "$work/checkpoint.stdout")" -eq 1000 ] ||
    fail 'below-10 transition measurement differs'
[ "$(sed -n '40p' "$work/checkpoint.stdout")" -eq 256 ] ||
    fail 'byte-fill transition measurement differs'
[ "$(sed -n '41p' "$work/checkpoint.stdout")" -eq 127 ] ||
    fail 'shuffle transition measurement differs'
[ "$(sed -n '42p' "$work/checkpoint.stdout")" -eq 2000 ] ||
    fail 'high-rejection transition measurement differs'

evidence="$random_dir/tests/cost-evidence.json"
source_hash=$("$repo_dir/bin/kofun-digest" "$source_file" | awk '{ print $1 }')
grep -Fq "\"sha256\": \"$source_hash\"" "$evidence" ||
    fail 'cost evidence is not bound to the canonical source'
grep -Fq '"unit": "generator transitions"' "$evidence" ||
    fail 'cost evidence unit is missing'
grep -Fq '"generator_transitions": 2000' "$evidence" ||
    fail 'high-rejection measured cost is missing'
grep -Fq '"wall_clock_claimed": false' "$evidence" ||
    fail 'cost evidence overclaims wall-clock measurement'

printf 'random deterministic vectors and errors: PASS\n'
printf 'random unbiased rejection model (21/21): PASS\n'
printf 'random C11 differential oracle: PASS\n'
printf 'random measured generator-transition costs: PASS\n'
