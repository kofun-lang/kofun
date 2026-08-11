#!/bin/sh

# Runner-scoped object reuse for the ordinary Stage 2 semantic producer.
#
# This file is sourced.  It deliberately owns both halves of the contract:
# one builder publishes a complete immutable bundle, and every consumer uses
# the same validator before choosing source files or supplied objects.  A set
# but invalid KOFUN_STAGE2_SEMANTIC_OBJECT_DIR is an error; falling back in
# that case would quietly mix build profiles.

kofun_stage2_semantic_object_fail() {
    printf '%s\n' "semantic objects: $*" >&2
    return 1
}

# kofun_stage2_semantic_executable_validate OUTPUT
#
# A cached executable is trusted only as a regular file.  In particular, do
# not let an attacker-controlled or interrupted prior build turn the stable
# content-key path into a symlink that bypasses the linker.
kofun_stage2_semantic_executable_validate() {
    kofun_semantic_executable=$1
    if test -L "$kofun_semantic_executable"; then
        kofun_stage2_semantic_object_fail \
            "cached semantic executable is a symlink: $kofun_semantic_executable"
        return 1
    fi
    if test -e "$kofun_semantic_executable" &&
       test ! -f "$kofun_semantic_executable"
    then
        kofun_stage2_semantic_object_fail \
            "cached semantic executable is not a regular file: $kofun_semantic_executable"
        return 1
    fi
}

# kofun_stage2_semantic_executable_link OUTPUT COMMAND ARG...
#
# Link to an unpredictable file in the destination directory, then publish by
# rename.  Concurrent links of one content identity may both finish; either
# complete regular file is valid.  A signal or compiler failure removes only
# this invocation's private file and never exposes a partial executable.
kofun_stage2_semantic_executable_link() (
    set -eu

    kofun_semantic_executable_output=$1
    shift
    kofun_stage2_semantic_executable_validate \
        "$kofun_semantic_executable_output"
    kofun_semantic_executable_parent=$(dirname -- \
        "$kofun_semantic_executable_output")
    kofun_semantic_executable_base=$(basename -- \
        "$kofun_semantic_executable_output")
    kofun_semantic_executable_tmp=$(mktemp \
        "$kofun_semantic_executable_parent/.$kofun_semantic_executable_base.XXXXXX")
    cleanup_semantic_executable() {
        if test -n "${kofun_semantic_executable_tmp:-}"; then
            rm -f "$kofun_semantic_executable_tmp"
        fi
    }
    trap cleanup_semantic_executable 0
    trap 'exit 129' 1
    trap 'exit 130' 2
    trap 'exit 143' 15

    "$@" -o "$kofun_semantic_executable_tmp"
    test -f "$kofun_semantic_executable_tmp" &&
        test -x "$kofun_semantic_executable_tmp" || {
        kofun_stage2_semantic_object_fail \
            'compiler did not produce an executable regular file'
        exit 1
    }
    mv -f "$kofun_semantic_executable_tmp" \
        "$kofun_semantic_executable_output"
    kofun_semantic_executable_tmp=
    trap - 0 1 2 15
)

# Print the permission bits in the stable ten-character form used by POSIX
# `ls -l`.  `test -r` and `test -w` answer effective access instead: uid 0 can
# write a 0444 file, which made both the positive bundle and the unreadable
# mutation meaningless in root-run CI.
kofun_stage2_semantic_mode() {
    kofun_semantic_mode_line=$(LC_ALL=C ls -ld -- "$1") || return 1
    printf '%s\n' "${kofun_semantic_mode_line%% *}"
}

