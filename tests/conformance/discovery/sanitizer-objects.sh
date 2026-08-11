#!/bin/sh

# Discovery-private ASan/UBSan support objects.
#
# This file is sourced.  The bundle is deliberately runner-scoped: unlike the
# ordinary Stage 2 semantic bundle, it has no persistent lookup path or cache
# identity.  The compiler wrapper observes the exact argv which produced every
# member; this helper owns only publication, byte/mode validation, and the
# fixed six-member closure.

KOFUN_DISCOVERY_SANITIZER_PROFILE='-std=c11|-O1|-g|-Wall|-Wextra|-Werror|-pedantic|-fno-omit-frame-pointer|-fsanitize=address,undefined|-DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY|-Ibootstrap/stage2'

kofun_discovery_sanitizer_fail() {
    printf '%s\n' "discovery sanitizer objects: $*" >&2
    return 1
}

kofun_discovery_sanitizer_mode() {
    kofun_discovery_sanitizer_mode_line=$(LC_ALL=C ls -ld -- "$1") ||
        return 1
    printf '%s\n' "${kofun_discovery_sanitizer_mode_line%% *}"
}

kofun_discovery_sanitizer_digest_file() {
    kofun_discovery_sanitizer_digest_root=$1
    kofun_discovery_sanitizer_digest_path=$2
    kofun_discovery_sanitizer_digest_label=$3
    kofun_discovery_sanitizer_digest_output=$(
        "$kofun_discovery_sanitizer_digest_root/bin/kofun-digest" \
            "$kofun_discovery_sanitizer_digest_path"
    ) || {
        kofun_discovery_sanitizer_fail \
            "cannot digest $kofun_discovery_sanitizer_digest_label"
        return 1
    }
    kofun_discovery_sanitizer_digest=${kofun_discovery_sanitizer_digest_output%% *}
    case $kofun_discovery_sanitizer_digest in
        *[!0-9a-f]*|'')
            kofun_discovery_sanitizer_fail \
                "invalid digest for $kofun_discovery_sanitizer_digest_label"
            return 1
            ;;
    esac
    test "${#kofun_discovery_sanitizer_digest}" -eq 64 || {
        kofun_discovery_sanitizer_fail \
            "invalid digest for $kofun_discovery_sanitizer_digest_label"
        return 1
    }
    printf '%s\n' "$kofun_discovery_sanitizer_digest"
}

kofun_discovery_sanitizer_member_specs() {
    printf '%s\n' \
        'semantic-producer|semantic-producer-library.o|bootstrap/stage2/semantic_producer.c' \
        'semantic-events|semantic-events.o|bootstrap/stage2/semantic_events.c' \
        'sha256|sha256.o|bootstrap/stage2/sha256.c' \
        'discovery-v1|discovery-v1.o|bootstrap/stage2/discovery_v1.c' \
        'discovery-provider|discovery-provider.o|bootstrap/stage2/discovery_provider.c' \
        'discovery-query|discovery-query.o|bootstrap/stage2/discovery_query.c'
}

