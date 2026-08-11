#!/bin/sh
set -u

# Observe and enforce the exact discovery-private sanitizer argv.  This wraps
# the configured compiler only for six support compiles and four driver links;
# ordinary discovery builds and the sanitizer availability probe do not pass
# through it.

: "${KOFUN_DISCOVERY_SANITIZER_REAL_CC:?missing real compiler}"
: "${KOFUN_DISCOVERY_SANITIZER_CENSUS_LOG:?missing census log}"
: "${KOFUN_DISCOVERY_SANITIZER_ROOT:?missing repository root}"
: "${KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR:?missing object directory}"

if test -e "$KOFUN_DISCOVERY_SANITIZER_REAL_CC" && test -e "$0" &&
   test "$KOFUN_DISCOVERY_SANITIZER_REAL_CC" -ef "$0"
then
    printf '%s\n' \
        'discovery sanitizer compiler: real compiler resolves to this wrapper' >&2
    exit 2
fi

reject() {
    printf '%s\n' "discovery sanitizer compiler: refused argv: $*" >&2
    exit 2
}

profile_prefix_is_exact() {
    test "$1" = -std=c11 &&
        test "$2" = -O1 &&
        test "$3" = -g &&
        test "$4" = -Wall &&
        test "$5" = -Wextra &&
        test "$6" = -Werror &&
        test "$7" = -pedantic &&
        test "$8" = -fno-omit-frame-pointer &&
        test "$9" = -fsanitize=address,undefined &&
        test "${10}" = -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY &&
        test "${11}" = "-I$KOFUN_DISCOVERY_SANITIZER_ROOT/bootstrap/stage2"
}

kind=
unit=
output=

if test "$#" -eq 15 && test "${12}" = -c; then
    profile_prefix_is_exact "$@" || reject 'support compile profile changed'
    test "${14}" = -o || reject 'support compile output flag changed'
    case ${13} in
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/bootstrap/stage2/semantic_producer.c")
            unit=semantic-producer
            expected_output=semantic-producer-library.o
            ;;
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/bootstrap/stage2/semantic_events.c")
            unit=semantic-events
            expected_output=semantic-events.o
            ;;
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/bootstrap/stage2/sha256.c")
            unit=sha256
            expected_output=sha256.o
            ;;
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/bootstrap/stage2/discovery_v1.c")
            unit=discovery-v1
            expected_output=discovery-v1.o
            ;;
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/bootstrap/stage2/discovery_provider.c")
            unit=discovery-provider
            expected_output=discovery-provider.o
            ;;
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/bootstrap/stage2/discovery_query.c")
            unit=discovery-query
            expected_output=discovery-query.o
            ;;
        *) reject 'support source is outside the fixed six-member closure' ;;
    esac
    test "${15}" = \
        "$KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR/$expected_output" ||
        reject 'support object name or directory changed'
    kind=compile
    output=$expected_output
elif test "$#" -eq 20 && test "${19}" = -o; then
    profile_prefix_is_exact "$@" || reject 'driver link profile changed'
    test "${12}" = "$KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR/semantic-producer-library.o" &&
        test "${13}" = "$KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR/semantic-events.o" &&
        test "${14}" = "$KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR/sha256.o" &&
        test "${15}" = "$KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR/discovery-v1.o" &&
        test "${16}" = "$KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR/discovery-provider.o" &&
        test "${17}" = "$KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR/discovery-query.o" ||
        reject 'driver link object set or order changed'
    case ${18} in
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/tests/conformance/discovery/live_query_test.c")
            unit=live-query
            expected_output=live-query-sanitized
            ;;
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/tests/conformance/discovery/nominal_typeid_test.c")
            unit=nominal-typeid
            expected_output=nominal-typeid-sanitized
            ;;
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/tests/conformance/discovery/bounded_typeid_test.c")
            unit=bounded-typeid
            expected_output=bounded-typeid-sanitized
            ;;
        "$KOFUN_DISCOVERY_SANITIZER_ROOT/tests/conformance/discovery/closure_test.c")
            unit=closure
            expected_output=closure-sanitized
            ;;
        *) reject 'driver is outside the fixed four-program closure' ;;
    esac
    : "${KOFUN_DISCOVERY_SANITIZER_OUTPUT:?missing expected link output}"
    test "${20}" = "$KOFUN_DISCOVERY_SANITIZER_OUTPUT" ||
        reject 'driver link output path changed'
    test "${20##*/}" = "$expected_output" ||
        reject 'driver link output name changed'
    kind=link
    output=$expected_output
else
    reject 'expected one support compile or driver link'
fi

start=$(date +%s%N)
status=0
"$KOFUN_DISCOVERY_SANITIZER_REAL_CC" "$@" || status=$?
end=$(date +%s%N)

printf 'cc\tkind=%s\tunit=%s\toutput=%s\tprofile=asan-ubsan-library-v1\tstatus=%s\twall_ns=%s\n' \
    "$kind" "$unit" "$output" "$status" "$((end - start))" \
    >>"$KOFUN_DISCOVERY_SANITIZER_CENSUS_LOG"

exit "$status"
