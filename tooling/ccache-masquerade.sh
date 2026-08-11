#!/bin/sh
set -eu

# Print a directory that makes `cc`, `gcc`, and `clang` resolve to ccache.
#
#     PATH="$(sh tooling/ccache-masquerade.sh):$PATH"
#
# `task verify` spends about two thirds of its wall time in `cc`, and roughly
# four fifths of that is recompiling source sets an earlier gate in the same
# run already compiled. #1202 removed the repeated builds of one file; the
# frontend bundles remain, and they are rebuilt from source in each of the
# ~15 gate scripts that needs them. A cache fixes all of those at once, which
# per-site edits cannot, because no site knows what the others already built.
#
# Why a masquerade rather than pointing CC at a launcher:
# `bootstrap/selfhost/generations-lib.sh` derives `compiler_identity` from
# `"$CC" --version`, and `bootstrap/manifest.json` records that string for the
# closure measurement. Setting `CC="ccache cc"` would also break every gate
# that invokes `"$CC"` as a single word. A masquerade keeps `CC` untouched and
# is transparent to both: ccache forwards a non-compilation invocation,
# `--version` among them, to the compiler it fronts. The caller is expected to
# verify that rather than take it on trust -- see the identity check in
# `.github/workflows/ci.yml`.
#
# The cache is a pure accelerator. ccache returns an object only for an
# identical compilation -- same preprocessed source, same flags, same compiler
# -- so it cannot change what any gate observes, including the byte-identical
# artifact comparisons in `tests/conformance/discovery/run.sh` and the
# generation digests in the selfhost chain.

fail() {
    printf '%s\n' "ccache masquerade: $*" >&2
    exit 1
}

command -v ccache >/dev/null 2>&1 ||
    fail "ccache is not installed; install it or do not source this"

ccache_binary=$(command -v ccache)
target=${KOFUN_CCACHE_BIN_DIR:-"${TMPDIR:-/tmp}/kofun-ccache-bin"}

mkdir -p "$target" || fail "cannot create $target"

# Only `cc` is fronted, and `gcc` and `clang` are deliberately left alone.
#
# The first attempt linked all three. `task verify` refused it:
#
#   FAIL: selfhost diverse double compilation: `gcc` and `clang` resolve to
#   the same binary (/usr/bin/ccache): the pair is not diverse
#
# That gate exists because a payload living in one host compiler cannot be
# caught by a chain that only ever uses that compiler, so it requires the two
# to be genuinely different binaries. Fronting both collapsed them into one
# and defeated the check -- the cache is transparent to what a compiler
# *emits*, but the gate is about which compiler ran at all, and it cannot see
# through a symlink to answer that.
#
# Leaving them alone costs almost nothing. Measured over a full serial run:
# `cc` is 1004 of the 1429 compiler invocations and 987 s of the 1075 s spent
# compiling -- 92% of it -- against 88 s for `gcc` and `clang` together.
if command -v cc >/dev/null 2>&1; then
    ln -sf "$ccache_binary" "$target/cc"
else
    fail "no cc on PATH to front"
fi

printf '%s\n' "$target"
