#!/bin/sh
# Produce the inventory `imports_qualified` consumes, from a package root.
#
#     sh bootstrap/stage2/module-inventory.sh PACKAGE_NAME ROOT FILE...
#
# Each output line is
#
#     PACKAGE_ID|MODULE_ID|FILE_ID|module.path|logical/path.kofun|/absolute/path
#
# with the three identities derived exactly as `spec/modules/module-identity.md`
# and `spec/modules/source-file-mapping.md` specify. Nothing shipped computed
# them before this script: `module_symbols.c` parses identities and every
# conformance harness writes `1111…`/`2222…` placeholders, because there was no
# producer to call.
#
# The derivations are checked against the spec gate's own golden package and
# module ids, so this file cannot drift from the specification silently — see
# `tests/modules/inventory/check.sh`.
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIGEST="$ROOT/bin/kofun-digest"

usage() {
    printf '%s\n' \
        "usage: module-inventory.sh PACKAGE_NAME PACKAGE_ROOT FILE..." >&2
    exit 2
}

test "$#" -ge 3 || usage
package_name=$1
package_root=$(CDPATH= cd -- "$2" && pwd)
shift 2

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-inventory.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

u16be() {
    printf "$(printf '\\%03o\\%03o' $(( ($1 >> 8) & 255 )) $(( $1 & 255 )))"
}

u32be() {
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o' \
        $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) \
        $(( ($1 >> 8) & 255 )) $(( $1 & 255 )))"
}

byte_count() {
    wc -c <"$1" | tr -d '[:space:]'
}

text_byte_count() {
    printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

# sha256 over KOFUN\0 || u16be(len domain) || domain || u32be(len payload) || payload.
# The framing is what keeps two different domains from colliding on one payload.
framed_hash() {
    fh_domain=$1
    fh_payload=$2
    {
        printf 'KOFUN\000'
        u16be "$(text_byte_count "$fh_domain")"
        printf '%s' "$fh_domain"
        u32be "$(byte_count "$fh_payload")"
        cat "$fh_payload"
    } >"$work/preimage"
    "$DIGEST" "$work/preimage" | awk '{ print $1 }'
}

# The canonical PackageIdPayload. `source=workspace-root` and
# `manifest-schema=1` are the values the specification's own reference vector
# uses; a package manifest is not read here because the driver does not have one.
printf '%s\n' \
    'kofun.package-id/v1' \
    'kind=manifest' \
    "name=$package_name" \
    'version=unspecified' \
    'source=workspace-root' \
    'edition=unspecified' \
    'manifest-schema=1' >"$work/package.payload"
package_id=$(framed_hash kofun.id.package/v1 "$work/package.payload")

# The declared `module` path, which is what makes the file a module rather than
# a single-file program. A file without one is not this script's input: the
# driver refuses it as EDRV001 before reaching here.
module_path_of() {
    LC_ALL=C awk '
        {
            stripped = $0
            sub(/^[ \t]+/, "", stripped)
            if (stripped != "" && substr(stripped, 1, 1) != "#") {
                if (stripped ~ /^module[ \t]/) {
                    sub(/^module[ \t]+/, "", stripped)
                    sub(/[ \t]+$/, "", stripped)
                    print stripped
                }
                exit
            }
        }
    ' "$1"
}

for file in "$@"; do
    absolute=$(CDPATH= cd -- "$(dirname -- "$file")" && pwd)/$(basename -- "$file")
    case $absolute in
        "$package_root"/*) logical=${absolute#"$package_root"/} ;;
        *)
            printf '%s\n' \
                "module-inventory: $file is outside the package root $package_root" >&2
            exit 2
            ;;
    esac

    module_path=$(module_path_of "$absolute")
    if test -z "$module_path"; then
        printf '%s\n' "module-inventory: $file declares no module" >&2
        exit 2
    fi

    {
        printf '%s\n' 'kofun.module-id-input/v1' 'package-payload-begin'
        cat "$work/package.payload"
        printf '%s\n' 'package-payload-end' 'kind=declared' \
            "module-path=$module_path"
    } >"$work/module.payload"
    module_id=$(framed_hash kofun.id.module/v1 "$work/module.payload")

    # The logical path participates in FileId, so moving a file changes its
    # identity even when its bytes and module declaration do not — that is the
    # specification's stated intent, not an accident of this implementation.
    {
        printf '%s\n' 'kofun.file-id-input/v1' 'package-payload-begin'
        cat "$work/package.payload"
        printf '%s\n' 'package-payload-end' "logical-path=$logical" \
            'source-role=authored' 'provenance=explicit-source'
    } >"$work/file.payload"
    file_id=$(framed_hash kofun.id.file/v1 "$work/file.payload")

    printf '%s|%s|%s|%s|%s|%s\n' \
        "$package_id" "$module_id" "$file_id" \
        "$module_path" "$logical" "$absolute"
done
