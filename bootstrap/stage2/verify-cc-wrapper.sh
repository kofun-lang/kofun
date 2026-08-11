#!/bin/sh
set -u

# Instrument only semantic-producer inputs.  One line is appended per compiler
# process so concurrent verify workers cannot interleave a multi-line record.
: "${KOFUN_VERIFY_REAL_CC:?missing real compiler}"
: "${KOFUN_VERIFY_CC_LOG:?missing compiler census log}"

if test -e "$KOFUN_VERIFY_REAL_CC" && test -e "$0" &&
   test "$KOFUN_VERIFY_REAL_CC" -ef "$0"
then
    printf '%s\n' \
        'verify compiler wrapper: real compiler resolves to the wrapper itself' >&2
    exit 2
fi

producer_source=0
producer_source_count=0
events_source=0
events_source_count=0
sha_source=0
sha_source_count=0
producer_object=0
main_object=0
library_object=0
optimization=none
optimization_count=0
library=0
library_count=0
sanitizer=0
analyzer=0
pic=0
compile_only=0
compile_only_count=0
language_c11=0
language_c11_count=0
debug=0
debug_count=0
wall=0
wall_count=0
wextra=0
wextra_count=0
werror=0
werror_count=0
pedantic=0
pedantic_count=0
include_count=0
output_count=0
profile_extra=0
output_name=none
expect_output=0

for argument in "$@"; do
    if test "$expect_output" -eq 1; then
        output_name=${argument##*/}
        expect_output=0
        continue
    fi
    case $argument in
        -o)
            expect_output=1
            output_count=$((output_count + 1))
            ;;
        -o?*)
            output_count=$((output_count + 1))
            output_name=${argument#-o}
            output_name=${output_name##*/}
            ;;
        */bootstrap/stage2/semantic_producer.c)
            producer_source=1
            producer_source_count=$((producer_source_count + 1))
            ;;
        */bootstrap/stage2/semantic_events.c)
            events_source=1
            events_source_count=$((events_source_count + 1))
            ;;
        */bootstrap/stage2/sha256.c)
            sha_source=1
            sha_source_count=$((sha_source_count + 1))
            ;;
        */semantic-producer-main.o)
            producer_object=1
            main_object=1
            ;;
        */semantic-producer-library.o)
            producer_object=1
            library_object=1
            ;;
        -O2)
            optimization=O2
            optimization_count=$((optimization_count + 1))
            ;;
        -O1)
            optimization=O1
            optimization_count=$((optimization_count + 1))
            ;;
        -O0)
            optimization=O0
            optimization_count=$((optimization_count + 1))
            ;;
        -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY)
            library=1
            library_count=$((library_count + 1))
            ;;
        -fsanitize=*) sanitizer=1 ;;
        --analyze|-fanalyzer) analyzer=1 ;;
        -fPIC|-fpic) pic=1 ;;
        -c)
            compile_only=1
            compile_only_count=$((compile_only_count + 1))
            ;;
        -std=c11)
            language_c11=1
            language_c11_count=$((language_c11_count + 1))
            ;;
        -g)
            debug=1
            debug_count=$((debug_count + 1))
            ;;
        -Wall)
            wall=1
            wall_count=$((wall_count + 1))
            ;;
        -Wextra)
            wextra=1
            wextra_count=$((wextra_count + 1))
            ;;
        -Werror)
            werror=1
            werror_count=$((werror_count + 1))
            ;;
        -pedantic)
            pedantic=1
            pedantic_count=$((pedantic_count + 1))
            ;;
        -I*/bootstrap/stage2|-Ibootstrap/stage2)
            include_count=$((include_count + 1))
            ;;
        *) profile_extra=$((profile_extra + 1)) ;;
    esac
done

case $output_name in
    *'
'*|*'	'*)
        output_name=invalid-delimited-output-name
        profile_extra=$((profile_extra + 1))
        ;;
esac

# The census concerns only the reusable semantic inputs. Preserve the exact
# compiler process shape for unrelated verify builds; do not spawn two timing
# processes around hundreds of calls that cannot affect the reuse count.
if test "$producer_source" -eq 0 &&
   test "$events_source" -eq 0 &&
   test "$sha_source" -eq 0 &&
   test "$producer_object" -eq 0
then
    exec "$KOFUN_VERIFY_REAL_CC" "$@"
fi

# Exact means exact: every required token occurs once, the include root and
# output are present once, and no unrecognized/profile-changing token exists.
# Source-set, role, and output checks below close the remaining identity.
strict_standard=0
if test "$language_c11_count" -eq 1 &&
   test "$optimization" = O2 &&
   test "$optimization_count" -eq 1 &&
   test "$debug_count" -eq 1 &&
   test "$wall_count" -eq 1 &&
   test "$wextra_count" -eq 1 &&
   test "$werror_count" -eq 1 &&
   test "$pedantic_count" -eq 1 &&
   test "$include_count" -eq 1 &&
   test "$compile_only_count" -eq 1 &&
   test "$output_count" -eq 1 &&
   test "$expect_output" -eq 0 &&
   test "$profile_extra" -eq 0 &&
   test "$sanitizer" -eq 0 &&
   test "$analyzer" -eq 0 &&
   test "$pic" -eq 0
