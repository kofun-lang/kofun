#!/bin/sh
set -u

# Observe and enforce only the fixed #1326 object compile and five object
# links.  Refused argv never reaches the real compiler or the completed census.

: "${KOFUN_FUZZ_SANITIZER_REAL_CC:?missing real compiler}"
: "${KOFUN_FUZZ_SANITIZER_CENSUS_LOG:?missing census log}"
: "${KOFUN_FUZZ_SANITIZER_ROOT:?missing repository root}"
: "${KOFUN_FUZZ_SANITIZER_OBJECT_DIR:?missing object directory}"

if test -e "$KOFUN_FUZZ_SANITIZER_REAL_CC" && test -e "$0" &&
   test "$KOFUN_FUZZ_SANITIZER_REAL_CC" -ef "$0"
then
    printf '%s\n' \
        'fuzz sanitizer compiler: real compiler resolves to this wrapper' >&2
    exit 2
fi
if test ! -f "$KOFUN_FUZZ_SANITIZER_REAL_CC" ||
   test ! -x "$KOFUN_FUZZ_SANITIZER_REAL_CC"
then
    printf '%s\n' \
        'fuzz sanitizer compiler: real compiler is not an executable regular file' >&2
    exit 2
fi
if test -L "$KOFUN_FUZZ_SANITIZER_CENSUS_LOG" ||
   test ! -f "$KOFUN_FUZZ_SANITIZER_CENSUS_LOG"
then
    printf '%s\n' \
        'fuzz sanitizer compiler: census is missing or not regular' >&2
    exit 2
fi

reject() {
    printf '%s\n' "fuzz sanitizer compiler: refused argv: $*" >&2
    exit 2
}

profile_prefix_is_exact() {
    test "$1" = -std=c11 &&
        test "$2" = -O1 &&
        test "$3" = -g &&
        test "$4" = -Wall &&
        test "$5" = -Wextra &&
        test "$6" = -Werror &&
        test "$7" = -fsanitize=address,undefined &&
        test "$8" = -fno-omit-frame-pointer
}

kind=
role=
output=

if test "$#" -eq 12 && test "$9" = -c; then
    profile_prefix_is_exact "$@" || reject 'compile profile changed'
    test "${KOFUN_FUZZ_SANITIZER_LINK_ROLE:-}" = '' ||
        reject 'compile carried a link role'
    test "${KOFUN_FUZZ_SANITIZER_LINK_OUTPUT:-}" = '' ||
        reject 'compile carried a logical link output'
    test "${10}" = \
        "$KOFUN_FUZZ_SANITIZER_ROOT/bootstrap/stage2/compiler.c" ||
        reject 'compile source changed'
    test "${11}" = -o || reject 'compile output flag changed'
    test "${12}" = \
        "$KOFUN_FUZZ_SANITIZER_OBJECT_DIR/compiler-fuzz-asan-ubsan.o" ||
        reject 'compile object name or directory changed'
    kind=compile
    role=shared
    output=compiler-fuzz-asan-ubsan.o
elif test "$#" -eq 11 &&
     test "$9" = \
        "$KOFUN_FUZZ_SANITIZER_OBJECT_DIR/compiler-fuzz-asan-ubsan.o" &&
     test "${10}" = -o
then
    profile_prefix_is_exact "$@" || reject 'link profile changed'
    role=${KOFUN_FUZZ_SANITIZER_LINK_ROLE:-}
    case $role in
        value-if|match-guard|match-value|match-value-invalid|enum-match) ;;
        *) reject 'link role changed' ;;
    esac
    logical_output=${KOFUN_FUZZ_SANITIZER_LINK_OUTPUT:-}
    test -n "$logical_output" || reject 'logical link output is missing'
    logical_parent=$(dirname -- "$logical_output")
    logical_base=$(basename -- "$logical_output")
    test "$logical_base" = kofun-stage2-sanitized ||
        reject 'logical link output basename changed'
    case ${11} in
        "$logical_parent/.$logical_base."??????) ;;
        *) reject 'private link output path changed' ;;
    esac
    kind=link
    output=kofun-stage2-sanitized
else
    reject 'expected the one object compile or one fixed-role object link'
fi

start=$(date +%s%N)
status=0
"$KOFUN_FUZZ_SANITIZER_REAL_CC" "$@" || status=$?
end=$(date +%s%N)

printf 'cc\tkind=%s\trole=%s\toutput=%s\tprofile=fuzz-stage2-asan-ubsan-v1\tstatus=%s\twall_ns=%s\n' \
    "$kind" "$role" "$output" "$status" "$((end - start))" \
    >>"$KOFUN_FUZZ_SANITIZER_CENSUS_LOG"

exit "$status"
