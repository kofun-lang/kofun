#!/usr/bin/env sh
set -eu

# Invokes the regression gate in `benchmark.sh`, which enforces nothing until it
# is told which revision to compare against (#1139). The pair it needs — a
# baseline revision and the improvement percentages claimed against it — is not
# invented here: `results.json` already records both, as `baseline_revision` and
# `budgets.declared_improvements`. The recorded measurement is the pin, so the
# gate and the published numbers cannot describe different comparisons.
#
# Why a named revision and not committed numbers: the harness builds the
# baseline revision's producer and measures it in the same run, on the same
# machine, interleaving rounds so drift lands on every variant. Comparing
# against numbers recorded elsewhere would measure the hardware instead — the
# recorded ones came from a laptop, and CI runners are neither that laptop nor
# each other. Comparing against a *moving* baseline such as HEAD~1 would be
# worse than either: the 5% per-comparison allowance would let performance decay
# without limit while every run stayed green. The pin moves when someone records
# a new measurement, which is the point at which a human looked at the numbers.
#
# Two modes, because the enforcing run costs twice a normal build and needs
# history that CI's default shallow checkout does not have:
#
#   structure  validates the pin only — shape, and that every claim names a
#              workload the harness measures. Cheap, offline, no benchmark; this
#              is the mode `task verify` runs, and it is what catches a pin that
#              has rotted into naming a workload that no longer exists.
#   measure    the real gate. Needs the baseline revision in the object store,
#              so its lane checks out full history.

MODE=${1:-measure}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BENCH="$ROOT/benchmarks/native-functions"
RESULTS="$BENCH/results.json"

case "$MODE" in
structure | measure) ;;
*)
    printf '%s\n' "native function benchmark: unknown mode $MODE" >&2
    exit 2
    ;;
esac

test -f "$RESULTS" || {
    printf '%s\n' "native function benchmark: $RESULTS is missing" >&2
    exit 2
}

# One node pass reads the pin and checks it against the workloads benchmark.sh
# actually measures, so a claim can never name something unmeasured.
PIN=$(
    KOFUN_BENCH_RESULTS="$RESULTS" KOFUN_BENCH_SCRIPT="$BENCH/benchmark.sh" \
        node --input-type=module -e '
import { readFileSync } from "node:fs";

const results = JSON.parse(readFileSync(process.env.KOFUN_BENCH_RESULTS, "utf8"));
const script = readFileSync(process.env.KOFUN_BENCH_SCRIPT, "utf8");

const fail = (message) => {
    process.stderr.write(`native function benchmark: ${message}\n`);
    process.exit(2);
};

const revision = results.baseline_revision;
if (typeof revision !== "string" || !/^[0-9a-f]{40}$/.test(revision)) {
    fail("results.json baseline_revision is not a full 40-character revision");
}

const declared = results.budgets?.declared_improvements;
if (declared === null || typeof declared !== "object" || Array.isArray(declared)) {
    fail("results.json budgets.declared_improvements is not an object");
}

const claims = Object.entries(declared);
if (claims.length === 0) {
    fail("results.json declares no improvement to hold the baseline to");
}

// The workload list benchmark.sh iterates, read from the script itself rather
// than duplicated here — a copy would drift and stop catching the rot.
const workloadBlock = script.match(/^WORKLOADS="([^"]*)"/m);
if (!workloadBlock) fail("benchmark.sh no longer declares WORKLOADS");
const workloads = new Set(workloadBlock[1].split(/\s+/).filter(Boolean));

for (const [stem, percent] of claims) {
    if (!workloads.has(stem)) {
        fail(`declared improvement names ${stem}, which benchmark.sh does not measure`);
    }
    if (typeof percent !== "number" || !Number.isFinite(percent) || percent <= 0) {
        fail(`declared improvement for ${stem} is not a positive number`);
    }
}

const improve = claims.map(([stem, percent]) => `${stem}:${percent}`).join(" ");
process.stdout.write(`${revision}\n${improve}\n`);
'
)

BASELINE=$(printf '%s\n' "$PIN" | sed -n '1p')
IMPROVE=$(printf '%s\n' "$PIN" | sed -n '2p')

printf '%s\n' \
    "baseline_revision=$BASELINE" \
    "declared_improvements=$IMPROVE"

test "$MODE" = measure || {
    printf '%s\n' "pin=valid (structure only; run \`task native-functions-benchmark\` to enforce it)"
    exit 0
}

# A shallow clone reports the revision as missing rather than as a regression.
# Saying which it is keeps a CI misconfiguration from reading as a real failure.
git -C "$ROOT" cat-file -e "$BASELINE^{commit}" 2>/dev/null || {
    printf '%s\n' \
        "native function benchmark: baseline revision $BASELINE is not in this checkout" \
        "  the enforcing lane needs full history (actions/checkout fetch-depth: 0)" \
        >&2
    exit 2
}

BASELINE="$BASELINE" IMPROVE="$IMPROVE" exec sh "$BENCH/benchmark.sh"
