#!/bin/sh

# Runner-scoped object reuse for the one Stage 2 compiler sanitizer profile
# shared by five deterministic fuzz gates.  This file is sourced after
# semantic-objects.sh so it can reuse the repository's digest, immutable-tree,
# and executable-publication primitives without widening that bundle.

KOFUN_STAGE2_FUZZ_SANITIZER_PROFILE='-std=c11|-O1|-g|-Wall|-Wextra|-Werror|-fsanitize=address,undefined|-fno-omit-frame-pointer|-c|bootstrap/stage2/compiler.c|-o|compiler-fuzz-asan-ubsan.o'
KOFUN_STAGE2_FUZZ_SANITIZER_LINK_PROFILE='-std=c11|-O1|-g|-Wall|-Wextra|-Werror|-fsanitize=address,undefined|-fno-omit-frame-pointer|compiler-fuzz-asan-ubsan.o|-o|kofun-stage2-sanitized'

kofun_stage2_fuzz_sanitizer_fail() {
    printf '%s\n' "fuzz sanitizer object: $*" >&2
    return 1
}

kofun_stage2_fuzz_sanitizer_source_paths() {
    printf '%s\n' \
        bootstrap/stage2/compiler.c \
        bootstrap/stage2/decimal_v1.c \
        bootstrap/stage2/decimal_v1.h \
        unicode/kofun_unicode.c \
        unicode/kofun_unicode.h \
        unicode/kofun_unicode_tables.inc \
        vendor/utf8proc/utf8proc.c \
        vendor/utf8proc/utf8proc.h \
        vendor/utf8proc/utf8proc_data.c
}