kofun_discovery_sanitizer_manifest_write() {
    kofun_discovery_sanitizer_manifest_root=$1
    kofun_discovery_sanitizer_manifest_dir=$2

    printf '%s\t%s\n' schema kofun.discovery-sanitizer-objects/v1
    printf '%s\t%s\n' profile "$KOFUN_DISCOVERY_SANITIZER_PROFILE"
    kofun_discovery_sanitizer_manifest_specs=$(
        kofun_discovery_sanitizer_member_specs
    ) || return 1
    kofun_discovery_sanitizer_manifest_old_ifs=$IFS
    IFS='
'
    for kofun_discovery_sanitizer_manifest_spec in \
        $kofun_discovery_sanitizer_manifest_specs
    do
        IFS='|'
        set -- $kofun_discovery_sanitizer_manifest_spec
        IFS='
'
        kofun_discovery_sanitizer_member_role=$1
        kofun_discovery_sanitizer_member_name=$2
        kofun_discovery_sanitizer_member_source=$3
        kofun_discovery_sanitizer_member_digest=$(
            kofun_discovery_sanitizer_digest_file \
                "$kofun_discovery_sanitizer_manifest_root" \
                "$kofun_discovery_sanitizer_manifest_dir/$kofun_discovery_sanitizer_member_name" \
                "member $kofun_discovery_sanitizer_member_name"
        ) || {
            IFS=$kofun_discovery_sanitizer_manifest_old_ifs
            return 1
        }
        printf '%s\t%s\t%s\t%s\t%s\n' \
            member \
            "$kofun_discovery_sanitizer_member_role" \
            "$kofun_discovery_sanitizer_member_name" \
            "$kofun_discovery_sanitizer_member_source" \
            "$kofun_discovery_sanitizer_member_digest"
    done
    IFS=$kofun_discovery_sanitizer_manifest_old_ifs
}

# kofun_discovery_sanitizer_objects_validate ROOT OBJECT_DIR
kofun_discovery_sanitizer_objects_validate() {
    kofun_discovery_sanitizer_object_root=$1
    kofun_discovery_sanitizer_object_dir=$2

    test -n "$kofun_discovery_sanitizer_object_dir" || {
        kofun_discovery_sanitizer_fail 'object directory is empty'
        return 1
    }
    if test -L "$kofun_discovery_sanitizer_object_dir" ||
       test ! -d "$kofun_discovery_sanitizer_object_dir"
    then
        kofun_discovery_sanitizer_fail \
            "object bundle is not a directory: $kofun_discovery_sanitizer_object_dir"
        return 1
    fi

    kofun_discovery_sanitizer_object_mode=$(
        kofun_discovery_sanitizer_mode \
            "$kofun_discovery_sanitizer_object_dir"
    ) || return 1
    case $kofun_discovery_sanitizer_object_mode in
        dr-xr-xr-x*) ;;
        *w*)
            kofun_discovery_sanitizer_fail \
                'object bundle directory is mutable (mode must be 0555)'
            return 1
            ;;
        *)
            kofun_discovery_sanitizer_fail \
                'object bundle directory mode must be 0555'
            return 1
            ;;
    esac

    kofun_discovery_sanitizer_entry_count=$(
        find "$kofun_discovery_sanitizer_object_dir" \
            -mindepth 1 -maxdepth 1 -print | awk 'END { print NR + 0 }'
    ) || return 1
    test "$kofun_discovery_sanitizer_entry_count" -eq 8 || {
        kofun_discovery_sanitizer_fail \
            "object bundle must contain exactly eight members, found $kofun_discovery_sanitizer_entry_count"
        return 1
    }

    for kofun_discovery_sanitizer_object_name in \
        semantic-producer-library.o \
        semantic-events.o \
        sha256.o \
        discovery-v1.o \
        discovery-provider.o \
        discovery-query.o \
        complete-v1 \
        manifest-v1.tsv
    do
        kofun_discovery_sanitizer_object_path="$kofun_discovery_sanitizer_object_dir/$kofun_discovery_sanitizer_object_name"
        if test -L "$kofun_discovery_sanitizer_object_path" ||
           test ! -f "$kofun_discovery_sanitizer_object_path"
        then
            kofun_discovery_sanitizer_fail \
                "bundle member is missing or not regular: $kofun_discovery_sanitizer_object_name"
            return 1
        fi
        kofun_discovery_sanitizer_object_mode=$(
            kofun_discovery_sanitizer_mode \
                "$kofun_discovery_sanitizer_object_path"
        ) || return 1
        case $kofun_discovery_sanitizer_object_mode in
            -r--r--r--*) ;;
            *w*)
                kofun_discovery_sanitizer_fail \
                    "bundle member is mutable: $kofun_discovery_sanitizer_object_name (mode must be 0444)"
                return 1
                ;;
            *)
                kofun_discovery_sanitizer_fail \
                    "bundle member is not readable: $kofun_discovery_sanitizer_object_name (mode must be 0444)"
                return 1
                ;;
        esac
    done

    kofun_discovery_sanitizer_expected_marker=$(
        printf '%s\n' 'kofun.discovery-sanitizer-objects/v1' |
            "$kofun_discovery_sanitizer_object_root/bin/kofun-digest"
    ) || return 1
    kofun_discovery_sanitizer_expected_marker=${kofun_discovery_sanitizer_expected_marker%% *}
    kofun_discovery_sanitizer_actual_marker=$(
        kofun_discovery_sanitizer_digest_file \
            "$kofun_discovery_sanitizer_object_root" \
            "$kofun_discovery_sanitizer_object_dir/complete-v1" \
            complete-v1
    ) || return 1
    test "$kofun_discovery_sanitizer_actual_marker" = \
        "$kofun_discovery_sanitizer_expected_marker" || {
        kofun_discovery_sanitizer_fail \
            'bundle member has the wrong profile marker: complete-v1'
        return 1
    }

    kofun_discovery_sanitizer_expected_manifest=$(
        kofun_discovery_sanitizer_manifest_write \
            "$kofun_discovery_sanitizer_object_root" \
            "$kofun_discovery_sanitizer_object_dir"
    ) || return 1
    kofun_discovery_sanitizer_expected_manifest_digest=$(
        printf '%s\n' "$kofun_discovery_sanitizer_expected_manifest" |
            "$kofun_discovery_sanitizer_object_root/bin/kofun-digest"
    ) || return 1
    kofun_discovery_sanitizer_expected_manifest_digest=${kofun_discovery_sanitizer_expected_manifest_digest%% *}
    kofun_discovery_sanitizer_actual_manifest_digest=$(
        kofun_discovery_sanitizer_digest_file \
            "$kofun_discovery_sanitizer_object_root" \
            "$kofun_discovery_sanitizer_object_dir/manifest-v1.tsv" \
            manifest-v1.tsv
    ) || return 1
    test "$kofun_discovery_sanitizer_actual_manifest_digest" = \
        "$kofun_discovery_sanitizer_expected_manifest_digest" || {
        kofun_discovery_sanitizer_fail \
            'bundle manifest does not match the fixed profile and member bytes'
        return 1
    }
}