# Remove one owned temporary tree without ever following a replacement symlink
# at its root.  Renaming the entry first makes the ownership decision on the
# entry itself; only a verified directory is traversed, and find's default
# physical walk does not follow nested symlinks.  This is intentionally more
# careful than `test -d; chmod -R`: both operations follow a command-line
# symlink and can mutate a directory outside the runner's ownership.
kofun_stage2_owned_tree_remove() {
    kofun_owned_tree=$1
    if test ! -e "$kofun_owned_tree" && test ! -L "$kofun_owned_tree"; then
        return 0
    fi

    kofun_owned_parent=$(dirname -- "$kofun_owned_tree")
    kofun_owned_base=$(basename -- "$kofun_owned_tree")
    kofun_owned_before_line=$(LC_ALL=C ls -di -- "$kofun_owned_tree") ||
        return 1
    kofun_owned_before=${kofun_owned_before_line%% *}
    kofun_owned_tombstone=$(mktemp -d \
        "$kofun_owned_parent/.$kofun_owned_base.cleanup.XXXXXX") || return 1
    rmdir "$kofun_owned_tombstone" || return 1
    if ! mv -- "$kofun_owned_tree" "$kofun_owned_tombstone"; then
        return 1
    fi

    kofun_owned_after_line=$(LC_ALL=C ls -di -- "$kofun_owned_tombstone") ||
        return 1
    kofun_owned_after=${kofun_owned_after_line%% *}
    if test "$kofun_owned_before" != "$kofun_owned_after"; then
        # Do not chmod an entry whose identity changed.  rm -rf does not follow
        # a symlink named as its command-line root.
        rm -rf -- "$kofun_owned_tombstone"
        return 1
    fi
    if test -L "$kofun_owned_tombstone" ||
       test ! -d "$kofun_owned_tombstone"
    then
        rm -f -- "$kofun_owned_tombstone"
        return 0
    fi

    find "$kofun_owned_tombstone" -type d \
        -exec chmod u+w -- {} + 2>/dev/null || true
    rm -rf -- "$kofun_owned_tombstone"
}

kofun_stage2_semantic_digest_file() {
    kofun_semantic_digest_root=$1
    kofun_semantic_digest_path=$2
    kofun_semantic_digest_label=$3
    test -x "$kofun_semantic_digest_root/bin/kofun-digest" || {
        kofun_stage2_semantic_object_fail \
            'repository digest tool is unavailable'
        return 1
    }
    kofun_semantic_digest_output=$(
        "$kofun_semantic_digest_root/bin/kofun-digest" \
            "$kofun_semantic_digest_path"
    ) || {
        kofun_stage2_semantic_object_fail \
            "cannot digest $kofun_semantic_digest_label"
        return 1
    }
    kofun_semantic_digest=${kofun_semantic_digest_output%% *}
    case $kofun_semantic_digest in
        *[!0-9a-f]*|'')
            kofun_stage2_semantic_object_fail \
                "invalid digest for $kofun_semantic_digest_label"
            return 1
            ;;
    esac
    test "${#kofun_semantic_digest}" -eq 64 || {
        kofun_stage2_semantic_object_fail \
            "invalid digest for $kofun_semantic_digest_label"
        return 1
    }
    printf '%s\n' "$kofun_semantic_digest"
}