# Resolve and digest the compiler which consumes the fixed argv.  Path and
# executable bytes detect accidental drift; the manifest is not a signature
# or an authentication authority for adversarial input.
kofun_stage2_fuzz_sanitizer_compiler_identity() {
    kofun_fuzz_identity_root=$1
    kofun_fuzz_identity_candidate=${2:-${KOFUN_VERIFY_REAL_CC:-${CC:-cc}}}
    KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH=$(
        command -v "$kofun_fuzz_identity_candidate"
    ) || {
        kofun_stage2_fuzz_sanitizer_fail \
            'a C11 compiler is required; set CC to its executable'
        return 1
    }
    case $KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH in
        /*) ;;
        *)
            kofun_fuzz_identity_dir=$(dirname -- \
                "$KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH")
            kofun_fuzz_identity_base=$(basename -- \
                "$KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH")
            kofun_fuzz_identity_dir=$(CDPATH= cd -P -- \
                "$kofun_fuzz_identity_dir" && pwd) || return 1
            KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH="$kofun_fuzz_identity_dir/$kofun_fuzz_identity_base"
            ;;
    esac
    case $KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH in
        *'
'*|*'	'*)
            kofun_stage2_fuzz_sanitizer_fail \
                'resolved C compiler path contains a tab or newline'
            return 1
            ;;
    esac
    if test ! -f "$KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH" ||
       test ! -x "$KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH"
    then
        kofun_stage2_fuzz_sanitizer_fail \
            'resolved C compiler is not an executable regular file'
        return 1
    fi
    KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_SHA256=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_fuzz_identity_root" \
            "$KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH" \
            'resolved fuzz sanitizer C compiler'
    ) || return 1
}

# Emit the canonical helper-produced provenance document.  Every source in the
# compiler's transitive repository include closure is named and content-bound.
kofun_stage2_fuzz_sanitizer_manifest_write() {
    kofun_fuzz_manifest_root=$1
    kofun_fuzz_manifest_dir=$2
    kofun_fuzz_manifest_cc=${3:-${KOFUN_VERIFY_REAL_CC:-${CC:-cc}}}

    kofun_stage2_fuzz_sanitizer_compiler_identity \
        "$kofun_fuzz_manifest_root" "$kofun_fuzz_manifest_cc" || return 1

    printf '%s\t%s\n' schema \
        kofun.stage2-fuzz-sanitizer-object-manifest/v1
    printf '%s\t%s\n' trust \
        helper-produced-drift-detection-not-authentication
    printf '%s\t%s\n' compiler-path \
        "$KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH"
    printf '%s\t%s\n' compiler-sha256 \
        "$KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_SHA256"
    printf '%s\t%s\t%s\n' profile compile \
        "$KOFUN_STAGE2_FUZZ_SANITIZER_PROFILE"
    printf '%s\t%s\t%s\n' profile link \
        "$KOFUN_STAGE2_FUZZ_SANITIZER_LINK_PROFILE"

    for kofun_fuzz_manifest_source in $(
        kofun_stage2_fuzz_sanitizer_source_paths
    )
    do
        kofun_fuzz_manifest_source_digest=$(
            kofun_stage2_semantic_digest_file \
                "$kofun_fuzz_manifest_root" \
                "$kofun_fuzz_manifest_root/$kofun_fuzz_manifest_source" \
                "fuzz sanitizer source $kofun_fuzz_manifest_source"
        ) || return 1
        printf '%s\t%s\t%s\n' source "$kofun_fuzz_manifest_source" \
            "$kofun_fuzz_manifest_source_digest"
    done

    kofun_fuzz_manifest_primary_digest=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_fuzz_manifest_root" \
            "$kofun_fuzz_manifest_root/bootstrap/stage2/compiler.c" \
            'fuzz sanitizer primary source'
    ) || return 1
    kofun_fuzz_manifest_object_digest=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_fuzz_manifest_root" \
            "$kofun_fuzz_manifest_dir/compiler-fuzz-asan-ubsan.o" \
            'fuzz sanitizer object member'
    ) || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        member compiler-fuzz-asan-ubsan \
        compiler-fuzz-asan-ubsan.o \
        bootstrap/stage2/compiler.c \
        "$kofun_fuzz_manifest_primary_digest" \
        "$kofun_fuzz_manifest_object_digest"

    kofun_fuzz_manifest_marker_digest=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_fuzz_manifest_root" \
            "$kofun_fuzz_manifest_dir/complete-v1" \
            'fuzz sanitizer completion marker'
    ) || return 1
    printf '%s\t%s\t%s\n' marker complete-v1 \
        "$kofun_fuzz_manifest_marker_digest"
}

# kofun_stage2_fuzz_sanitizer_objects_validate ROOT OBJECT_DIR [REAL_CC]
kofun_stage2_fuzz_sanitizer_objects_validate() {
    kofun_fuzz_validate_root=$1
    kofun_fuzz_validate_dir=$2
    kofun_fuzz_validate_cc=${3:-${KOFUN_VERIFY_REAL_CC:-${CC:-cc}}}
    KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_ID=

    if test -z "$kofun_fuzz_validate_dir"; then
        kofun_stage2_fuzz_sanitizer_fail \
            'KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR is set but empty'
        return 1
    fi
    if test -L "$kofun_fuzz_validate_dir" ||
       test ! -d "$kofun_fuzz_validate_dir"
    then
        kofun_stage2_fuzz_sanitizer_fail \
            "object bundle is not a directory: $kofun_fuzz_validate_dir"
        return 1
    fi

    kofun_fuzz_validate_mode=$(kofun_stage2_semantic_mode \
        "$kofun_fuzz_validate_dir") || {
        kofun_stage2_fuzz_sanitizer_fail \
            "cannot inspect object bundle mode: $kofun_fuzz_validate_dir"
        return 1
    }
    case $kofun_fuzz_validate_mode in
        dr-xr-xr-x*) ;;
        *w*)
            kofun_stage2_fuzz_sanitizer_fail \
                'object bundle directory is mutable (mode must be 0555)'
            return 1
            ;;
        *)
            kofun_stage2_fuzz_sanitizer_fail \
                'object bundle directory mode must be 0555'
            return 1
            ;;
    esac

    kofun_fuzz_validate_count=$(
        find "$kofun_fuzz_validate_dir" -mindepth 1 -maxdepth 1 -print |
            awk 'END { print NR + 0 }'
    ) || return 1
    if test "$kofun_fuzz_validate_count" -ne 3; then
        kofun_stage2_fuzz_sanitizer_fail \
            "object bundle must contain exactly three members, found $kofun_fuzz_validate_count"
        return 1
    fi

    for kofun_fuzz_validate_name in \
        compiler-fuzz-asan-ubsan.o complete-v1 manifest-v1.tsv
    do
        kofun_fuzz_validate_path="$kofun_fuzz_validate_dir/$kofun_fuzz_validate_name"
        if test -L "$kofun_fuzz_validate_path" ||
           test ! -f "$kofun_fuzz_validate_path"
        then
            kofun_stage2_fuzz_sanitizer_fail \
                "bundle member is missing or not regular: $kofun_fuzz_validate_name"
            return 1
        fi
        kofun_fuzz_validate_mode=$(kofun_stage2_semantic_mode \
            "$kofun_fuzz_validate_path") || return 1
        case $kofun_fuzz_validate_mode in
            -r--r--r--*) ;;
            *w*)
                kofun_stage2_fuzz_sanitizer_fail \
                    "bundle member is mutable: $kofun_fuzz_validate_name (mode must be 0444)"
                return 1
                ;;
            *)
                kofun_stage2_fuzz_sanitizer_fail \
                    "bundle member is not readable: $kofun_fuzz_validate_name (mode must be 0444)"
                return 1
                ;;
        esac
    done

    kofun_fuzz_validate_expected_marker_output=$(
        printf '%s\n' 'kofun.stage2-fuzz-sanitizer-object/v1' |
            "$kofun_fuzz_validate_root/bin/kofun-digest"
    ) || return 1
    kofun_fuzz_validate_expected_marker=${kofun_fuzz_validate_expected_marker_output%% *}
    kofun_fuzz_validate_actual_marker=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_fuzz_validate_root" \
            "$kofun_fuzz_validate_dir/complete-v1" \
            'fuzz sanitizer completion marker'
    ) || return 1
    if test "$kofun_fuzz_validate_actual_marker" != \
        "$kofun_fuzz_validate_expected_marker"
    then
        kofun_stage2_fuzz_sanitizer_fail \
            'bundle member has the wrong profile marker: complete-v1'
        return 1
    fi

    kofun_fuzz_validate_expected_manifest=$(
        kofun_stage2_fuzz_sanitizer_manifest_write \
            "$kofun_fuzz_validate_root" "$kofun_fuzz_validate_dir" \
            "$kofun_fuzz_validate_cc"
    ) || return 1
    kofun_fuzz_validate_expected_manifest_output=$(
        printf '%s\n' "$kofun_fuzz_validate_expected_manifest" |
            "$kofun_fuzz_validate_root/bin/kofun-digest"
    ) || return 1
    kofun_fuzz_validate_expected_manifest_digest=${kofun_fuzz_validate_expected_manifest_output%% *}
    kofun_fuzz_validate_actual_manifest_digest=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_fuzz_validate_root" \
            "$kofun_fuzz_validate_dir/manifest-v1.tsv" \
            'fuzz sanitizer provenance manifest'
    ) || return 1
    if test "$kofun_fuzz_validate_actual_manifest_digest" != \
        "$kofun_fuzz_validate_expected_manifest_digest"
    then
        kofun_stage2_fuzz_sanitizer_fail \
            'bundle provenance does not match current compiler, profile, source closure, and object bytes'
        return 1
    fi

    kofun_fuzz_validate_identity_material="${kofun_fuzz_validate_actual_manifest_digest}  manifest-v1.tsv
"
    for kofun_fuzz_validate_name in \
        compiler-fuzz-asan-ubsan.o complete-v1
    do
        kofun_fuzz_validate_digest=$(
            kofun_stage2_semantic_digest_file \
                "$kofun_fuzz_validate_root" \
                "$kofun_fuzz_validate_dir/$kofun_fuzz_validate_name" \
                "fuzz sanitizer bundle member $kofun_fuzz_validate_name"
        ) || return 1
        kofun_fuzz_validate_identity_material="${kofun_fuzz_validate_identity_material}${kofun_fuzz_validate_digest}  ${kofun_fuzz_validate_name}
"
    done
    kofun_fuzz_validate_identity_output=$(
        printf '%s' "$kofun_fuzz_validate_identity_material" |
            "$kofun_fuzz_validate_root/bin/kofun-digest"
    ) || return 1
    KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_ID=${kofun_fuzz_validate_identity_output%% *}
    case $KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_ID in
        *[!0-9a-f]*|'')
            kofun_stage2_fuzz_sanitizer_fail \
                'invalid object bundle identity'
            return 1
            ;;
    esac
    if test "${#KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_ID}" -ne 64; then
        kofun_stage2_fuzz_sanitizer_fail \
            'invalid object bundle identity length'
        return 1
    fi
}

# kofun_stage2_fuzz_sanitizer_objects_build ROOT OBJECT_DIR CENSUS REAL_CC
kofun_stage2_fuzz_sanitizer_objects_build() (
    set -eu

    kofun_fuzz_build_root=$1
    kofun_fuzz_build_out=$2
    kofun_fuzz_build_census=$3
    kofun_fuzz_build_real_cc=$4
    kofun_fuzz_build_parent=$(dirname -- "$kofun_fuzz_build_out")
    kofun_fuzz_build_base=$(basename -- "$kofun_fuzz_build_out")
    kofun_fuzz_build_wrapper="$kofun_fuzz_build_root/bootstrap/stage2/fuzz-sanitizer-cc-wrapper.sh"

    if test -z "$kofun_fuzz_build_census"; then
        kofun_stage2_fuzz_sanitizer_fail 'compiler argv census path is empty'
        exit 1
    fi
    if test -L "$kofun_fuzz_build_out" || test -e "$kofun_fuzz_build_out"; then
        kofun_stage2_fuzz_sanitizer_fail \
            "refusing to replace an existing object bundle: $kofun_fuzz_build_out"
        exit 1
    fi
    if test ! -f "$kofun_fuzz_build_real_cc" ||
       test ! -x "$kofun_fuzz_build_real_cc"
    then
        kofun_stage2_fuzz_sanitizer_fail \
            "real C compiler is not an executable regular file: $kofun_fuzz_build_real_cc"
        exit 1
    fi
    if test ! -x "$kofun_fuzz_build_wrapper"; then
        kofun_stage2_fuzz_sanitizer_fail \
            "compiler argv observer is not executable: $kofun_fuzz_build_wrapper"
        exit 1
    fi

    mkdir -p "$kofun_fuzz_build_parent" \
        "$(dirname -- "$kofun_fuzz_build_census")"
    if test -L "$kofun_fuzz_build_census" ||
       { test -e "$kofun_fuzz_build_census" &&
         test ! -f "$kofun_fuzz_build_census"; }
    then
        kofun_stage2_fuzz_sanitizer_fail \
            "compiler argv census is not a regular file: $kofun_fuzz_build_census"
        exit 1
    fi
    : >"$kofun_fuzz_build_census"

    kofun_fuzz_build_tmp=$(mktemp -d \
        "$kofun_fuzz_build_parent/.$kofun_fuzz_build_base.XXXXXX")
    cleanup_fuzz_build() {
        if test -n "${kofun_fuzz_build_tmp:-}"; then
            kofun_stage2_owned_tree_remove \
                "$kofun_fuzz_build_tmp" 2>/dev/null || true
        fi
    }
    trap cleanup_fuzz_build 0
    trap 'exit 129' 1
    trap 'exit 130' 2
    trap 'exit 143' 15

    KOFUN_FUZZ_SANITIZER_REAL_CC=$kofun_fuzz_build_real_cc \
    KOFUN_FUZZ_SANITIZER_CENSUS_LOG=$kofun_fuzz_build_census \
    KOFUN_FUZZ_SANITIZER_ROOT=$kofun_fuzz_build_root \
    KOFUN_FUZZ_SANITIZER_OBJECT_DIR=$kofun_fuzz_build_tmp \
    KOFUN_FUZZ_SANITIZER_LINK_ROLE= \
    KOFUN_FUZZ_SANITIZER_LINK_OUTPUT= \
        "$kofun_fuzz_build_wrapper" \
            -std=c11 -O1 -g -Wall -Wextra -Werror \
            -fsanitize=address,undefined -fno-omit-frame-pointer \
            -c "$kofun_fuzz_build_root/bootstrap/stage2/compiler.c" \
            -o "$kofun_fuzz_build_tmp/compiler-fuzz-asan-ubsan.o" || exit $?

    printf '%s\n' 'kofun.stage2-fuzz-sanitizer-object/v1' \
        >"$kofun_fuzz_build_tmp/complete-v1" || exit $?
    kofun_stage2_fuzz_sanitizer_manifest_write \
        "$kofun_fuzz_build_root" "$kofun_fuzz_build_tmp" \
        "$kofun_fuzz_build_real_cc" \
        >"$kofun_fuzz_build_tmp/manifest-v1.tsv" || exit $?

    chmod 0444 "$kofun_fuzz_build_tmp"/* || exit $?
    chmod 0555 "$kofun_fuzz_build_tmp" || exit $?
    kofun_stage2_fuzz_sanitizer_objects_validate \
        "$kofun_fuzz_build_root" "$kofun_fuzz_build_tmp" \
        "$kofun_fuzz_build_real_cc" || exit $?
    mv "$kofun_fuzz_build_tmp" "$kofun_fuzz_build_out" || exit $?
    kofun_fuzz_build_tmp=
    trap - 0 1 2 15
)

# Build the private executable for one of the five fixed consumers.  Unset is
# the exact historical source path.  Set-but-invalid is a hard refusal.
# kofun_stage2_fuzz_sanitized_compiler ROOT OUTPUT ROLE
kofun_stage2_fuzz_sanitized_compiler() {
    kofun_fuzz_compiler_root=$1
    kofun_fuzz_compiler_output=$2
    kofun_fuzz_compiler_role=$3
    case $kofun_fuzz_compiler_role in
        value-if|match-guard|match-value|match-value-invalid|enum-match) ;;
        *)
            kofun_stage2_fuzz_sanitizer_fail \
                "unknown fuzz sanitizer consumer role: $kofun_fuzz_compiler_role"
            return 1
            ;;
    esac

    if test "${KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR+x}" != x; then
        "${CC:-cc}" -std=c11 -O1 -g -Wall -Wextra -Werror \
            -fsanitize=address,undefined -fno-omit-frame-pointer \
            "$kofun_fuzz_compiler_root/bootstrap/stage2/compiler.c" \
            -o "$kofun_fuzz_compiler_output"
        return
    fi

    kofun_fuzz_compiler_dir=$KOFUN_STAGE2_FUZZ_SANITIZER_OBJECT_DIR
    kofun_fuzz_compiler_census=${KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG:-}
    kofun_fuzz_compiler_real_cc=${KOFUN_VERIFY_REAL_CC:-${CC:-cc}}
    if test -z "$kofun_fuzz_compiler_census"; then
        kofun_stage2_fuzz_sanitizer_fail \
            'supplied object requires KOFUN_STAGE2_FUZZ_SANITIZER_CENSUS_LOG'
        return 1
    fi
    if test -L "$kofun_fuzz_compiler_census" ||
       test ! -f "$kofun_fuzz_compiler_census"
    then
        kofun_stage2_fuzz_sanitizer_fail \
            "compiler argv census is missing or not regular: $kofun_fuzz_compiler_census"
        return 1
    fi
    kofun_stage2_fuzz_sanitizer_objects_validate \
        "$kofun_fuzz_compiler_root" "$kofun_fuzz_compiler_dir" \
        "$kofun_fuzz_compiler_real_cc" || return 1
    kofun_stage2_fuzz_sanitizer_compiler_identity \
        "$kofun_fuzz_compiler_root" "$kofun_fuzz_compiler_real_cc" || return 1

    kofun_fuzz_compiler_wrapper="$kofun_fuzz_compiler_root/bootstrap/stage2/fuzz-sanitizer-cc-wrapper.sh"
    (
        KOFUN_FUZZ_SANITIZER_REAL_CC=$KOFUN_STAGE2_FUZZ_SANITIZER_COMPILER_PATH
        KOFUN_FUZZ_SANITIZER_CENSUS_LOG=$kofun_fuzz_compiler_census
        KOFUN_FUZZ_SANITIZER_ROOT=$kofun_fuzz_compiler_root
        KOFUN_FUZZ_SANITIZER_OBJECT_DIR=$kofun_fuzz_compiler_dir
        KOFUN_FUZZ_SANITIZER_LINK_ROLE=$kofun_fuzz_compiler_role
        KOFUN_FUZZ_SANITIZER_LINK_OUTPUT=$kofun_fuzz_compiler_output
        export KOFUN_FUZZ_SANITIZER_REAL_CC \
            KOFUN_FUZZ_SANITIZER_CENSUS_LOG KOFUN_FUZZ_SANITIZER_ROOT \
            KOFUN_FUZZ_SANITIZER_OBJECT_DIR \
            KOFUN_FUZZ_SANITIZER_LINK_ROLE KOFUN_FUZZ_SANITIZER_LINK_OUTPUT
        kofun_stage2_semantic_executable_link \
            "$kofun_fuzz_compiler_output" \
            "$kofun_fuzz_compiler_wrapper" \
                -std=c11 -O1 -g -Wall -Wextra -Werror \
                -fsanitize=address,undefined -fno-omit-frame-pointer \
                "$kofun_fuzz_compiler_dir/compiler-fuzz-asan-ubsan.o"
    )
}

# kofun_stage2_fuzz_sanitizer_census_validate CENSUS
kofun_stage2_fuzz_sanitizer_census_validate() {
    kofun_fuzz_census=$1
    if test -L "$kofun_fuzz_census" || test ! -f "$kofun_fuzz_census"; then
        kofun_stage2_fuzz_sanitizer_fail \
            "compiler argv census is missing or not regular: $kofun_fuzz_census"
        return 1
    fi
    awk -F '\t' '
        BEGIN {
            expected["compile:shared"] = "compiler-fuzz-asan-ubsan.o"
            expected["link:value-if"] = "kofun-stage2-sanitized"
            expected["link:match-guard"] = "kofun-stage2-sanitized"
            expected["link:match-value"] = "kofun-stage2-sanitized"
            expected["link:match-value-invalid"] = "kofun-stage2-sanitized"
            expected["link:enum-match"] = "kofun-stage2-sanitized"
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
            identity = field["kind"] ":" field["role"]
            if (!(identity in expected)) bad = 1
            if (field["output"] != expected[identity]) bad = 1
            if (field["profile"] != "fuzz-stage2-asan-ubsan-v1") bad = 1
            if (field["status"] != "0") bad = 1
            if (field["wall_ns"] !~ /^[0-9]+$/) bad = 1
            seen[identity]++
            total++
        }
        END {
            if (total != 6) bad = 1
            for (identity in expected) {
                if (seen[identity] != 1) bad = 1
            }
            if (bad) {
                print "fuzz sanitizer object: compiler argv census is incomplete or invalid" > "/dev/stderr"
                exit 1
            }
        }
    ' "$kofun_fuzz_census"
}
