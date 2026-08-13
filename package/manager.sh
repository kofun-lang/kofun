#!/usr/bin/env sh
set -eu

# This is deliberately a small artifact resolver, not a source-package build
# system.  The current Kofun compiler's external-code boundary is an explicit
# C ABI library file, so v1 resolves exactly that artifact by URL and SHA-256.

umask 077

MANIFEST=${KOFUN_PACKAGE_MANIFEST:-kofun.packages.toml}
LOCKFILE=${KOFUN_PACKAGE_LOCK:-kofun.packages.lock}
PROJECT_ROOT=$(pwd -P)
REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SHA256="$REPOSITORY_ROOT/bin/kofun-sha256"

die() {
    printf '%s\n' "kofun package: $*" >&2
    exit 2
}

cache_root() {
    if test -n "${KOFUN_PACKAGE_CACHE-}"; then
        printf '%s\n' "$KOFUN_PACKAGE_CACHE"
    elif test -n "${XDG_CACHE_HOME-}"; then
        printf '%s\n' "$XDG_CACHE_HOME/kofun/packages"
    elif test -n "${HOME-}"; then
        printf '%s\n' "$HOME/.cache/kofun/packages"
    else
        die "set KOFUN_PACKAGE_CACHE, XDG_CACHE_HOME, or HOME"
    fi
}

sha256_file() {
    "$SHA256" "$1" | awk '{ print $1 }'
}

