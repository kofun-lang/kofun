#!/bin/sh
# Build `kofun digest` (#1455).
#
# The command is ordinary Kofun: the SHA-256 block extracted from
# `bootstrap/stage2/compiler.kofun` between its marker and `fn main`, then
# `bootstrap/digest/command.kofun.in`, compiled by the C11 Stage 2 backend and
# linked with the C11 compiler the bootstrap already requires.
#
# Nothing here invokes the retired `kofun-digest` wrapper. The extraction is
# `grep`/`sed`, the
# compile is Stage 2, and the link is `cc`, so the command does not build itself
# out of the tool it replaces.
#
# This file is sourced by `bin/kofun` and by the `digest-command` gate. It is
# not executable and runs nothing on its own.
#
#   kofun_digest_build ROOT OUT
#
# Leaves the command at OUT. The build directory is private to the call and the
# final `mv` is within one directory, so a concurrent cold invocation never
# execs a partially written binary.

kofun_digest_build() {
    kofun_digest_root=$1
    kofun_digest_out=$2
    kofun_digest_cc=${CC:-cc}

    command -v "$kofun_digest_cc" >/dev/null 2>&1 || {
        printf '%s\n' "digest build: a C11 compiler is required; set CC" >&2
        return 1
    }

    kofun_digest_dir=$(dirname -- "$kofun_digest_out")
    mkdir -p "$kofun_digest_dir" || return 1
    kofun_digest_work=$(mktemp -d "$kofun_digest_dir/kofun-digest.XXXXXX") || return 1
    kofun_digest_staging="$kofun_digest_out.$$"

    kofun_digest_cleanup() {
        rm -rf "$kofun_digest_work" "$kofun_digest_staging"
    }

    kofun_digest_pair="$kofun_digest_root/bootstrap/stage2/compiler.kofun"
    kofun_digest_marker=$(grep -n '^# ---* SHA-256$' "$kofun_digest_pair" | cut -d: -f1)
    kofun_digest_main=$(grep -n '^fn main() -> Int {' "$kofun_digest_pair" | cut -d: -f1)
    if test -z "$kofun_digest_marker" || test -z "$kofun_digest_main"; then
        printf '%s\n' "digest build: compiler.kofun lost its SHA-256 marker or main" >&2
        kofun_digest_cleanup
        return 1
    fi
    sed -n "${kofun_digest_marker},$((kofun_digest_main - 1))p" \
        "$kofun_digest_pair" >"$kofun_digest_work/digest.kofun" || {
        kofun_digest_cleanup
        return 1
    }
    cat "$kofun_digest_root/bootstrap/digest/command.kofun.in" \
        >>"$kofun_digest_work/digest.kofun" || {
        kofun_digest_cleanup
        return 1
    }

    . "$kofun_digest_root/bootstrap/stage2/build.sh"
    kofun_stage2_build "$kofun_digest_root" "$kofun_digest_work/kofun-stage2" || {
        kofun_digest_cleanup
        return 1
    }

    "$kofun_digest_work/kofun-stage2" --compile-outcome \
        "$kofun_digest_work/digest.kofun" \
        "$kofun_digest_work/digest.c" \
        "$kofun_digest_work/digest.ir" \
        "$kofun_digest_work/digest.tokens" \
        >"$kofun_digest_work/compile.out" 2>"$kofun_digest_work/compile.err" || {
        printf '%s\n' "digest build: Stage 2 refused the command:" >&2
        sed -n '1,5p' "$kofun_digest_work/compile.out" >&2
        sed -n '1,5p' "$kofun_digest_work/compile.err" >&2
        kofun_digest_cleanup
        return 1
    }

    "$kofun_digest_cc" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$kofun_digest_work/digest.c" -o "$kofun_digest_staging" || {
        kofun_digest_cleanup
        return 1
    }
    mv -f "$kofun_digest_staging" "$kofun_digest_out" || {
        kofun_digest_cleanup
        return 1
    }
    kofun_digest_cleanup
    return 0
}