# kofun_discovery_sanitizer_objects_build ROOT OBJECT_DIR CENSUS_LOG REAL_CC
kofun_discovery_sanitizer_objects_build() (
    set -eu

    kofun_discovery_sanitizer_build_root=$1
    kofun_discovery_sanitizer_build_out=$2
    kofun_discovery_sanitizer_build_log=$3
    kofun_discovery_sanitizer_build_real_cc=$4
    kofun_discovery_sanitizer_build_wrapper="$kofun_discovery_sanitizer_build_root/tests/conformance/discovery/sanitizer-cc-wrapper.sh"
    kofun_discovery_sanitizer_build_parent=$(dirname -- \
        "$kofun_discovery_sanitizer_build_out")
    kofun_discovery_sanitizer_build_base=$(basename -- \
        "$kofun_discovery_sanitizer_build_out")

    test -x "$kofun_discovery_sanitizer_build_wrapper" || {
        kofun_discovery_sanitizer_fail \
            'sanitizer compiler wrapper is not executable'
        exit 1
    }
    command -v "$kofun_discovery_sanitizer_build_real_cc" >/dev/null 2>&1 || {
        kofun_discovery_sanitizer_fail 'real C compiler is unavailable'
        exit 1
    }
    test ! -e "$kofun_discovery_sanitizer_build_out" &&
        test ! -L "$kofun_discovery_sanitizer_build_out" || {
        kofun_discovery_sanitizer_fail \
            "refusing to replace object bundle: $kofun_discovery_sanitizer_build_out"
        exit 1
    }
    mkdir -p "$kofun_discovery_sanitizer_build_parent" || exit 1
    kofun_discovery_sanitizer_build_tmp=$(mktemp -d \
        "$kofun_discovery_sanitizer_build_parent/.$kofun_discovery_sanitizer_build_base.XXXXXX") || exit 1
    kofun_discovery_sanitizer_build_cleanup() {
        if test -n "${kofun_discovery_sanitizer_build_tmp:-}"; then
            kofun_stage2_owned_tree_remove \
                "$kofun_discovery_sanitizer_build_tmp" 2>/dev/null || true
        fi
    }
    trap kofun_discovery_sanitizer_build_cleanup 0
    trap 'exit 129' 1
    trap 'exit 130' 2
    trap 'exit 143' 15

    : >"$kofun_discovery_sanitizer_build_log" || exit 1
    export KOFUN_DISCOVERY_SANITIZER_REAL_CC="$kofun_discovery_sanitizer_build_real_cc"
    export KOFUN_DISCOVERY_SANITIZER_CENSUS_LOG="$kofun_discovery_sanitizer_build_log"
    export KOFUN_DISCOVERY_SANITIZER_ROOT="$kofun_discovery_sanitizer_build_root"
    export KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR="$kofun_discovery_sanitizer_build_tmp"

    kofun_discovery_sanitizer_build_specs=$(
        kofun_discovery_sanitizer_member_specs
    )
    kofun_discovery_sanitizer_build_old_ifs=$IFS
    IFS='
'
    for kofun_discovery_sanitizer_build_spec in \
        $kofun_discovery_sanitizer_build_specs
    do
        IFS='|'
        set -- $kofun_discovery_sanitizer_build_spec
        IFS='
'
        kofun_discovery_sanitizer_build_role=$1
        kofun_discovery_sanitizer_build_name=$2
        kofun_discovery_sanitizer_build_source=$3
        "$kofun_discovery_sanitizer_build_wrapper" \
            -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
            -fno-omit-frame-pointer -fsanitize=address,undefined \
            -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
            -I"$kofun_discovery_sanitizer_build_root/bootstrap/stage2" \
            -c "$kofun_discovery_sanitizer_build_root/$kofun_discovery_sanitizer_build_source" \
            -o "$kofun_discovery_sanitizer_build_tmp/$kofun_discovery_sanitizer_build_name" || {
            IFS=$kofun_discovery_sanitizer_build_old_ifs
            exit 1
        }
    done
    IFS=$kofun_discovery_sanitizer_build_old_ifs

    printf '%s\n' 'kofun.discovery-sanitizer-objects/v1' \
        >"$kofun_discovery_sanitizer_build_tmp/complete-v1" || exit 1
    kofun_discovery_sanitizer_manifest_write \
        "$kofun_discovery_sanitizer_build_root" \
        "$kofun_discovery_sanitizer_build_tmp" \
        >"$kofun_discovery_sanitizer_build_tmp/manifest-v1.tsv" || exit 1
    chmod 0444 "$kofun_discovery_sanitizer_build_tmp"/* || exit 1
    chmod 0555 "$kofun_discovery_sanitizer_build_tmp" || exit 1
    mv "$kofun_discovery_sanitizer_build_tmp" \
        "$kofun_discovery_sanitizer_build_out" || exit 1
    kofun_discovery_sanitizer_build_tmp=
    trap - 0 1 2 15

    kofun_discovery_sanitizer_objects_validate \
        "$kofun_discovery_sanitizer_build_root" \
        "$kofun_discovery_sanitizer_build_out"
)

# kofun_discovery_sanitizer_link ROOT OBJECT_DIR CENSUS_LOG REAL_CC DRIVER OUTPUT
kofun_discovery_sanitizer_link() {
    kofun_discovery_sanitizer_link_root=$1
    kofun_discovery_sanitizer_link_dir=$2
    kofun_discovery_sanitizer_link_log=$3
    kofun_discovery_sanitizer_link_real_cc=$4
    kofun_discovery_sanitizer_link_driver=$5
    kofun_discovery_sanitizer_link_output=$6
    kofun_discovery_sanitizer_link_wrapper="$kofun_discovery_sanitizer_link_root/tests/conformance/discovery/sanitizer-cc-wrapper.sh"

    kofun_discovery_sanitizer_objects_validate \
        "$kofun_discovery_sanitizer_link_root" \
        "$kofun_discovery_sanitizer_link_dir" || return 1
    KOFUN_DISCOVERY_SANITIZER_REAL_CC=$kofun_discovery_sanitizer_link_real_cc \
    KOFUN_DISCOVERY_SANITIZER_CENSUS_LOG=$kofun_discovery_sanitizer_link_log \
    KOFUN_DISCOVERY_SANITIZER_ROOT=$kofun_discovery_sanitizer_link_root \
    KOFUN_DISCOVERY_SANITIZER_OBJECT_DIR=$kofun_discovery_sanitizer_link_dir \
    KOFUN_DISCOVERY_SANITIZER_OUTPUT=$kofun_discovery_sanitizer_link_output \
        "$kofun_discovery_sanitizer_link_wrapper" \
            -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic \
            -fno-omit-frame-pointer -fsanitize=address,undefined \
            -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
            -I"$kofun_discovery_sanitizer_link_root/bootstrap/stage2" \
            "$kofun_discovery_sanitizer_link_dir/semantic-producer-library.o" \
            "$kofun_discovery_sanitizer_link_dir/semantic-events.o" \
            "$kofun_discovery_sanitizer_link_dir/sha256.o" \
            "$kofun_discovery_sanitizer_link_dir/discovery-v1.o" \
            "$kofun_discovery_sanitizer_link_dir/discovery-provider.o" \
            "$kofun_discovery_sanitizer_link_dir/discovery-query.o" \
            "$kofun_discovery_sanitizer_link_driver" \
            -o "$kofun_discovery_sanitizer_link_output"
}

# kofun_discovery_sanitizer_census_validate CENSUS_LOG
kofun_discovery_sanitizer_census_validate() {
    awk -F '\t' '
        BEGIN {
            expected["compile:semantic-producer"] = "semantic-producer-library.o"
            expected["compile:semantic-events"] = "semantic-events.o"
            expected["compile:sha256"] = "sha256.o"
            expected["compile:discovery-v1"] = "discovery-v1.o"
            expected["compile:discovery-provider"] = "discovery-provider.o"
            expected["compile:discovery-query"] = "discovery-query.o"
            expected["link:live-query"] = "live-query-sanitized"
            expected["link:nominal-typeid"] = "nominal-typeid-sanitized"
            expected["link:bounded-typeid"] = "bounded-typeid-sanitized"
            expected["link:closure"] = "closure-sanitized"
        }
        {
            delete field
            if ($1 != "cc" || NF != 7) bad = 1
            for (column = 2; column <= NF; column++) {
                equals = index($column, "=")
                if (equals == 0) {
                    bad = 1
                    continue
                }
                key = substr($column, 1, equals - 1)
                value = substr($column, equals + 1)
                if (key in field) bad = 1
                field[key] = value
            }
            if (!(field["kind"] == "compile" || field["kind"] == "link")) bad = 1
            identity = field["kind"] ":" field["unit"]
            if (!(identity in expected)) bad = 1
            if (field["output"] != expected[identity]) bad = 1
            if (field["profile"] != "asan-ubsan-library-v1") bad = 1
            if (field["status"] != "0") bad = 1
            if (field["wall_ns"] !~ /^[0-9]+$/) bad = 1
            seen[identity]++
            total++
        }
        END {
            if (total != 10) bad = 1
            for (identity in expected) {
                if (seen[identity] != 1) bad = 1
            }
            if (bad) {
                print "discovery sanitizer objects: compiler argv census is incomplete or invalid" > "/dev/stderr"
                exit 1
            }
        }
    ' "$1"
}
