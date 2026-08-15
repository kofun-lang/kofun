#!/bin/sh
set -u

# Instrument the semantic-producer family and the bounded strict-O2 common
# family.  One line is appended per compiler process so concurrent verify
# workers cannot interleave a multi-line record.
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
common_kif_source=0
common_kif_source_count=0
common_unicode_source=0
common_unicode_source_count=0
common_visibility_source=0
common_visibility_source_count=0
producer_object=0
main_object=0
main_object_count=0
library_object=0
library_object_count=0
events_object=0
events_object_count=0
semantic_sha_object=0
semantic_sha_object_count=0
common_kif_object=0
common_kif_object_count=0
common_unicode_object=0
common_unicode_object_count=0
common_sha_object=0
common_sha_object_count=0
common_visibility_object=0
common_visibility_object_count=0
# #1449. The analyzer members get their own counters rather than sharing the
# O2 ones. Sharing would make the two variants interchangeable to every rule
# below, and an analyzer arm that linked the O2 object would then be
# indistinguishable from one that linked the analysed object -- which is the
# one failure the analyzer arm exists to rule out, since `-fanalyzer` is a
# compile-time diagnostic that a prebuilt O2 object never carried.
common_kif_analyzer_object=0
common_kif_analyzer_object_count=0
common_unicode_analyzer_object=0
common_unicode_analyzer_object_count=0
common_sha_analyzer_object=0
common_sha_analyzer_object_count=0
common_visibility_analyzer_object=0
common_visibility_analyzer_object_count=0
optimization=none
optimization_count=0
library=0
library_count=0
diagnostic_faults=0
diagnostic_faults_count=0
work_limit=0
work_limit_count=0
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
primary=none
primary_count=0
argument_count=0

for argument in "$@"; do
    argument_count=$((argument_count + 1))
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
        */bootstrap/stage2/kif_v1.c)
            common_kif_source=1
            common_kif_source_count=$((common_kif_source_count + 1))
            ;;
        */unicode/kofun_unicode.c)
            common_unicode_source=1
            common_unicode_source_count=$((common_unicode_source_count + 1))
            ;;
        */bootstrap/stage2/visibility_access.c)
            common_visibility_source=1
            common_visibility_source_count=$((common_visibility_source_count + 1))
            ;;
        */semantic-producer-main.o)
            producer_object=1
            main_object=1
            main_object_count=$((main_object_count + 1))
            ;;
        */semantic-producer-library.o)
            producer_object=1
            library_object=1
            library_object_count=$((library_object_count + 1))
            ;;
        */semantic-events.o)
            events_object=1
            events_object_count=$((events_object_count + 1))
            ;;
        */sha256.o)
            semantic_sha_object=1
            semantic_sha_object_count=$((semantic_sha_object_count + 1))
            ;;
        */kif-v1-common-o2.o)
            common_kif_object=1
            common_kif_object_count=$((common_kif_object_count + 1))
            ;;
        */kofun-unicode-common-o2.o)
            common_unicode_object=1
            common_unicode_object_count=$((common_unicode_object_count + 1))
            ;;
        */sha256-common-o2.o)
            common_sha_object=1
            common_sha_object_count=$((common_sha_object_count + 1))
            ;;
        */visibility-access-common-o2.o)
            common_visibility_object=1
            common_visibility_object_count=$((common_visibility_object_count + 1))
            ;;
        # #1449. The `-O0 -fanalyzer` members of the same bundle. They must be
        # recognised here or the passthrough below stops observing exactly the
        # invocations whose count this census exists to report: a gate linking
        # them touches no other tracked input, so every counter would be zero
        # and the reuse would read as absent rather than as achieved.
        */kif-v1-common-analyzer.o)
            common_kif_analyzer_object=1
            common_kif_analyzer_object_count=$((
                common_kif_analyzer_object_count + 1))
            ;;
        */kofun-unicode-common-analyzer.o)
            common_unicode_analyzer_object=1
            common_unicode_analyzer_object_count=$((
                common_unicode_analyzer_object_count + 1))
            ;;
        */sha256-common-analyzer.o)
            common_sha_analyzer_object=1
            common_sha_analyzer_object_count=$((
                common_sha_analyzer_object_count + 1))
            ;;
        */visibility-access-common-analyzer.o)
            common_visibility_analyzer_object=1
            common_visibility_analyzer_object_count=$((
                common_visibility_analyzer_object_count + 1))
            ;;
        */bootstrap/stage2/kif_v1_tool.c)
            primary=kif-v1-tool
            primary_count=$((primary_count + 1))
            ;;
        */tests/conformance/modules/kif-v1/codec_test.c)
            primary=kif-v1-codec-test
            primary_count=$((primary_count + 1))
            ;;
        */tests/artifact-qualification/kif_measure.c)
            primary=artifact-kif-measure
            primary_count=$((primary_count + 1))
            ;;
        */bootstrap/stage2/stage2_kif_producer.c)
            primary=stage2-kif-producer
            primary_count=$((primary_count + 1))
            ;;
        */bootstrap/stage2/incremental_graph.c)
            primary=incremental-graph
            primary_count=$((primary_count + 1))
            ;;
        */bootstrap/stage2/re_exports.c)
            primary=re-exports
            primary_count=$((primary_count + 1))
            ;;
        # Primaries reached only through an analysed site (#1449).
        */bootstrap/stage2/imports_selective.c)
            primary=imports-selective
            primary_count=$((primary_count + 1))
            ;;
        */bootstrap/stage2/module_symbols.c)
            primary=module-symbols
            primary_count=$((primary_count + 1))
            ;;
        */tests/conformance/modules/re-exports/export_binding_reference.c)
            primary=export-binding-reference
            primary_count=$((primary_count + 1))
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
        -DKOFUN_TEST_DIAGNOSTIC_FAULTS)
            diagnostic_faults=1
            diagnostic_faults_count=$((diagnostic_faults_count + 1))
            ;;
        -DRE_EXPORT_GRAPH_WORK_LIMIT=*)
            work_limit=1
            work_limit_count=$((work_limit_count + 1))
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

