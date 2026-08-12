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

## Three profile limits shaped this, not preference

**The corpus runs in four processes.** The bounded Text arena is a whole-run
4096-byte budget that is never reclaimed (#1359), and validating four SHA-256
digests costs 256 bytes of one-byte slices per report, so one program cannot
construct every case. The groups are that split, and the gate's sweep driver is
generated for the same reason.

**No `main` in `model.kofun`, and `run_group` names every corpus function.** A
declared-but-uncalled function fails the build at `cc` with
`-Werror=unused-function` (#1358), so a driver that used part of the model
would not compile.

**No typed-sidecar assertion.** On a program this size the projector prints
`ok:`, writes `ETS04`, and exits 3 without producing a file (#1360). The
assertion belongs here and returns when that is fixed.

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

`compare_reports` takes two validated reports and a caller threshold and
returns `Stage2BenchmarkComparisonOutcome(status_tag, result_tag, change_bps,
threshold_bps)` — a flat four-field carrier, not a `Result` or a
payload-bearing ADT, so a caller reads one shape whatever happened. A refusal
carries its status and three zeros; there is no partial answer to read.

Groups 4–6 run **the decision's own comparison vectors**, by name and with the
vector's own arguments. `spec/benchmark-report-v1/vectors/comparison.json` is
the boundary set #1310 froze, and the oracle joins to it twice: it reads the
arguments back out of `corpus.kofun` and requires them to equal the manifest's,
and it requires every vector in the manifest to have a case here. A boundary
added upstream fails this gate rather than going unrun. The expectation itself
comes from calling `compareReports`, the same function
`spec/benchmark-report-v1/check.sh` asserts the manifest against.

Groups 7–9 are the runtime-only concerns the manifest cannot express: each of
the eight compatibility fields mismatching on its own, the threshold's two
refusals, and the precedence between them. Their expectation is the contract's
error code, like the other refusal groups.

### Arithmetic

`magnitude * 10000` is not computed. At the report integer ceiling it is 9.0e20,
which traps as R010 — so a ceiling check written after the multiplication would
never execute, because the process is already gone. The quotient is built in
four guarded long-division steps, each testing the ceiling *before* scaling,
and the exact half rounds away from zero at the end.

### What the comparison mutations are for

Five of the nine reintroduced defects are comparison defects, and every one of
them leaves all the reports in the corpus valid — so none of the groups above
can see them. The threshold's strictness, the direction tag's reading, the
overflow guard's position, one compatibility field, and which report's status a
refusal reports.

One of them had to be rewritten to mean anything. Turning the overflow guard
*always on* edits the source, runs, and proves nothing: both other cases in that
group take the zero-baseline branch before any division, so the output does not
move. Only a guard that never fires separates the two behaviours.
