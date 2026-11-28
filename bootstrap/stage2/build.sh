#!/bin/sh

# The one place that knows how to produce a Stage 2 compiler binary. This file
# is sourced by the gates that need one. It is not a gate itself, it runs
# nothing on its own, and it is deliberately not executable.
#
# Gate scripts use this helper instead of carrying their own ordinary compile
# line. A gate that ignores KOFUN_STAGE2_COMPILER rebuilds
# bootstrap/stage2/compiler.c from scratch — roughly 4.6s of cc — even when
# the caller has already built exactly that binary. Sanitizer, analyzer,
# mutation, macro-variant, and diverse-toolchain builds stay separate because
# they prove different properties.

# kofun_stage2_build ROOT OUT
#
# Leaves a Stage 2 compiler executable at OUT, so a caller keeps referring to
# the path it chose rather than to a path this function picked. When
# KOFUN_STAGE2_COMPILER is set it is copied to OUT instead of rebuilt: the copy
# costs milliseconds, and it keeps OUT meaningful for the callers that run the
# compiler out of their own work directory. cc diagnostics stay on stderr.
kofun_stage2_build() {
    kofun_stage2_root=$1
    kofun_stage2_out=$2

    if test -n "${KOFUN_STAGE2_COMPILER:-}"; then
        cp "$KOFUN_STAGE2_COMPILER" "$kofun_stage2_out"
        return 0
    fi

    kofun_stage2_cc=${CC:-cc}
    command -v "$kofun_stage2_cc" >/dev/null 2>&1 || {
        printf '%s\n' \
            "stage2 build: a C11 compiler is required; set CC, or set KOFUN_STAGE2_COMPILER to reuse a built one" >&2
        return 1
    }

    "$kofun_stage2_cc" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$kofun_stage2_root/bootstrap/stage2/compiler.c" \
        -o "$kofun_stage2_out"
}

# kofun_seed_digest_build ROOT OUT
#
# The non-circular pre-build seed verifier (#1668, #1455). It is the C tool
# `sha256_tool.c` over `sha256.c`/`sha256.h`, compiled from its own seed unit
# rather than from `compiler.c`, so the checks in `bootstrap/stage1/check.sh`,
# `bootstrap/stage2/check.sh` and `bootstrap/selfhost/build-a1-a2.sh` can
# verify the seeds *before* any Kofun compiler exists. The Kofun `kofun digest`
# command is built from the seed those checks verify, so using it there would
# make the seed vouch for itself.
kofun_seed_digest_build() {
    kofun_seed_root=$1
    kofun_seed_out=$2
    kofun_seed_cc=${CC:-cc}

    command -v "$kofun_seed_cc" >/dev/null 2>&1 || {
        printf '%s\n' \
            "seed digest build: a C11 compiler is required; set CC" >&2
        return 1
    }

    "$kofun_seed_cc" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -I"$kofun_seed_root/bootstrap/stage2" \
        "$kofun_seed_root/bootstrap/stage2/sha256_tool.c" \
        "$kofun_seed_root/bootstrap/stage2/sha256.c" \
        -o "$kofun_seed_out"
}

# Prepare an include catalog once for the caller's compilation. The archive
# inventory is part of the acquisition; the gate checks it against Git's files.
# Both the packer and the catalog are private to the caller's work directory.
kofun_stage2_include_bundle() (
    root=$1
    work=$2
    "${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$root/bootstrap/stage2/include_bundle.c" "$root/bootstrap/stage2/sha256.c" \
        -o "$work/include-bundle" || exit 1
    if test -e "$root/.git" || test -L "$root/.git"; then
        # A changed worktree inventory cannot authorize a new target. Compare
        # each path in the staged inventory to its actual mode and stage.
        inventory=bootstrap/stage2/includes-v1.files
        git -C "$root" show ":$inventory" >"$work/index.files" || {
            printf '%s\n' 'error[E2S226]: cannot read checkout include inventory'
            exit 1
        }
        while IFS= read -r entry; do
            if ! git --literal-pathspecs -C "$root" ls-files --stage -- "$entry" |
                LC_ALL=C grep -Eq '^100(644|755) [0-9a-f]+ 0[[:space:]]'; then
                printf '%s\n' 'error[E2S226]: include target is not a tracked regular file'
                exit 1
            fi
        done <"$work/index.files"
        "$work/include-bundle" "$root" "$work/includes-v1.bundle" \
            --tracked-stdin <"$work/index.files"
    else
        "$work/include-bundle" "$root" "$work/includes-v1.bundle"
    fi
)

# Build the public digest command from its manifest-pinned source. A private
# directory beside the destination keeps a concurrent cold build atomic.
kofun_digest_build() (
    root=$1
    output=$2
    directory=$(dirname -- "$output")
    mkdir -p "$directory" || exit 1
    work=$(mktemp -d "$directory/kofun-digest.XXXXXX") || exit 1
    trap 'rm -rf "$work"' 0 1 2 15
    kofun_stage2_build "$root" "$work/kofun-stage2" || exit 1
    kofun_stage2_include_bundle "$root" "$work" || exit 1
    "$work/kofun-stage2" --include-bundle "$work/includes-v1.bundle" --compile-outcome \
        "$root/bootstrap/digest/command.kofun.in" "$work/digest.c" \
        "$work/digest.ir" "$work/digest.tokens" >"$work/out" || {
        cat "$work/out" >&2
        exit 1
    }
    "${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        "$work/digest.c" -o "$work/digest" || exit 1
    mv -f "$work/digest" "$output"
)
