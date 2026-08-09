#!/bin/sh
set -eu

LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ADAPTERS="$ROOT/tests/diagnostics/adapters.tsv"
WORK=${KOFUN_DIAGNOSTIC_REGISTRY_WORK:-"$ROOT/build/diagnostic-registry"}

rm -rf "$WORK"
mkdir -p "$WORK"

# Several adapters run a script that is also its own task, and each defaults to
# one shared work directory. Under a concurrent `task verify` the two
# copies interleave in that directory: the module-symbols pair appends to one
# module inventory until it trips `E2S55: inventory exceeds 256 modules`. Give the
# adapter copies their own directories so the two invocations cannot meet. Each
# runner already honours these overrides; the tasks keep the defaults.
#
# Runners that validate a fixed work-directory basename accept an optional
# suffix, so each override keeps that name and adds `.diagnostics` rather than
# inventing a new one.
KOFUN_ADT_FRONTEND_WORK="$WORK/adt-frontend.diagnostics"
KOFUN_RECORD_FRONTEND_WORK="$WORK/record-frontend.diagnostics"
KOFUN_GENERICS_FRONTEND_WORK="$WORK/generics-frontend.diagnostics"
KOFUN_CONST_GENERICS_FRONTEND_WORK="$WORK/const-generics-frontend.diagnostics"
KOFUN_HM_LEVELS_WORK="$ROOT/build/hm-levels.diagnostics"
KOFUN_TRAITS_FRONTEND_WORK="$WORK/traits-frontend.diagnostics"
KOFUN_ADT_EXHAUSTIVENESS_WORK="$WORK/adt-exhaustiveness.diagnostics"
KOFUN_MODULE_SYMBOLS_WORK="$WORK/module-symbols.diagnostics"
KOFUN_IMPORTS_SELECTIVE_WORK="$WORK/imports-selective.diagnostics"
KOFUN_RE_EXPORTS_WORK="$WORK/re-exports.diagnostics"
export KOFUN_ADT_FRONTEND_WORK KOFUN_RECORD_FRONTEND_WORK
export KOFUN_GENERICS_FRONTEND_WORK KOFUN_CONST_GENERICS_FRONTEND_WORK
export KOFUN_HM_LEVELS_WORK KOFUN_TRAITS_FRONTEND_WORK
export KOFUN_ADT_EXHAUSTIVENESS_WORK KOFUN_MODULE_SYMBOLS_WORK
export KOFUN_IMPORTS_SELECTIVE_WORK KOFUN_RE_EXPORTS_WORK

sh "$ROOT/tests/diagnostics/check.sh" --registry-only
: >"$WORK/observed.tsv"

while IFS='	' read -r adapter command bless report; do
    case $adapter in ''|\#*) continue ;; esac
    printf '%s\n' "RUN [diagnostic-adapter] $adapter"
    # An adapter is a full gate script that other `task verify` targets also
    # run. Give each one its own build namespace so this gate cannot race them
    # or its own siblings (#713).
    KOFUN_GATE_WORK_NAMESPACE="diagnostic-adapter/$adapter" \
        sh "$ROOT/$command"
    awk -F '\t' -v adapter="$adapter" '
        /^#/ || NF == 0 { next }
        $2 != adapter {
            printf "diagnostic registry: adapter %s reported owner %s\n",
                adapter, $2 > "/dev/stderr"
            exit 1
        }
        { print }
    ' "$ROOT/$report" >>"$WORK/observed.tsv"
done <"$ADAPTERS"

# The const-generics runner is also a top-level verify task. Pin evidence that
# this adapter consumed the exported override instead of racing the direct
# task in build/const-generics-frontend.
expected_const_generics_work="$WORK/const-generics-frontend.diagnostics"
test "$KOFUN_CONST_GENERICS_FRONTEND_WORK" = "$expected_const_generics_work" || {
    printf '%s\n' \
        'diagnostic registry: const-generics adapter work directory is not isolated' \
        >&2
    exit 1
}
test -f "$expected_const_generics_work/backends.stdout" || {
    printf '%s\n' \
        'diagnostic registry: const-generics adapter did not use its isolated work directory' \
        >&2
    exit 1
}

# The traits runner likewise has a direct top-level task. It does not derive a
# path from KOFUN_GATE_WORK_NAMESPACE, so pin the explicit override here; an
# executable produced under this path proves the adapter did not race the
# direct task in build/traits-frontend.
expected_traits_work="$WORK/traits-frontend.diagnostics"
test "$KOFUN_TRAITS_FRONTEND_WORK" = "$expected_traits_work" || {
    printf '%s\n' \
        'diagnostic registry: traits adapter work directory is not isolated' \
        >&2
    exit 1
}
test -x "$expected_traits_work/kofun-traits-sanitize" || {
    printf '%s\n' \
        'diagnostic registry: traits adapter did not use its isolated work directory' \
        >&2
    exit 1
}

KOFUN_DIAGNOSTIC_OBSERVED="$WORK/observed.tsv" \
    sh "$ROOT/tests/diagnostics/check.sh"
sh "$ROOT/tests/diagnostics/self-test.sh"
