#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P -- "$(dirname -- "$0")/../../.." && pwd)
ASSERT_CONTEXT='Stage 2 build reuse'
. "$ROOT/tests/assertions/assert.sh"

ordinary_consumers='tests/conformance/adt-exhaustiveness/run.sh
tests/conformance/aggregate-bridge/run.sh
tests/conformance/call-arguments/run.sh
tests/conformance/const-generics/run.sh
tests/conformance/discovery/run.sh
tests/conformance/syntax/issues_48_60/run.sh
tests/conformance/backends/c11-stage2.sh
spec/roadmap-31-34/verify-current-gates.sh'

printf '%s\n' "$ordinary_consumers" |
while IFS= read -r consumer; do
    assert_grep "$consumer sources the shared builder" \
        -Fq 'bootstrap/stage2/build.sh' "$ROOT/$consumer"
    assert_grep "$consumer calls the shared builder" \
        -Fq 'kofun_stage2_build ' "$ROOT/$consumer"
done

for consumer in \
    tests/conformance/adt-exhaustiveness/run.sh \
    tests/conformance/aggregate-bridge/run.sh \
    tests/conformance/call-arguments/run.sh \
    tests/conformance/syntax/issues_48_60/run.sh \
    tests/conformance/backends/c11-stage2.sh \
    spec/roadmap-31-34/verify-current-gates.sh
do
    assert_not_grep "$consumer has no direct ordinary Stage 2 compile" \
        -Fq 'bootstrap/stage2/compiler.c' "$ROOT/$consumer"
done

# These two gates still need one deliberately distinct compiler build. The
# marker makes that exception reviewable and prevents the ordinary arm from
# being copied back beside it.
assert_num "discovery specialized Stage 2 source references" \
    "$(grep -c 'bootstrap/stage2/compiler.c' \
        "$ROOT/tests/conformance/discovery/run.sh")" -eq 1
assert_grep "discovery names the macro-variant exception" \
    -Fq 'stage2-build-reuse: specialized macro-variant build' \
    "$ROOT/tests/conformance/discovery/run.sh"

# Const-generics retains the source reference used by its falsification: it
# writes a deliberately collapsed compiler pair and proves the product gate
# catches it. The ordinary executable now comes only from the helper.
assert_not_grep "const-generics removed its ordinary compile output" \
    -Fq '"$ROOT/bootstrap/stage2/compiler.c" -o "$WORK/kofun-stage2"' \
    "$ROOT/tests/conformance/const-generics/run.sh"
assert_grep "const-generics retains the collapsed-pair mutation" \
    -Fq '"$ROOT/bootstrap/stage2/compiler.c" >"$WORK/collapsed.c"' \
    "$ROOT/tests/conformance/const-generics/run.sh"

assert_grep "shared ordinary build retains optimized strict warnings" \
    -Fq -- '-std=c11 -O2 -Wall -Wextra -Werror -pedantic' \
    "$ROOT/bootstrap/stage2/build.sh"

verify_body=$(sed -n '/^  verify:/,$p' "$ROOT/Taskfile.yml")
for redundant in selfhost-frontend selfhost-c11 selfhost-c11-control; do
    if printf '%s\n' "$verify_body" |
        grep -Eq "^[[:space:]]+$redundant[[:space:]]*\\\\$"
    then
        assert_fail "$redundant repeats the shared profile scan in verify"
    fi
done
assert_grep "default profile checks frontend completion" \
    -Fq 'test -z "$phase" || test "$phase" = frontend' \
    "$ROOT/bootstrap/selfhost/check-profile.sh"
assert_grep "default profile checks c11-text completion" \
    -Fq 'test -z "$phase" || test "$phase" = c11-text' \
    "$ROOT/bootstrap/selfhost/check-profile.sh"
assert_grep "default profile checks c11-control completion" \
    -Fq 'test -z "$phase" || test "$phase" = c11-control' \
    "$ROOT/bootstrap/selfhost/check-profile.sh"

printf '%s\n' \
    'PASS: eight ordinary Stage 2 consumers reuse the shared compiler' \
    'PASS: specialized compiler builds remain explicit and independent' \
    'PASS: aggregate verify scans the self-host profile once'