then
    strict_standard=1
fi

# Record why this argv belongs to the census.  Any semantic source/object mix
# is classified before either side, so an extra producer, events, or SHA
# compilation cannot hide behind an otherwise valid supplied producer object.
classification=other
if test "$producer_object" -eq 1 &&
   { test "$producer_source" -eq 1 ||
     test "$events_source" -eq 1 ||
     test "$sha_source" -eq 1; }
then
    classification=mixed-semantic-source-object
elif test "$producer_object" -eq 1; then
    if test "$main_object" -eq 1 && test "$library_object" -eq 0; then
        classification=producer-object-main
    elif test "$library_object" -eq 1 && test "$main_object" -eq 0; then
        classification=producer-object-library
    else
        classification=producer-object-mixed
    fi
elif test "$producer_source" -eq 1; then
    if test "$sanitizer" -eq 1; then
        classification=special-sanitizer
    elif test "$analyzer" -eq 1; then
        classification=special-analyzer
    elif test "$pic" -eq 1; then
        classification=special-pic
    elif test "$strict_standard" -eq 1 &&
         test "$producer_source_count" -eq 1 &&
         test "$events_source_count" -eq 0 &&
         test "$sha_source_count" -eq 0 &&
         test "$library_count" -eq 0 &&
         test "$output_name" = semantic-producer-main.o
    then
        classification=standard-producer-main
    elif test "$strict_standard" -eq 1 &&
         test "$producer_source_count" -eq 1 &&
         test "$events_source_count" -eq 0 &&
         test "$sha_source_count" -eq 0 &&
         test "$library_count" -eq 1 &&
         test "$output_name" = semantic-producer-library.o
    then
        classification=standard-producer-library
    else
        classification=other-producer-source
    fi
elif test "$events_source" -eq 1; then
    if test "$strict_standard" -eq 1 &&
       test "$events_source_count" -eq 1 &&
       test "$producer_source_count" -eq 0 &&
       test "$sha_source_count" -eq 0 &&
       test "$library_count" -eq 0 &&
       test "$output_name" = semantic-events.o
    then
        classification=standard-events
    elif test "$sanitizer" -eq 1 ||
         test "$analyzer" -eq 1 ||
         test "$pic" -eq 1
    then
        classification=special-events-source
    elif test "$compile_only" -eq 1 &&
         test "$output_name" = semantic-events.o
    then
        # A second object claiming the reusable output kind but changing the
        # exact profile is never a local standalone consumer.
        classification=unexpected-events-source
    else
        classification=special-events-source
    fi
elif test "$sha_source" -eq 1; then
    if test "$strict_standard" -eq 1 &&
       test "$sha_source_count" -eq 1 &&
       test "$producer_source_count" -eq 0 &&
       test "$events_source_count" -eq 0 &&
       test "$library_count" -eq 0 &&
       test "$output_name" = sha256.o
    then
        classification=standard-sha
    elif test "$sanitizer" -eq 1 ||
         test "$analyzer" -eq 1 ||
         test "$pic" -eq 1
    then
        classification=special-sha-source
    elif test "$compile_only" -eq 1 && test "$output_name" = sha256.o; then
        classification=unexpected-sha-source
    else
        # sha256.c also belongs to unrelated KIF/Unicode/visibility tools;
        # their executable/source-local profiles are explicitly out of this
        # object-reuse slice and remain measured but allowed.
        classification=special-sha-source
    fi
fi

start=$(date +%s%N)
status=0
"$KOFUN_VERIFY_REAL_CC" "$@" || status=$?
end=$(date +%s%N)

printf 'cc\tclass=%s\toutput=%s\tproducer_source=%s\tevents_source=%s\tsha_source=%s\tproducer_object=%s\tmain_object=%s\tlibrary_object=%s\topt=%s\tlibrary=%s\tsanitizer=%s\tanalyzer=%s\tpic=%s\tcompile_only=%s\tc11=%s\tdebug=%s\twall=%s\twextra=%s\twerror=%s\tpedantic=%s\textra=%s\tstatus=%s\twall_ns=%s\n' \
    "$classification" "$output_name" "$producer_source" \
    "$events_source" "$sha_source" "$producer_object" "$main_object" \
    "$library_object" "$optimization" "$library" "$sanitizer" \
    "$analyzer" "$pic" "$compile_only" "$language_c11" "$debug" \
    "$wall" "$wextra" "$werror" "$pedantic" "$profile_extra" \
    "$status" "$((end - start))" >>"$KOFUN_VERIFY_CC_LOG"

exit "$status"
