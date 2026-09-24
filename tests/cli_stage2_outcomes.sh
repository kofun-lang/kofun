#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KOFUN="$ROOT/bin/kofun"
SUITE="$ROOT/tests/diagnostics/stage2"
WORK=${KOFUN_CLI_OUTCOME_WORK:-"$ROOT/build/cli-stage2-outcomes"}
TASK_TMP="$WORK/tmp"
STAGE1_BUILD="$WORK/stage1"
STAGE2_BUILD="$WORK/stage2"

fail() {
    printf '%s\n' "FAIL: $*" >&2
    exit 1
}

rm -rf "$WORK"
mkdir -p "$TASK_TMP" "$STAGE1_BUILD" "$STAGE2_BUILD"

run_kofun() {
    TMPDIR="$TASK_TMP" \
    KOFUN_BUILD_DIR="$STAGE1_BUILD" \
    KOFUN_STAGE2_BUILD_DIR="$STAGE2_BUILD" \
        "$KOFUN" "$@"
}

expect_cli_failure() {
    source=$1
    expected_status=$2
    golden=$3
    stem=$(basename "${source%.kofun}")
    stdout="$WORK/$stem.check.stdout"
    stderr="$WORK/$stem.check.stderr"

    set +e
    run_kofun check "$source" >"$stdout" 2>"$stderr"
    status=$?
    set -e
    test "$status" -eq "$expected_status" ||
        fail "$stem check exited $status instead of $expected_status"
    test ! -s "$stdout" || fail "$stem check wrote stdout"
    cmp "$golden" "$stderr" ||
        fail "$stem check did not preserve the Stage 2 diagnostic"
}

checked=0
for source in "$SUITE"/*.kofun; do
    stem=$(basename "${source%.kofun}")
    mode=$(sed -n 's/^# diagnostic-mode: //p' "$source")
    code=$(sed -n 's/^# expect-code: //p' "$source")
    case "$mode:$code" in
        ownership:E2S20)
            # E2S20 means the optional ownership checker does not apply. The
            # ordinary compiler still validates this source successfully.
            run_kofun check "$source" >"$WORK/$stem.check.stdout" \
                2>"$WORK/$stem.check.stderr" ||
                fail "$stem general check should remain valid"
            test ! -s "$WORK/$stem.check.stderr" ||
                fail "$stem general check wrote stderr"
            ;;
        compile:E2S10)
            expect_cli_failure "$source" 3 "$SUITE/$stem.stderr"
            ;;
        compile:*|ownership:E007|ownership:E2S21)
            expect_cli_failure "$source" 1 "$SUITE/$stem.stderr"
            ;;
        scoped-ownership:E2S18[3-8])
            # `kofun check` reports the scoped ownership class (#1163)
            # rather than whichever unimplemented construct compiled first.
            expect_cli_failure "$source" 1 "$SUITE/$stem.stderr"
            ;;
        *)
            fail "unhandled Stage 2 diagnostic mode/code: $mode/$code"
            ;;
    esac
    checked=$((checked + 1))
done

self="$SUITE/e2s35_self_reference.kofun"
for command in emit-c build run; do
    stdout="$WORK/$command.stdout"
    stderr="$WORK/$command.stderr"
    set +e
    case "$command" in
        emit-c)
            run_kofun emit-c "$self" "$WORK/rejected.c" \
                >"$stdout" 2>"$stderr"
            ;;
        build)
            run_kofun build "$self" -o "$WORK/rejected" \
                >"$stdout" 2>"$stderr"
            ;;
        run)
            run_kofun run "$self" >"$stdout" 2>"$stderr"
            ;;
    esac
    status=$?
    set -e
    test "$status" -eq 1 ||
        fail "$command semantic failure exited $status instead of 1"
    test ! -s "$stdout" || fail "$command semantic failure wrote stdout"
    cmp "$SUITE/e2s35_self_reference.stderr" "$stderr" ||
        fail "$command did not preserve the Stage 2 diagnostic"
done
test ! -e "$WORK/rejected.c" ||
    fail 'emit-c committed output after semantic failure'
test ! -e "$WORK/rejected" ||
    fail 'build committed output after semantic failure'
test ! -e "$STAGE1_BUILD/e2s35_self_reference.c" ||
    fail 'build committed intermediate C after semantic failure'

compiler="$STAGE2_BUILD/kofun-stage2"
test -x "$compiler" || fail 'public checks did not build the Stage 2 compiler'
check_outcome() {
    name=$1
    expected=$2
    source=$3
    set +e
    "$compiler" --compile-outcome "$source" \
        "$WORK/$name.c" "$WORK/$name.ir" "$WORK/$name.tokens" \
        >"$WORK/$name.outcome.stdout" 2>"$WORK/$name.outcome.stderr"
    status=$?
    set -e
    test "$status" -eq "$expected" ||
        fail "$name outcome was $status instead of $expected"
    test ! -s "$WORK/$name.outcome.stderr" ||
        fail "$name outcome wrote internal stderr"
}

check_outcome valid 0 "$ROOT/bootstrap/fixtures/answer.kofun"
check_outcome invalid 1 "$self"
check_outcome unsupported 3 "$SUITE/e2s10_unsupported_statement.kofun"
check_outcome ownership 3 \
    "$ROOT/bootstrap/stage2/fixtures/borrowed_copy_int.kofun"
test -s "$WORK/valid.c" || fail 'valid outcome omitted C output'
for name in invalid unsupported ownership; do
    test ! -e "$WORK/$name.c" ||
        fail "$name outcome committed C output"
done

fake_stage2="$WORK/fake-stage2"
mkdir -p "$fake_stage2"
cp "$ROOT/tests/fixtures/stage2_unsupported_compiler.sh" \
    "$fake_stage2/kofun-stage2"
chmod +x "$fake_stage2/kofun-stage2"
touch "$fake_stage2/kofun-stage2"
TMPDIR="$TASK_TMP" \
KOFUN_BUILD_DIR="$WORK/fallback-stage1" \
KOFUN_STAGE2_BUILD_DIR="$fake_stage2" \
    "$KOFUN" emit-c "$ROOT/bootstrap/fixtures/answer.kofun" \
    "$WORK/fallback.c" >"$WORK/fallback.stdout" 2>"$WORK/fallback.stderr"
test ! -s "$WORK/fallback.stderr" ||
    fail 'explicit Stage 1 compatibility fallback wrote stderr'
grep -F 'Generated by the Kofun-written Stage 1 seed compiler' \
    "$WORK/fallback.c" >/dev/null ||
    fail 'status 3 did not use the explicit Stage 1 compatibility path'

printf '%s\n' \
    "PASS: public CLI covered $checked Stage 2 diagnostic fixtures by mode" \
    'PASS: check/emit-c/build/run preserve semantic diagnostics and artifacts' \
    'PASS: Stage 2 outcomes distinguish invalid from unsupported lowering' \
    'PASS: explicit Stage 1 compatibility fallback remains executable'