common_site=${KOFUN_STAGE2_COMMON_LINK_ID:-none}
case $common_site in
    *'
'*|*'	'*) common_site=invalid-delimited-site ;;
esac

common_source_count=$((common_kif_source_count + common_unicode_source_count +
    sha_source_count + common_visibility_source_count))
common_analyzer_object_count=$((common_kif_analyzer_object_count +
    common_unicode_analyzer_object_count + common_sha_analyzer_object_count +
    common_visibility_analyzer_object_count))
common_object_count=$((common_kif_object_count + common_unicode_object_count +
    common_sha_object_count + common_visibility_object_count +
    common_analyzer_object_count))

# A selected common link is a closed call-site contract, not a basename
# heuristic.  Each identity fixes its role set, primary translation unit,
# output kind, and the only target-local macro that may be present.
site_known=0
expected_kif=0
expected_unicode=0
expected_sha=0
expected_visibility=0
expected_primary=none
expected_output=none
expected_library=0
expected_diagnostic_faults=0
expected_semantic_library=0
# 0 for a linked O2 site, 1 for an `-O0 -fanalyzer` site (#1449). The field
# selects which member variant the site may consume, so the two can never
# satisfy each other's contract.
expected_analyzer=0
# Every site but one passes exactly one `-I`. The selective-import analyzer
# arm passes none, and its members are still substitutable because the shared
# sources compile to the same bytes with and without it -- which is why the
# count is a declared field here rather than a constant the odd site would
# have been quietly edited to satisfy.
expected_include=1
case $common_site in
    kif-v1/tool)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-tool
        expected_output=kofun-kif-v1
        expected_diagnostic_faults=1
        ;;
    kif-v1/codec-test)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-codec-test
        expected_output=codec-test
        ;;
    # The `-O0 -fanalyzer` arms (#1449). Each one is the same closed contract
    # as its O2 sibling: role set, primary translation unit, output name.
    kif-v1/analyzed)
        site_known=1
        expected_analyzer=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-tool
        expected_output=kofun-kif-v1-analyzed
        ;;
    incremental/analyzed)
        site_known=1
        expected_analyzer=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_visibility=1
        expected_primary=incremental-graph
        expected_output=incremental-analyzed
        ;;
    imports-selective/analyzed)
        site_known=1
        expected_analyzer=1
        expected_include=0
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_visibility=1
        expected_primary=imports-selective
        expected_output=imports-selective-analyzed
        ;;
    re-exports/analyzed)
        site_known=1
        expected_analyzer=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_visibility=1
        expected_primary=re-exports
        expected_output=re-exports-analyzed
        ;;
    top-level-declarations/analyzed)
        site_known=1
        expected_analyzer=1
        expected_unicode=1
        expected_sha=1
        expected_primary=module-symbols
        expected_output=kofun-module-symbols-analyzed
        ;;
    artifact-qualification/kif-tool)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-tool
        expected_output=kif-tool
        ;;
    artifact-qualification/kif-measure)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=artifact-kif-measure
        expected_output=kif-measure
        ;;
    stage2-kif-producer/producer)
        site_known=1
        expected_kif=1
        expected_sha=1
        expected_primary=stage2-kif-producer
        expected_output=kofun-stage2-kif
        expected_library=1
        expected_semantic_library=1
        ;;
    stage2-kif-producer/reader)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-tool
        expected_output=kofun-kif-v1
        ;;
    incremental/graph)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_visibility=1
        expected_primary=incremental-graph
        expected_output=kofun-incremental-graph
        ;;
    incremental/reader)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-tool
        expected_output=kofun-kif-v1
        ;;
    documentation-index/producer)
        site_known=1
        expected_kif=1
        expected_sha=1
        expected_primary=stage2-kif-producer
        expected_output=kofun-stage2-kif
        expected_library=1
        expected_semantic_library=1
        ;;
    documentation-index/reader)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-tool
        expected_output=kofun-kif-v1
        ;;
    visibility-filtering/producer)
        site_known=1
        expected_kif=1
        expected_sha=1
        expected_primary=stage2-kif-producer
        expected_output=kofun-stage2-kif
        expected_library=1
        expected_semantic_library=1
        ;;
    visibility-filtering/reader)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-tool
        expected_output=kofun-kif-v1
        ;;
    fuzz-visibility-artifacts/resolver)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_visibility=1
        expected_primary=re-exports
        expected_output=re-exports
        ;;
    fuzz-visibility-artifacts/reader)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-tool
        expected_output=kofun-kif-v1
        ;;
    re-exports/resolver)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_visibility=1
        expected_primary=re-exports
        expected_output=re-exports
        expected_diagnostic_faults=1
        ;;
    re-exports/reader)
        site_known=1
        expected_kif=1
        expected_unicode=1
        expected_sha=1
        expected_primary=kif-v1-tool
        expected_output=kofun-kif-v1
        ;;
    re-exports/export-binding-reference)
        site_known=1
        expected_sha=1
        expected_primary=export-binding-reference
        expected_output=export-binding-reference
        ;;
    none) ;;
