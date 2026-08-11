#!/bin/sh

# The one place that knows how to produce a Stage 1 compiler binary, and the
# one place that decides whether a binary is that compiler. This file is
# sourced by the gates that need one. It is not a gate itself, it runs nothing
# on its own, and it is deliberately not executable.
#
# It exists for the same reason `bootstrap/stage2/build.sh` does — one compile
# line instead of one per caller — and for a second reason that one does not
# have. A caller that wants the Stage 1 seed usually wants it *because* it is
# Stage 1: reaching Stage 1 through `bin/kofun` reaches Stage 2 first, and the
# fallback is silent. So this helper does not just produce a binary, it proves
# the binary is the seed before returning it.

# The first line the Stage 1 seed prints when it is given no arguments. Nothing
# else in this repository prints it: `bin/kofun` prints its own usage,
# `kofun-stage2` names four operands, and a copied-in wrong binary prints
# whatever it prints. Cheap to ask, and it is what turns a substituted compiler
# into a refusal here rather than into evidence somewhere else.
KOFUN_STAGE1_USAGE='usage: kofun-stage1 INPUT.kofun OUTPUT.c'

# kofun_stage1_identify PATH
#
# Succeeds when PATH is the Stage 1 seed. Diagnoses on stderr and fails
# otherwise, including when PATH is missing or not executable.
kofun_stage1_identify() {
    kofun_stage1_candidate=$1

    test -x "$kofun_stage1_candidate" || {
        printf '%s\n' \
            "stage1 build: not an executable file: $kofun_stage1_candidate" >&2
        return 1
    }

    kofun_stage1_first_line=$(
        "$kofun_stage1_candidate" 2>/dev/null | sed -n 1p
    ) || kofun_stage1_first_line=
    test "$kofun_stage1_first_line" = "$KOFUN_STAGE1_USAGE" || {
        printf '%s\n' \
            "stage1 build: $kofun_stage1_candidate is not the Stage 1 seed" >&2
        printf '%s\n' \
            "stage1 build:   expected first line: $KOFUN_STAGE1_USAGE" >&2
        printf '%s\n' \
            "stage1 build:   observed first line: $kofun_stage1_first_line" >&2
        return 1
    }
}

# kofun_stage1_build ROOT OUT
#
# Leaves a Stage 1 compiler executable at OUT, so a caller keeps referring to
# the path it chose rather than to a path this function picked. When
# KOFUN_STAGE1_COMPILER is set it is copied to OUT instead of rebuilt, and a
# value that names nothing, or names something that is not the seed, fails here
# rather than being quietly replaced by a fresh build — a stale reuse path that
# repairs itself is a stale reuse path nobody ever notices. cc diagnostics stay
# on stderr.
kofun_stage1_build() {
    kofun_stage1_root=$1
    kofun_stage1_out=$2

    if test -n "${KOFUN_STAGE1_COMPILER:-}"; then
        kofun_stage1_identify "$KOFUN_STAGE1_COMPILER" || return 1
        cp "$KOFUN_STAGE1_COMPILER" "$kofun_stage1_out" || return 1
        return 0
    fi

    kofun_stage1_cc=${CC:-cc}
    command -v "$kofun_stage1_cc" >/dev/null 2>&1 || {
        printf '%s\n' \
            "stage1 build: a C11 compiler is required; set CC, or set KOFUN_STAGE1_COMPILER to reuse a built one" >&2
        return 1
    }

    # The same line `bootstrap/stage1/check.sh` uses, `-lm` included.
    "$kofun_stage1_cc" -std=c11 -O2 -Wall -Wextra -Werror \
        "$kofun_stage1_root/bootstrap/stage1/compiler.c" -lm \
        -o "$kofun_stage1_out" || return 1

    kofun_stage1_identify "$kofun_stage1_out"
}