parse_manifest() {
    test -f "$1" || die "dependency manifest not found: $1"
    awk '
        function fail(message) {
            print "kofun package: " FILENAME ":" NR ": " message >"/dev/stderr"
            failed = 1
            exit 2
        }
        function value_of(line, value) {
            value = line
            sub(/^[^"]*"/, "", value)
            sub(/"[[:space:]]*$/, "", value)
            if (index(value, "\\") != 0)
                fail("backslash escapes are not supported")
            return value
        }
        function finish() {
            if (name == "")
                return
            if (source == "")
                fail("dependency " name " is missing source")
            if (kind == "")
                fail("dependency " name " is missing kind")
            if (kind != "static-library")
                fail("dependency " name " kind must be static-library")
            if (seen[name]++)
                fail("duplicate dependency " name)
            print name "\t" source "\t" kind
        }
        /^[[:space:]]*($|#)/ { next }
        /^[[:space:]]*format[[:space:]]*=[[:space:]]*1[[:space:]]*$/ {
            if (format++)
                fail("duplicate format")
            if (name != "")
                fail("format must precede dependencies")
            next
        }
        /^[[:space:]]*\[dependency\.[A-Za-z][A-Za-z0-9_-]*\][[:space:]]*$/ {
            if (!format)
                fail("format = 1 must precede dependencies")
            finish()
            name = $0
            sub(/^[[:space:]]*\[dependency\./, "", name)
            sub(/\][[:space:]]*$/, "", name)
            source = ""
            kind = ""
            next
        }
        /^[[:space:]]*source[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/ {
            if (name == "")
                fail("source must be inside a dependency section")
            if (source != "")
                fail("duplicate source")
            source = value_of($0)
            next
        }
        /^[[:space:]]*kind[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/ {
            if (name == "")
                fail("kind must be inside a dependency section")
            if (kind != "")
                fail("duplicate kind")
            kind = value_of($0)
            next
        }
        { fail("unsupported manifest syntax") }
        END {
            if (!failed) {
                if (!format)
                    fail("missing format = 1")
                finish()
            }
        }
    ' "$1"
}

parse_lockfile() {
    test -f "$1" || die "lockfile not found: $1 (run: kofun package lock)"
    awk '
        function fail(message) {
            print "kofun package: " FILENAME ":" NR ": " message >"/dev/stderr"
            failed = 1
            exit 2
        }
        function value_of(line, value) {
            value = line
            sub(/^[^"]*"/, "", value)
            sub(/"[[:space:]]*$/, "", value)
            if (index(value, "\\") != 0)
                fail("backslash escapes are not supported")
            return value
        }
        function finish() {
            if (!package)
                return
            if (name == "" || source == "" || kind == "" || hash == "")
                fail("package block is incomplete")
            if (name !~ /^[A-Za-z][A-Za-z0-9_-]*$/)
                fail("invalid package name")
            if (kind != "static-library")
                fail("package " name " kind must be static-library")
            if (length(hash) != 64 || hash ~ /[^0-9a-f]/)
                fail("package " name " has an invalid SHA-256")
            if (seen[name]++)
                fail("duplicate package " name)
            print name "\t" source "\t" kind "\t" hash
        }
        /^[[:space:]]*($|#)/ { next }
        /^[[:space:]]*format[[:space:]]*=[[:space:]]*1[[:space:]]*$/ {
            if (format++)
                fail("duplicate format")
            if (package)
                fail("format must precede packages")
            next
        }
        /^[[:space:]]*\[\[package\]\][[:space:]]*$/ {
            if (!format)
                fail("format = 1 must precede packages")
            finish()
            package = 1
            name = ""
            source = ""
            kind = ""
            hash = ""
            next
        }
        /^[[:space:]]*name[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/ {
            if (!package || name != "")
                fail("unexpected or duplicate name")
            name = value_of($0)
            next
        }
        /^[[:space:]]*source[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/ {
            if (!package || source != "")
                fail("unexpected or duplicate source")
            source = value_of($0)
            next
        }
        /^[[:space:]]*kind[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/ {
            if (!package || kind != "")
                fail("unexpected or duplicate kind")
            kind = value_of($0)
            next
        }
        /^[[:space:]]*sha256[[:space:]]*=[[:space:]]*"[0-9a-f]+"[[:space:]]*$/ {
            if (!package || hash != "")
                fail("unexpected or duplicate sha256")
            hash = value_of($0)
            next
        }
        { fail("unsupported lockfile syntax") }
        END {
            if (!failed) {
                if (!format)
                    fail("missing format = 1")
                finish()
            }
        }
    ' "$1"
}

download() {
    source=$1
    destination=$2
    case $source in
        file://*)
            path=${source#file://}
            case $path in
                /*) ;;
                *) die "file:// source must use an absolute path: $source" ;;
            esac
            test -f "$path" ||
                die "dependency artifact not found: $source"
            cp "$path" "$destination"
            ;;
        file:*)
            path=${source#file:}
            case $path in
                /*) ;;
                *) path=$PROJECT_ROOT/$path ;;
            esac
            test -f "$path" ||
                die "dependency artifact not found: $source"
            cp "$path" "$destination"
            ;;
        https://*)
            if command -v curl >/dev/null 2>&1; then
                curl --fail --location --silent --show-error \
                    --proto '=https' --output "$destination" "$source"
            elif command -v wget >/dev/null 2>&1; then
                wget --https-only --quiet -O "$destination" "$source"
            else
                die "HTTPS fetch requires curl or wget"
            fi
            ;;
        *)
            die "unsupported source (use file: or https:): $source"
            ;;
    esac
}

cache_entry() {
    printf '%s/sha256/%s\n' "$(cache_root)" "$1"
}

verify_cache_entry() {
    entry=$1
    expected=$2
    test -f "$entry" ||
        return 1
    actual=$(sha256_file "$entry")
    test "$actual" = "$expected" ||
        die "cached content hash mismatch: expected $expected, got $actual"
}

store_cache_entry() (
    source_file=$1
    expected=$2
    entry=$(cache_entry "$expected")
    directory=${entry%/*}
    mkdir -p "$directory"

    if verify_cache_entry "$entry" "$expected"; then
        return
    fi

    temporary=$(mktemp "$directory/.tmp.XXXXXX")
    trap 'rm -f "$temporary"' 0 1 2 15
    cp "$source_file" "$temporary"
    chmod 444 "$temporary"
    if ln "$temporary" "$entry" 2>/dev/null; then
        rm -f "$temporary"
    else
        rm -f "$temporary"
        verify_cache_entry "$entry" "$expected" ||
            die "could not install cache entry: $entry"
    fi
    trap - 0 1 2 15
)

workspace() {
    mktemp -d "${TMPDIR:-/tmp}/kofun-package.XXXXXX"
}

check_manifest_lock_agreement() {
    manifest_records=$1
    lock_records=$2
    lock_declarations=$3
    manifest_unsorted=$manifest_records.unsorted
    lock_unsorted=$lock_records.unsorted
    parse_manifest "$MANIFEST" >"$manifest_unsorted"
    LC_ALL=C sort "$manifest_unsorted" >"$manifest_records"
    parse_lockfile "$LOCKFILE" >"$lock_unsorted"
    LC_ALL=C sort "$lock_unsorted" >"$lock_records"
    awk -F '	' 'BEGIN { OFS = FS } { print $1, $2, $3 }' \
        "$lock_records" >"$lock_declarations"
    cmp -s "$manifest_records" "$lock_declarations" ||
        die "manifest and lockfile disagree (run: kofun package lock)"
}

lock_packages() {
    work=$(workspace)
    trap 'rm -rf "$work"' 0 1 2 15
    records=$work/manifest
    unsorted_records=$work/manifest.unsorted
    parse_manifest "$MANIFEST" >"$unsorted_records"
    LC_ALL=C sort "$unsorted_records" >"$records"

    temporary_lock=$work/lock
    printf '%s\n' 'format = 1' >"$temporary_lock"
    count=0
    while IFS='	' read -r name source kind; do
        test -n "$name" || continue
        artifact=$work/artifact
        rm -f "$artifact"
        download "$source" "$artifact"
        hash=$(sha256_file "$artifact")
        store_cache_entry "$artifact" "$hash"
        printf '\n[[package]]\n' >>"$temporary_lock"
        printf 'name = "%s"\n' "$name" >>"$temporary_lock"
        printf 'source = "%s"\n' "$source" >>"$temporary_lock"
        printf 'kind = "%s"\n' "$kind" >>"$temporary_lock"
        printf 'sha256 = "%s"\n' "$hash" >>"$temporary_lock"
        count=$((count + 1))
    done <"$records"

    lock_directory=$(dirname "$LOCKFILE")
    mkdir -p "$lock_directory"
    installed_lock=$(
        mktemp "$lock_directory/.kofun-packages-lock.XXXXXX"
    )
    cp "$temporary_lock" "$installed_lock"
    mv "$installed_lock" "$LOCKFILE"
    trap - 0 1 2 15
    rm -rf "$work"
    printf '%s\n' "locked $count package(s)"
}

resolve_packages() {
    requested=${1-}
    offline=${2-false}
    snapshot_directory=${3-}
    work=$(workspace)
    trap 'rm -rf "$work"' 0 1 2 15
    manifest_records=$work/manifest
    lock_records=$work/lock
    lock_declarations=$work/declarations
    check_manifest_lock_agreement \
        "$manifest_records" "$lock_records" "$lock_declarations"

    found=false
    count=0
    while IFS='	' read -r name source kind hash; do
        test -n "$name" || continue
        if test -n "$requested" && test "$requested" != "$name"; then
            continue
        fi
        found=true
        entry=$(cache_entry "$hash")
        if ! verify_cache_entry "$entry" "$hash"; then
            test "$offline" = false ||
                die "offline cache miss for package $name ($hash)"
            artifact=$work/artifact
            rm -f "$artifact"
            download "$source" "$artifact"
            actual=$(sha256_file "$artifact")
            test "$actual" = "$hash" ||
                die "content hash mismatch for package $name: expected $hash, got $actual"
            store_cache_entry "$artifact" "$hash"
        fi
        if test -n "$requested"; then
            test -n "$snapshot_directory" ||
                die "internal error: package snapshot directory is missing"
            test -d "$snapshot_directory" &&
                test ! -L "$snapshot_directory" ||
                die "package snapshot directory is not a private directory"
            snapshot_temporary=$(
                mktemp "$snapshot_directory/.package.XXXXXX"
            )
            trap 'rm -rf "$work"; rm -f "$snapshot_temporary"' 0 1 2 15
            cp "$entry" "$snapshot_temporary"
            snapshot_hash=$(sha256_file "$snapshot_temporary")
            test "$snapshot_hash" = "$hash" ||
                die "snapshot content hash mismatch for package $name: expected $hash, got $snapshot_hash"
            chmod 400 "$snapshot_temporary"
            snapshot=$snapshot_directory/$name-$hash.a
            mv "$snapshot_temporary" "$snapshot"
            trap 'rm -rf "$work"' 0 1 2 15
            printf '%s\n' "$snapshot"
        fi
        count=$((count + 1))
    done <"$lock_records"

    if test -n "$requested" && test "$found" = false; then
        die "package is not declared: $requested"
    fi
    trap - 0 1 2 15
    rm -rf "$work"
    RESOLVED_COUNT=$count
}

usage() {
    cat <<'EOF'
usage:
  kofun package lock
  kofun package fetch [--offline]
EOF
}

case ${1-} in
    lock)
        test "$#" -eq 1 || { usage >&2; exit 2; }
        lock_packages
        ;;
    fetch)
        case ${2-} in
            '') offline=${KOFUN_OFFLINE:-false} ;;
            --offline) test "$#" -eq 2 || { usage >&2; exit 2; }; offline=true ;;
            *) usage >&2; exit 2 ;;
        esac
        case $offline in
            true|1) offline=true ;;
            false|0|'') offline=false ;;
            *) die "KOFUN_OFFLINE must be true, false, 1, or 0" ;;
        esac
        resolve_packages "" "$offline"
        printf '%s\n' "fetched $RESOLVED_COUNT package(s)"
        ;;
    snapshot)
        test "$#" -ge 3 && test "$#" -le 4 || {
            usage >&2
            exit 2
        }
        offline=${KOFUN_OFFLINE:-false}
        if test "$#" -eq 4; then
            test "$4" = --offline || { usage >&2; exit 2; }
            offline=true
        fi
        case $offline in
            true|1) offline=true ;;
            false|0|'') offline=false ;;
            *) die "KOFUN_OFFLINE must be true, false, 1, or 0" ;;
        esac
        resolve_packages "$2" "$offline" "$3"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
