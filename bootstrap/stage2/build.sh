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
