# Benchmark report model

The production realisation of
[`spec/benchmark-report-v1.md`](../../../spec/benchmark-report-v1.md) on the
executable Stage 2 C11 profile, in Kofun (#1311).

- `model.kofun` — the 49-field flat outcome, closed validation, the segmented
  summaries, and the outlier flags. It declares no `main`: it is a library.
- `corpus.kofun` — the inputs and the four groups the gate runs.
- `oracle.mjs` — the independent expectation. It computes nothing itself; it
  calls `summarize` and `outlierFlags` from the merged #1310 oracle and reads
  the sample values out of `corpus.kofun`, so the two sides cannot drift.
- `group0..3.stdout` — the goldens.

Run:

```sh
task benchmark-report-model
```

## What it proves

The Kofun model computes each summary from **two bounded segments** with a
two-way merge selector and never materialises the merged series; the oracle
computes it from one flat array with arbitrary-precision comparisons. The gate
requires the two to agree at 29 counts, chosen to cover each `n mod 4` residue
at each structural position — the bottom, the middle, both sides of the 64-value
segment boundary, and the 100-sample ceiling. `KOFUN_BENCHMARK_REPORT_MODEL_SWEEP=all`
runs every count from 1 to 100; the counts actually used are printed by the gate
rather than assumed.

The refusals have no oracle, because their expectation is the contract's error
code. Four mutations defend them: truncating the nearest rank, admitting
equality at the Tukey fence, disarming the canonical-split guard, and leaking
one Text field into a refused outcome. Each is required to change the output.

## Bounded execution and tooling

The committed corpus runs in four groups, preserving the original golden
boundaries and giving each group independent runtime state. The Text runtime
has 4,096 slots of 256 bytes; #1359 added reuse of loop temporaries. It is not
a 4,096-byte whole-process budget.

`model.kofun` declares no `main`; the corpus and gate supply the callers.
The production emitter references declared functions, so an unused fixture
helper no longer fails strict C compilation (#1358).

The full model still exceeds the typed-sidecar producer's declaration profile.
Since #1360, the gate checks the located `ETS04` refusal, exit 3, empty stdout
and absent sidecar. The small `benchmark-summary` regression separately keeps
a positive complete projection; these are different tooling observations.

## What this child does not own

Bytes, the JSON codec and its canonical wire, the filesystem publisher, the
comparison verdict, the runner, and any capability or release claim. The
control-character policy is bounded to the three controls with portable escapes
for a stated reason: the full C0/DEL set needs either byte-valued Text
inspection or the decoded escape set of #1357, and it belongs to the decoder
child that reads bytes.

The fixed `Samples8` scaffold in
[`../benchmark-summary`](../benchmark-summary) is deliberately retained. Only
#1320 may decide and perform its deletion.

## Comparison (#1313)

`compare.kofun` is the deterministic caller-threshold comparison over two
outcomes this model produced, and `compare.sh` is its gate:

```sh
task benchmark-report-comparison
```

The arithmetic is why that file is not three lines. The value is
`difference * 10000 / base`, and production must not evaluate
`difference * 10000` in `Int` — every report integer may be 2^53-1, so the
product overflows the carrier for inputs the contract admits. Production uses
#1310's decomposition instead: a whole quotient bounded *before* it is scaled,
four decimal digits extracted one at a time from a remainder that stays below
`base`, and one rounding decision at the end. The oracle computes the same
value in BigInt, and the gate requires them to agree.

Two rules the corpus is built to make observable rather than to assert:

- **An exact half rounds away from zero.** 32 → 33 is +312.5 and 32 → 31 is
  −312.5, so a model that truncated, or that rounded before applying the sign,
  disagrees on both.
- **Precedence is an order, and an order is invisible to inputs that are wrong
  in only one way.** The fixtures are wrong in two at once: an invalid baseline
  *and* an invalid threshold reports the baseline; an incompatible pair *and* an
  invalid threshold reports the threshold.

Five mutations defend it: dropping the half-rounding, admitting equality at the
threshold, removing the pre-scaling overflow bound, dropping
`iterations_per_sample` from compatibility, and swapping the threshold and
compatibility checks.

Out of scope here as well: the codec, publication, the runner, and any
capability or release claim. This child owns comparison.

### The frozen boundary vectors (#1367)

`spec/benchmark-report-v1/vectors/comparison.json` holds the thirteen
comparison boundaries #1310 froze. All of them run here, by name, against the
production comparison — and coverage is asserted **from the manifest's side**:
`oracle.mjs` refuses if a declared vector has no case, if the corpus runs a
vector the manifest does not declare, or if one runs twice.

That direction is the whole point. A corpus can be complete today and silently
incomplete the moment a boundary is added upstream, and a gate that only checks
the cases it has would stay green through it. Both halves are proved rather
than read: the gate points the oracle at a manifest carrying one extra vector
and requires the refusal to name it, and at a corpus with one case deleted and
requires the same.

The six groups above stay, because they cover precedence and compatibility,
which a value-oriented vector set does not.