# Resolve the compiler which actually consumes the C argv.  During aggregate
# verify CC names the census wrapper, so KOFUN_VERIFY_REAL_CC is the identity
# that belongs in provenance.  Path plus executable bytes are an identity for
# accidental/drift detection; this is not a signature or an authentication
# authority for manifests supplied by an adversary.
kofun_stage2_semantic_compiler_identity() {
    kofun_semantic_compiler_root=$1
    kofun_semantic_compiler_candidate=${KOFUN_VERIFY_REAL_CC:-${CC:-cc}}
    KOFUN_STAGE2_SEMANTIC_COMPILER_PATH=$(
        command -v "$kofun_semantic_compiler_candidate"
    ) || {
        kofun_stage2_semantic_object_fail \
            'a C11 compiler is required; set CC to its executable'
        return 1
    }
    case $KOFUN_STAGE2_SEMANTIC_COMPILER_PATH in
        /*) ;;
        *)
            kofun_semantic_compiler_dir=$(dirname -- \
                "$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH")
            kofun_semantic_compiler_base=$(basename -- \
                "$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH")
            kofun_semantic_compiler_dir=$(CDPATH= cd -P -- \
                "$kofun_semantic_compiler_dir" && pwd) || return 1
            KOFUN_STAGE2_SEMANTIC_COMPILER_PATH="$kofun_semantic_compiler_dir/$kofun_semantic_compiler_base"
            ;;
    esac
    case $KOFUN_STAGE2_SEMANTIC_COMPILER_PATH in
        *'
'*|*'	'*)
            kofun_stage2_semantic_object_fail \
                'resolved C compiler path contains a tab or newline'
            return 1
            ;;
    esac
    test -f "$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH" &&
        test -x "$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH" || {
        kofun_stage2_semantic_object_fail \
            'resolved C compiler is not an executable regular file'
        return 1
    }
    KOFUN_STAGE2_SEMANTIC_COMPILER_SHA256=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_semantic_compiler_root" \
            "$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH" \
            'resolved C compiler'
    ) || return 1
}

kofun_stage2_semantic_source_paths() {
    printf '%s\n' \
        bootstrap/stage2/semantic_producer.c \
        bootstrap/stage2/semantic_producer.h \
        bootstrap/stage2/semantic_events.c \
        bootstrap/stage2/semantic_events.h \
        bootstrap/stage2/sha256.c \
        bootstrap/stage2/sha256.h \
        bootstrap/stage2/effect_inference.h \
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

kofun_stage2_semantic_kif_source_paths() {
    printf '%s\n' \
        bootstrap/stage2/stage2_kif_producer.c \
        bootstrap/stage2/kif_v1.c \
        bootstrap/stage2/stage2_kif_producer.h \
        bootstrap/stage2/kif_v1.h \
        bootstrap/stage2/semantic_producer.h \
        bootstrap/stage2/semantic_events.h \
        bootstrap/stage2/sha256.h \
        unicode/kofun_unicode.h
}

# Emit the one canonical helper-produced provenance manifest.  Every line and
# its order are load-bearing: validation hashes these exact bytes, so unknown
# keys, duplicate roles, extra lines, profile changes, source drift, and member
# replacement all refuse.  A forged manifest can lie because no signing
# authority exists; this contract detects accidental/drift/corruption only.
kofun_stage2_semantic_manifest_write() {
    kofun_semantic_manifest_root=$1
    kofun_semantic_manifest_dir=$2
    kofun_stage2_semantic_compiler_identity \
        "$kofun_semantic_manifest_root" || return 1

    printf '%s\t%s\n' schema kofun.stage2-semantic-object-manifest/v1
    printf '%s\t%s\n' trust helper-produced-drift-detection-not-authentication
    printf '%s\t%s\n' compiler-path \
        "$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH"
    printf '%s\t%s\n' compiler-sha256 \
        "$KOFUN_STAGE2_SEMANTIC_COMPILER_SHA256"
    printf '%s\t%s\t%s\n' profile main \
        '-std=c11|-O2|-g|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|bootstrap/stage2/semantic_producer.c|-o|semantic-producer-main.o'
    printf '%s\t%s\t%s\n' profile library \
        '-std=c11|-O2|-g|-Wall|-Wextra|-Werror|-pedantic|-DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY|-Ibootstrap/stage2|-c|bootstrap/stage2/semantic_producer.c|-o|semantic-producer-library.o'
    printf '%s\t%s\t%s\n' profile events \
        '-std=c11|-O2|-g|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|bootstrap/stage2/semantic_events.c|-o|semantic-events.o'
    printf '%s\t%s\t%s\n' profile sha256 \
        '-std=c11|-O2|-g|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|-c|bootstrap/stage2/sha256.c|-o|sha256.o'

    kofun_stage2_semantic_source_paths |
    while IFS= read -r kofun_semantic_source_path; do
        kofun_semantic_source_digest=$(
            kofun_stage2_semantic_digest_file \
                "$kofun_semantic_manifest_root" \
                "$kofun_semantic_manifest_root/$kofun_semantic_source_path" \
                "source $kofun_semantic_source_path"
        ) || exit 1
        printf '%s\t%s\t%s\n' source "$kofun_semantic_source_path" \
            "$kofun_semantic_source_digest"
    done || return 1

    for kofun_semantic_member_spec in \
        'producer-main|semantic-producer-main.o|bootstrap/stage2/semantic_producer.c|main' \
        'producer-library|semantic-producer-library.o|bootstrap/stage2/semantic_producer.c|library' \
        'semantic-events|semantic-events.o|bootstrap/stage2/semantic_events.c|events' \
        'sha256|sha256.o|bootstrap/stage2/sha256.c|sha256'
    do
        kofun_semantic_old_ifs=$IFS
        IFS='|'
        set -- $kofun_semantic_member_spec
        IFS=$kofun_semantic_old_ifs
        kofun_semantic_member_role=$1
        kofun_semantic_member_path=$2
        kofun_semantic_member_source=$3
        kofun_semantic_member_profile=$4
        kofun_semantic_member_source_digest=$(
            kofun_stage2_semantic_digest_file \
                "$kofun_semantic_manifest_root" \
                "$kofun_semantic_manifest_root/$kofun_semantic_member_source" \
                "source $kofun_semantic_member_source"
        ) || return 1
        kofun_semantic_member_digest=$(
            kofun_stage2_semantic_digest_file \
                "$kofun_semantic_manifest_root" \
                "$kofun_semantic_manifest_dir/$kofun_semantic_member_path" \
                "bundle member $kofun_semantic_member_path"
        ) || return 1
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            member "$kofun_semantic_member_role" \
            "$kofun_semantic_member_path" \
            "$kofun_semantic_member_source" \
            "$kofun_semantic_member_source_digest" \
            "$kofun_semantic_member_digest" \
            "$kofun_semantic_member_profile"
    done

    kofun_semantic_marker_digest=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_semantic_manifest_root" \
            "$kofun_semantic_manifest_dir/complete-v1" \
            'bundle marker complete-v1'
    ) || return 1
    printf '%s\t%s\t%s\n' marker complete-v1 \
        "$kofun_semantic_marker_digest"
}

# Derive the executable identity from the exact relevant input subset, output
# kind, complete fixed link profile, and resolved compiler.  KIF-only source
# bytes are included, so an equal-mtime edit cannot reuse an older executable.
kofun_stage2_semantic_executable_identity() {
    kofun_semantic_link_root=$1
    kofun_semantic_link_kind=$2
    shift 2
    kofun_stage2_semantic_compiler_identity \
        "$kofun_semantic_link_root" || return 1
    case $kofun_semantic_link_kind in
        events)
            test "$#" -eq 3 || {
                kofun_stage2_semantic_object_fail \
                    'events executable identity requires three object inputs'
                return 1
            }
            kofun_semantic_link_profile='-std=c11|-O2|-Wall|-Wextra|-Werror|-pedantic|-Ibootstrap/stage2|semantic-producer-main.o|semantic-events.o|sha256.o|-o|kofun-stage2-semantic-events'
            kofun_semantic_link_roles='producer-main semantic-events sha256'
            ;;
        kif)
            test "$#" -eq 3 || {
                kofun_stage2_semantic_object_fail \
                    'KIF executable identity requires three object inputs'
                return 1
            }
            kofun_semantic_link_profile='-std=c11|-O2|-Wall|-Wextra|-Werror|-pedantic|-DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY|-Ibootstrap/stage2|stage2_kif_producer.c|semantic-producer-library.o|semantic-events.o|kif_v1.c|sha256.o|-o|kofun-stage2-kif'
            kofun_semantic_link_roles='producer-library semantic-events sha256'
            ;;
        *)
            kofun_stage2_semantic_object_fail \
                "unknown semantic executable identity kind: $kofun_semantic_link_kind"
            return 1
            ;;
    esac

    # Dynamic fields are always printf data, never part of a format string or
    # a %b escape program.  Compiler paths may legally contain backslashes;
    # only the framing delimiters (tab/newline) were rejected above.
    kofun_semantic_link_material=$(printf \
        'schema\t%s\nkind\t%s\ncompiler-path\t%s\ncompiler-sha256\t%s\nprofile\t%s' \
        kofun.stage2-semantic-executable/v1 \
        "$kofun_semantic_link_kind" \
        "$KOFUN_STAGE2_SEMANTIC_COMPILER_PATH" \
        "$KOFUN_STAGE2_SEMANTIC_COMPILER_SHA256" \
        "$kofun_semantic_link_profile") || return 1
    kofun_semantic_link_material="$kofun_semantic_link_material
"
    for kofun_semantic_link_role in $kofun_semantic_link_roles; do
        kofun_semantic_link_input=$1
        shift
        kofun_semantic_link_digest=$(
            kofun_stage2_semantic_digest_file \
                "$kofun_semantic_link_root" "$kofun_semantic_link_input" \
                "semantic executable input $kofun_semantic_link_role"
        ) || return 1
        kofun_semantic_link_record=$(printf 'input\t%s\t%s' \
            "$kofun_semantic_link_role" "$kofun_semantic_link_digest") ||
            return 1
        kofun_semantic_link_material="$kofun_semantic_link_material$kofun_semantic_link_record
"
    done
    if test "$kofun_semantic_link_kind" = kif; then
        for kofun_semantic_link_source in $(
            kofun_stage2_semantic_kif_source_paths
        ); do
            kofun_semantic_link_digest=$(
                kofun_stage2_semantic_digest_file \
                    "$kofun_semantic_link_root" \
                    "$kofun_semantic_link_root/$kofun_semantic_link_source" \
                    "semantic executable source $kofun_semantic_link_source"
            ) || return 1
            kofun_semantic_link_record=$(printf 'source\t%s\t%s' \
                "$kofun_semantic_link_source" \
                "$kofun_semantic_link_digest") || return 1
            kofun_semantic_link_material="$kofun_semantic_link_material$kofun_semantic_link_record
"
        done
    fi
    kofun_semantic_link_identity_output=$(
        printf '%s' "$kofun_semantic_link_material" |
            "$kofun_semantic_link_root/bin/kofun-digest"
    ) || {
        kofun_stage2_semantic_object_fail \
            'cannot derive semantic executable identity'
        return 1
    }
    KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID=${kofun_semantic_link_identity_output%% *}
    case $KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID in
        *[!0-9a-f]*|'')
            kofun_stage2_semantic_object_fail \
                'invalid semantic executable identity'
            return 1
            ;;
    esac
    test "${#KOFUN_STAGE2_SEMANTIC_EXECUTABLE_ID}" -eq 64 || {
        kofun_stage2_semantic_object_fail \
            'invalid semantic executable identity'
        return 1
    }
}

# kofun_stage2_semantic_objects_validate ROOT OBJECT_DIR
#
# On success KOFUN_STAGE2_SEMANTIC_OBJECT_ID covers the exact canonical
# provenance manifest, profile marker, and four object bytes.  Validation
# recomputes the manifest from the current source closure/compiler/profile;
# mtimes are deliberately absent from both validation and identity.
kofun_stage2_semantic_objects_validate() {
    kofun_semantic_object_root=$1
    kofun_semantic_object_dir=$2
    KOFUN_STAGE2_SEMANTIC_OBJECT_ID=

    test -n "$kofun_semantic_object_dir" ||
        kofun_stage2_semantic_object_fail \
            'KOFUN_STAGE2_SEMANTIC_OBJECT_DIR is set but empty' || return 1
    if test -L "$kofun_semantic_object_dir" ||
       test ! -d "$kofun_semantic_object_dir"
    then
        kofun_stage2_semantic_object_fail \
            "object bundle is not a directory: $kofun_semantic_object_dir"
        return 1
    fi

    kofun_semantic_object_mode=$(kofun_stage2_semantic_mode \
        "$kofun_semantic_object_dir") || {
        kofun_stage2_semantic_object_fail \
            "cannot inspect object bundle mode: $kofun_semantic_object_dir"
        return 1
    }
    case $kofun_semantic_object_mode in
        dr-xr-xr-x*) ;;
        *w*)
            kofun_stage2_semantic_object_fail \
                "object bundle directory is mutable: $kofun_semantic_object_dir (mode must be 0555)"
            return 1
            ;;
        *)
            kofun_stage2_semantic_object_fail \
                "object bundle directory mode must be 0555: $kofun_semantic_object_dir"
            return 1
            ;;
    esac

    for kofun_semantic_object_name in \
        semantic-producer-main.o \
        semantic-producer-library.o \
        semantic-events.o \
        sha256.o \
        complete-v1 \
        manifest-v1.tsv
    do
        kofun_semantic_object_path="$kofun_semantic_object_dir/$kofun_semantic_object_name"
        if test -L "$kofun_semantic_object_path"; then
            kofun_stage2_semantic_object_fail \
                "bundle member is not a regular file: $kofun_semantic_object_name"
            return 1
        fi
        if test ! -e "$kofun_semantic_object_path"; then
            kofun_stage2_semantic_object_fail \
                "bundle member is missing: $kofun_semantic_object_name"
            return 1
        fi
        if test ! -f "$kofun_semantic_object_path"; then
            kofun_stage2_semantic_object_fail \
                "bundle member is not a regular file: $kofun_semantic_object_name"
            return 1
        fi
        kofun_semantic_object_mode=$(kofun_stage2_semantic_mode \
            "$kofun_semantic_object_path") || {
            kofun_stage2_semantic_object_fail \
                "cannot inspect bundle member mode: $kofun_semantic_object_name"
            return 1
        }
        case $kofun_semantic_object_mode in
            -r--r--r--*) ;;
            *w*)
                kofun_stage2_semantic_object_fail \
                    "bundle member is mutable: $kofun_semantic_object_name (mode must be 0444)"
                return 1
                ;;
            *)
                kofun_stage2_semantic_object_fail \
                    "bundle member is not readable: $kofun_semantic_object_name (mode must be 0444)"
                return 1
                ;;
        esac
    done
    kofun_semantic_expected_marker_output=$(
        printf '%s\n' 'kofun.stage2-semantic-objects/v1' |
            "$kofun_semantic_object_root/bin/kofun-digest"
    ) || return 1
    kofun_semantic_expected_marker=${kofun_semantic_expected_marker_output%% *}
    kofun_semantic_actual_marker=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_semantic_object_root" \
            "$kofun_semantic_object_dir/complete-v1" \
            'bundle marker complete-v1'
    ) || return 1
    test "$kofun_semantic_actual_marker" = \
        "$kofun_semantic_expected_marker" || {
        kofun_stage2_semantic_object_fail \
            'bundle member has the wrong profile marker: complete-v1'
        return 1
    }

    kofun_semantic_expected_manifest=$(
        kofun_stage2_semantic_manifest_write \
            "$kofun_semantic_object_root" "$kofun_semantic_object_dir"
    ) || return 1
    kofun_semantic_expected_manifest_output=$(
        printf '%s\n' "$kofun_semantic_expected_manifest" |
            "$kofun_semantic_object_root/bin/kofun-digest"
    ) || return 1
    kofun_semantic_expected_manifest_digest=${kofun_semantic_expected_manifest_output%% *}
    kofun_semantic_actual_manifest_digest=$(
        kofun_stage2_semantic_digest_file \
            "$kofun_semantic_object_root" \
            "$kofun_semantic_object_dir/manifest-v1.tsv" \
            'bundle provenance manifest-v1.tsv'
    ) || return 1
    test "$kofun_semantic_actual_manifest_digest" = \
        "$kofun_semantic_expected_manifest_digest" || {
        kofun_stage2_semantic_object_fail \
            'bundle provenance manifest does not match current sources, compiler, members, roles, and profiles'
        return 1
    }

    # The executable key covers the canonical manifest bytes as well as every
    # published member.  This is content provenance, never mtime equivalence.
    kofun_semantic_identity_material="${kofun_semantic_actual_manifest_digest}  manifest-v1.tsv
"
    for kofun_semantic_object_name in \
        semantic-producer-main.o \
        semantic-producer-library.o \
        semantic-events.o \
        sha256.o \
        complete-v1
    do
        kofun_semantic_digest=$(
            kofun_stage2_semantic_digest_file \
                "$kofun_semantic_object_root" \
                "$kofun_semantic_object_dir/$kofun_semantic_object_name" \
                "bundle member $kofun_semantic_object_name"
        ) || return 1
        kofun_semantic_identity_material="${kofun_semantic_identity_material}${kofun_semantic_digest}  ${kofun_semantic_object_name}
"
    done
    kofun_semantic_identity_output=$(
        printf '%s' "$kofun_semantic_identity_material" |
            "$kofun_semantic_object_root/bin/kofun-digest"
    ) || {
        kofun_stage2_semantic_object_fail \
            'cannot derive object bundle identity'
        return 1
    }
    KOFUN_STAGE2_SEMANTIC_OBJECT_ID=${kofun_semantic_identity_output%% *}
    case $KOFUN_STAGE2_SEMANTIC_OBJECT_ID in
        *[!0-9a-f]*|'')
            kofun_stage2_semantic_object_fail \
                'invalid object bundle identity'
            return 1
            ;;
    esac
    test "${#KOFUN_STAGE2_SEMANTIC_OBJECT_ID}" -eq 64 || {
        kofun_stage2_semantic_object_fail \
            'invalid object bundle identity'
        return 1
    }
}

# kofun_stage2_semantic_inputs ROOT main|library
#
# Sets three separately quoted input paths.  When the bundle variable is
# unset they are the original source files, preserving every standalone gate.
kofun_stage2_semantic_inputs() {
    kofun_semantic_root=$1
    kofun_semantic_profile=$2

    case $kofun_semantic_profile in
        main|library) ;;
        *)
            kofun_stage2_semantic_object_fail \
                "unknown semantic producer profile: $kofun_semantic_profile"
            return 1
            ;;
    esac

    if test "${KOFUN_STAGE2_SEMANTIC_OBJECT_DIR+x}" = x; then
        kofun_stage2_semantic_objects_validate \
            "$kofun_semantic_root" \
            "$KOFUN_STAGE2_SEMANTIC_OBJECT_DIR" || return 1
        KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT="$KOFUN_STAGE2_SEMANTIC_OBJECT_DIR/semantic-producer-$kofun_semantic_profile.o"
        KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT="$KOFUN_STAGE2_SEMANTIC_OBJECT_DIR/semantic-events.o"
        KOFUN_STAGE2_SEMANTIC_SHA256_INPUT="$KOFUN_STAGE2_SEMANTIC_OBJECT_DIR/sha256.o"
        return 0
    fi

    KOFUN_STAGE2_SEMANTIC_OBJECT_ID=
    KOFUN_STAGE2_SEMANTIC_PRODUCER_INPUT="$kofun_semantic_root/bootstrap/stage2/semantic_producer.c"
    KOFUN_STAGE2_SEMANTIC_EVENTS_INPUT="$kofun_semantic_root/bootstrap/stage2/semantic_events.c"
    KOFUN_STAGE2_SEMANTIC_SHA256_INPUT="$kofun_semantic_root/bootstrap/stage2/sha256.c"
}

# kofun_stage2_semantic_objects_build ROOT OBJECT_DIR
#
# Builds in a sibling temporary directory.  chmod completes the immutable
# bundle before one rename publishes it, so parallel gates can never observe a
# partial object set.
kofun_stage2_semantic_objects_build() {
    (
        set -eu

        kofun_semantic_build_root=$1
        kofun_semantic_build_out=$2
        kofun_semantic_build_cc=${CC:-cc}
        kofun_semantic_build_parent=$(dirname -- "$kofun_semantic_build_out")
        kofun_semantic_build_base=$(basename -- "$kofun_semantic_build_out")

        command -v "$kofun_semantic_build_cc" >/dev/null 2>&1 || {
            kofun_stage2_semantic_object_fail \
                'a C11 compiler is required; set CC to its executable'
            exit 1
        }
        test ! -e "$kofun_semantic_build_out" || {
            kofun_stage2_semantic_object_fail \
                "refusing to replace an existing object bundle: $kofun_semantic_build_out"
            exit 1
        }
        mkdir -p "$kofun_semantic_build_parent"
        kofun_semantic_build_tmp=$(mktemp -d \
            "$kofun_semantic_build_parent/.$kofun_semantic_build_base.XXXXXX")
        cleanup_semantic_build() {
            if test -n "${kofun_semantic_build_tmp:-}"; then
                kofun_stage2_owned_tree_remove \
                    "$kofun_semantic_build_tmp" 2>/dev/null || true
            fi
        }
        trap cleanup_semantic_build 0
        trap 'exit 129' 1
        trap 'exit 130' 2
        trap 'exit 143' 15

        "$kofun_semantic_build_cc" \
            -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
            -I"$kofun_semantic_build_root/bootstrap/stage2" \
            -c "$kofun_semantic_build_root/bootstrap/stage2/semantic_producer.c" \
            -o "$kofun_semantic_build_tmp/semantic-producer-main.o"
        "$kofun_semantic_build_cc" \
            -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
            -DKOFUN_STAGE2_SEMANTIC_PRODUCER_LIBRARY \
            -I"$kofun_semantic_build_root/bootstrap/stage2" \
            -c "$kofun_semantic_build_root/bootstrap/stage2/semantic_producer.c" \
            -o "$kofun_semantic_build_tmp/semantic-producer-library.o"
        "$kofun_semantic_build_cc" \
            -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
            -I"$kofun_semantic_build_root/bootstrap/stage2" \
            -c "$kofun_semantic_build_root/bootstrap/stage2/semantic_events.c" \
            -o "$kofun_semantic_build_tmp/semantic-events.o"
        "$kofun_semantic_build_cc" \
            -std=c11 -O2 -g -Wall -Wextra -Werror -pedantic \
            -I"$kofun_semantic_build_root/bootstrap/stage2" \
            -c "$kofun_semantic_build_root/bootstrap/stage2/sha256.c" \
            -o "$kofun_semantic_build_tmp/sha256.o"
        printf '%s\n' 'kofun.stage2-semantic-objects/v1' \
            >"$kofun_semantic_build_tmp/complete-v1"
        kofun_stage2_semantic_manifest_write \
            "$kofun_semantic_build_root" "$kofun_semantic_build_tmp" \
            >"$kofun_semantic_build_tmp/manifest-v1.tsv"

        chmod 0444 "$kofun_semantic_build_tmp"/*
        chmod 0555 "$kofun_semantic_build_tmp"
        mv "$kofun_semantic_build_tmp" "$kofun_semantic_build_out"
        kofun_semantic_build_tmp=
        trap - 0 1 2 15
    )
}