esac

# The census concerns only the reusable semantic inputs. Preserve the exact
# compiler process shape for unrelated verify builds; do not spawn two timing
# processes around hundreds of calls that cannot affect the reuse count.
if test "$producer_source" -eq 0 &&
   test "$events_source" -eq 0 &&
   test "$sha_source" -eq 0 &&
   test "$producer_object" -eq 0 &&
   test "$common_kif_source" -eq 0 &&
   test "$common_unicode_source" -eq 0 &&
   test "$common_visibility_source" -eq 0 &&
   test "$common_object_count" -eq 0 &&
   test "$common_site" = none
then
    exec "$KOFUN_VERIFY_REAL_CC" "$@"
fi

compiler_path=$(command -v "$KOFUN_VERIFY_REAL_CC") || {
    printf '%s\n' 'verify compiler wrapper: real compiler is unavailable' >&2
    exit 2
}
case $compiler_path in
    /*) ;;
    *)
        compiler_dir=$(dirname -- "$compiler_path")
        compiler_base=$(basename -- "$compiler_path")
        compiler_dir=$(CDPATH= cd -P -- "$compiler_dir" && pwd) || exit 2
        compiler_path=$compiler_dir/$compiler_base
        ;;
esac
case $compiler_path in
    *'
'*|*'	'*)
        printf '%s\n' \
            'verify compiler wrapper: resolved compiler path contains a delimiter' >&2
        exit 2
        ;;
esac
compiler_path_hex=$(printf '%s' "$compiler_path" |
    od -An -v -tx1 | tr -d ' \n')
compiler_sha256=not-required
compiler_identity=not-required
common_identity_required=0
case $output_name in
    kif-v1-common-o2.o|kofun-unicode-common-o2.o|sha256-common-o2.o|\
visibility-access-common-o2.o|kif-v1-common-analyzer.o|\
kofun-unicode-common-analyzer.o|sha256-common-analyzer.o|\
visibility-access-common-analyzer.o)
        common_identity_required=1
        ;;
esac
if test "$common_site" != none; then
    common_identity_required=1
fi
if test "$common_identity_required" -eq 1; then
    wrapper_dir=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd) || exit 2
    wrapper_root=$(CDPATH= cd -P -- "$wrapper_dir/../.." && pwd) || exit 2
    compiler_digest_output=$(
        CC="$KOFUN_VERIFY_REAL_CC" \
            "$wrapper_root/bin/kofun-digest" "$compiler_path"
    ) || {
        printf '%s\n' \
            'verify compiler wrapper: cannot digest the resolved compiler' >&2
        exit 2
    }
    compiler_sha256=${compiler_digest_output%% *}
    case $compiler_sha256 in
        *[!0-9a-f]*|'') compiler_identity=invalid ;;
        *)
            if test "${#compiler_sha256}" -eq 64; then
                compiler_identity=valid
            else
                compiler_identity=invalid
            fi
            ;;
    esac
    if test "${KOFUN_VERIFY_REAL_CC_PATH+x}" = x ||
       test "${KOFUN_VERIFY_REAL_CC_SHA256+x}" = x
    then
        if test "${KOFUN_VERIFY_REAL_CC_PATH+x}" != x ||
           test "${KOFUN_VERIFY_REAL_CC_SHA256+x}" != x ||
           test "$KOFUN_VERIFY_REAL_CC_PATH" != "$compiler_path" ||
           test "$KOFUN_VERIFY_REAL_CC_SHA256" != "$compiler_sha256"
        then
            compiler_identity=mismatch
        fi
    fi
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

strict_common_compile=0
if test "$language_c11_count" -eq 1 &&
   test "$optimization" = O2 &&
   test "$optimization_count" -eq 1 &&
   test "$debug_count" -eq 0 &&
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
   test "$pic" -eq 0 &&
   test "$primary_count" -eq 0 &&
   test "$library_count" -eq 0 &&
   test "$diagnostic_faults_count" -eq 0 &&
   test "$work_limit_count" -eq 0 &&
   test "$common_object_count" -eq 0 &&
   test "$main_object_count" -eq 0 &&
   test "$library_object_count" -eq 0 &&
   test "$events_object_count" -eq 0 &&
   test "$semantic_sha_object_count" -eq 0 &&
   test "$producer_source_count" -eq 0 &&
   test "$events_source_count" -eq 0 &&
   test "$compiler_identity" = valid
then
    strict_common_compile=1
fi

# The same contract at `-O0 -fanalyzer` (#1449). Written out rather than
# parameterised over the O2 form because the two differ in exactly the two
# fields that decide whether the object carries analysis, and a shared
# predicate would let a mistake in either one satisfy the other.
strict_common_analyzer_compile=0
if test "$language_c11_count" -eq 1 &&
   test "$optimization" = O0 &&
   test "$optimization_count" -eq 1 &&
   test "$debug_count" -eq 0 &&
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
   test "$analyzer" -eq 1 &&
   test "$pic" -eq 0 &&
   test "$primary_count" -eq 0 &&
   test "$library_count" -eq 0 &&
   test "$diagnostic_faults_count" -eq 0 &&
   test "$work_limit_count" -eq 0 &&
   test "$common_object_count" -eq 0 &&
   test "$main_object_count" -eq 0 &&
   test "$library_object_count" -eq 0 &&
   test "$events_object_count" -eq 0 &&
   test "$semantic_sha_object_count" -eq 0 &&
   test "$producer_source_count" -eq 0 &&
   test "$events_source_count" -eq 0 &&
   test "$compiler_identity" = valid
then
    strict_common_analyzer_compile=1
fi

# A linked site is O2 unless it declared itself analysed, in which case the
# optimisation level and the analyzer flag both invert. Nothing else about the
# contract moves.
common_link_optimization=O2
common_link_analyzer=0
if test "$expected_analyzer" -eq 1; then
    common_link_optimization=O0
    common_link_analyzer=1
fi

strict_common_link=0
if test "$site_known" -eq 1 &&
   test "$compiler_identity" = valid &&
   test "$language_c11_count" -eq 1 &&
   test "$optimization" = "$common_link_optimization" &&
   test "$optimization_count" -eq 1 &&
   test "$debug_count" -eq 0 &&
   test "$wall_count" -eq 1 &&
   test "$wextra_count" -eq 1 &&
   test "$werror_count" -eq 1 &&
   test "$pedantic_count" -eq 1 &&
   test "$include_count" -eq "$expected_include" &&
   test "$compile_only_count" -eq 0 &&
   test "$output_count" -eq 1 &&
   test "$expect_output" -eq 0 &&
   test "$profile_extra" -eq 0 &&
   test "$sanitizer" -eq 0 &&
   test "$analyzer" -eq "$common_link_analyzer" &&
   test "$pic" -eq 0 &&
   test "$primary_count" -eq 1 &&
   test "$primary" = "$expected_primary" &&
   test "$output_name" = "$expected_output" &&
   test "$library_count" -eq "$expected_library" &&
   test "$diagnostic_faults_count" -eq "$expected_diagnostic_faults" &&
   test "$work_limit_count" -eq 0
then
    strict_common_link=1
fi

source_roles_match=0
if test "$common_kif_source_count" -eq "$expected_kif" &&
   test "$common_unicode_source_count" -eq "$expected_unicode" &&
   test "$sha_source_count" -eq "$expected_sha" &&
   test "$common_visibility_source_count" -eq "$expected_visibility" &&
   test "$common_object_count" -eq 0 &&
   test "$producer_source_count" -eq "$expected_semantic_library" &&
   test "$events_source_count" -eq "$expected_semantic_library" &&
   test "$main_object_count" -eq 0 &&
   test "$library_object_count" -eq 0 &&
   test "$events_object_count" -eq 0 &&
   test "$semantic_sha_object_count" -eq 0
then
    source_roles_match=1
fi

object_roles_match=0
if test "$expected_analyzer" -eq 1; then
    # An analysed site must consume the analysed members and nothing else.
    # The O2 counts are pinned at zero here, and the analysed counts are
    # pinned at zero below, so linking the wrong variant fails the site
    # rather than passing as the other one.
    if test "$common_kif_analyzer_object_count" -eq "$expected_kif" &&
       test "$common_unicode_analyzer_object_count" -eq "$expected_unicode" &&
       test "$common_sha_analyzer_object_count" -eq "$expected_sha" &&
       test "$common_visibility_analyzer_object_count" -eq \
           "$expected_visibility" &&
       test "$common_kif_object_count" -eq 0 &&
       test "$common_unicode_object_count" -eq 0 &&
       test "$common_sha_object_count" -eq 0 &&
       test "$common_visibility_object_count" -eq 0 &&
       test "$common_source_count" -eq 0 &&
       test "$producer_source_count" -eq 0 &&
       test "$events_source_count" -eq 0 &&
       test "$main_object_count" -eq 0 &&
       test "$library_object_count" -eq 0 &&
       test "$events_object_count" -eq 0 &&
       test "$semantic_sha_object_count" -eq 0
    then
        object_roles_match=1
    fi
elif test "$common_kif_object_count" -eq "$expected_kif" &&
   test "$common_unicode_object_count" -eq "$expected_unicode" &&
   test "$common_sha_object_count" -eq "$expected_sha" &&
   test "$common_visibility_object_count" -eq "$expected_visibility" &&
   test "$common_analyzer_object_count" -eq 0 &&
   test "$common_source_count" -eq 0 &&
   test "$producer_source_count" -eq 0 &&
   test "$events_source_count" -eq 0 &&
   test "$main_object_count" -eq 0 &&
   test "$library_object_count" -eq "$expected_semantic_library" &&
   test "$events_object_count" -eq "$expected_semantic_library" &&
   test "$semantic_sha_object_count" -eq 0
then
    object_roles_match=1
fi

common_class=other
if test "$common_identity_required" -eq 1 &&
   test "$compiler_identity" != valid
then
    common_class=invalid-common-compiler
elif test "$common_site" != none && test "$site_known" -eq 0; then
    common_class=unknown-common-site
elif test "$common_site" != none; then
    if test "$strict_common_link" -eq 1 &&
       test "$source_roles_match" -eq 1
    then
        if test "$expected_analyzer" -eq 1; then
            common_class=common-analyzer-source-link
        else
            common_class=common-source-link
        fi
    elif test "$strict_common_link" -eq 1 &&
         test "$object_roles_match" -eq 1
    then
        if test "$expected_analyzer" -eq 1; then
            common_class=common-analyzer-object-link
        else
            common_class=common-object-link
        fi
    elif test "$common_source_count" -gt 0 &&
         test "$common_object_count" -gt 0
    then
        common_class=mixed-common-source-object
    else
        common_class=unexpected-common-link
    fi
elif test "$strict_common_compile" -eq 1 &&
     test "$common_source_count" -eq 1
then
    if test "$common_kif_source_count" -eq 1 &&
       test "$output_name" = kif-v1-common-o2.o
    then
        common_class=common-compile-kif-v1
    elif test "$common_unicode_source_count" -eq 1 &&
         test "$output_name" = kofun-unicode-common-o2.o
    then
        common_class=common-compile-unicode
    elif test "$sha_source_count" -eq 1 &&
         test "$output_name" = sha256-common-o2.o
    then
        common_class=common-compile-sha256
    elif test "$common_visibility_source_count" -eq 1 &&
         test "$output_name" = visibility-access-common-o2.o
    then
        common_class=common-compile-visibility
    else
        common_class=unexpected-common-compile
    fi
elif test "$strict_common_analyzer_compile" -eq 1 &&
     test "$common_source_count" -eq 1
then
    if test "$common_kif_source_count" -eq 1 &&
       test "$output_name" = kif-v1-common-analyzer.o
    then
        common_class=common-compile-kif-v1-analyzer
    elif test "$common_unicode_source_count" -eq 1 &&
         test "$output_name" = kofun-unicode-common-analyzer.o
    then
        common_class=common-compile-unicode-analyzer
    elif test "$sha_source_count" -eq 1 &&
         test "$output_name" = sha256-common-analyzer.o
    then
        common_class=common-compile-sha256-analyzer
    elif test "$common_visibility_source_count" -eq 1 &&
         test "$output_name" = visibility-access-common-analyzer.o
    then
        common_class=common-compile-visibility-analyzer
    else
        common_class=unexpected-common-compile
    fi
elif test "$common_object_count" -gt 0; then
    common_class=unexpected-common-object
elif test "$common_source_count" -gt 0; then
    common_class=distinct-common-source
fi

# Record why this argv belongs to the census.  Any semantic source/object mix
# is classified before either side, so an extra producer, events, or SHA
# compilation cannot hide behind an otherwise valid supplied producer object.
classification=other
if test "$producer_object" -eq 1 &&
   { test "$producer_source" -eq 1 ||
     test "$events_source" -eq 1 ||
     { test "$sha_source" -eq 1 && test "$common_site" = none; }; }
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
    if test "$common_class" = common-compile-sha256; then
        # The no-debug common role is deliberately distinct from the
        # existing O2/-g semantic SHA role.
        classification=special-sha-source
    elif test "$strict_standard" -eq 1 &&
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

# Preserve every argv byte without quoting ambiguity. POSIX arguments cannot
# contain NUL, so a NUL-framed hexadecimal record is lossless and keeps the
# tab-separated census one physical line per compiler process.
argv_hex=$(
    for argument in "$@"; do
        printf '%s\0' "$argument"
    done | od -An -v -tx1 | tr -d ' \n'
)

start=$(date +%s%N)
status=0
"$KOFUN_VERIFY_REAL_CC" "$@" || status=$?
end=$(date +%s%N)

printf 'cc\tclass=%s\tcommon_class=%s\tsite=%s\toutput=%s\tprimary=%s\tcompiler_path_hex=%s\tcompiler_sha256=%s\tcompiler_identity=%s\tproducer_source=%s\tproducer_source_count=%s\tevents_source=%s\tevents_source_count=%s\tsha_source=%s\tsha_source_count=%s\tproducer_object=%s\tmain_object=%s\tmain_object_count=%s\tlibrary_object=%s\tlibrary_object_count=%s\tevents_object=%s\tevents_object_count=%s\tsemantic_sha_object=%s\tsemantic_sha_object_count=%s\tcommon_kif_source=%s\tcommon_kif_source_count=%s\tcommon_unicode_source=%s\tcommon_unicode_source_count=%s\tcommon_visibility_source=%s\tcommon_visibility_source_count=%s\tcommon_kif_object=%s\tcommon_kif_object_count=%s\tcommon_unicode_object=%s\tcommon_unicode_object_count=%s\tcommon_sha_object=%s\tcommon_sha_object_count=%s\tcommon_visibility_object=%s\tcommon_visibility_object_count=%s\topt=%s\tlibrary=%s\tdiagnostic_faults=%s\twork_limit=%s\tsanitizer=%s\tanalyzer=%s\tpic=%s\tcompile_only=%s\tc11=%s\tdebug=%s\twall=%s\twextra=%s\twerror=%s\tpedantic=%s\textra=%s\targc=%s\targv_hex=%s\tstatus=%s\twall_ns=%s\n' \
    "$classification" "$common_class" "$common_site" "$output_name" \
    "$primary" "$compiler_path_hex" "$compiler_sha256" \
    "$compiler_identity" "$producer_source" "$producer_source_count" \
    "$events_source" "$events_source_count" "$sha_source" \
    "$sha_source_count" "$producer_object" "$main_object" \
    "$main_object_count" "$library_object" "$library_object_count" \
    "$events_object" "$events_object_count" "$semantic_sha_object" \
    "$semantic_sha_object_count" "$common_kif_source" \
    "$common_kif_source_count" "$common_unicode_source" \
    "$common_unicode_source_count" "$common_visibility_source" \
    "$common_visibility_source_count" "$common_kif_object" \
    "$common_kif_object_count" "$common_unicode_object" \
    "$common_unicode_object_count" "$common_sha_object" \
    "$common_sha_object_count" "$common_visibility_object" \
    "$common_visibility_object_count" "$optimization" "$library" \
    "$diagnostic_faults" "$work_limit" "$sanitizer" "$analyzer" "$pic" \
    "$compile_only" "$language_c11" "$debug" "$wall" "$wextra" \
    "$werror" "$pedantic" "$profile_extra" "$argument_count" \
    "$argv_hex" "$status" "$((end - start))" >>"$KOFUN_VERIFY_CC_LOG"

exit "$status"
