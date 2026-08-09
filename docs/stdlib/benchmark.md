# Benchmark harness contract

## Status

This document is the accepted contract for GitHub issue
[#640](https://github.com/kofun-lang/kofun/issues/640). No public harness is
implemented: the harnesses in
[`kofun-lang/kofun-benchmarks`](https://github.com/kofun-lang/kofun-benchmarks)
are repository evidence, not a library contract. The first slice is #646 — the canonical raw-sample report,
deterministic summaries, and explicit unavailable metrics — before any live
runner or counters.

Under the standard-library charter the benchmark **API** is portable and the
`kofun bench` runner ships with the toolchain; #398 and #476 remain the
allocation/VM counter providers behind this contract and are not duplicated.

The words **must**, **must not**, and **may** are normative.

## Decision summary

A benchmark is a declared function measured by the runner, never an ad-hoc
shell timing. The API separates what users state (the workload, its
parameters, its setup) from what the harness owns (warmup, sampling, stop
rules, statistics, report identity), and every number in a report says which
clock produced it.

```kofun
bench parse_config(b: Bench) {
    let input = fixtures.large_config()      // setup: outside measurement
    b.iter(fn() => b.consume(config.parse(input)))
}
```

## Accepted decisions

### API and runner split

- The portable library defines `Bench`, `b.iter`, `b.consume`, parameterized
  cases, and the report types. The `kofun bench` runner discovers `bench`
  declarations, applies budgets, and writes reports. Assertions on
  performance do not belong in unit tests; the runner owns comparison.

### Measurement model

- Wall, process-CPU, and monotonic readings are distinct fields and can
  never be mislabeled: each sample records which clock produced it, via the
  platform-adapter monotonic clock capability.
- The harness calibrates and reports its own per-iteration overhead;
  samples are not silently corrected.
- `b.consume(value)` is the anti-elision primitive: it promises the
  optimizer the value is observed while changing no program semantics.
  Work not routed through `b.iter`/`b.consume` may legally be elided, and
  the contract says so rather than pretending otherwise.
- Warmup and sampling budgets are explicit with bounded defaults (warmup
  until steady or 500 ms cap; then up to 100 samples or 3 s, whichever
  first). Stop rules are deterministic for the same input sample stream.

### Counters

- Allocation, GC/VM, and native counters are attached when the providers
  (#398, #476) exist for the running backend; otherwise the field is the
  explicit value `unavailable` — never zero, never omitted. A report that
  says `unavailable` is honest; a report that invents a number is a bug.

### Reports

- Schema `kofun.bench-report/v1`, versioned, machine-readable, containing:
  raw samples (never only summaries), requested budgets, harness overhead,
  toolchain/source/artifact digests, host identity, and CPU
  affinity/frequency/noise notes as metadata rather than corrections.
- Summaries (min, max, median, p25, p75, MAD) are computed deterministically
  from raw samples; outliers are flagged, never dropped.
- Comparison between two reports requires both raw sample sets and a
  stated threshold; the runner never claims a significant speedup from one
  run.
- Failures and cancellation produce typed non-success results; a partial
  report is never published as success.

### Deterministic v1 summary rule

Sort the complete raw sample series in ascending order before computing a
summary. For `n` samples, v1 quantiles use the one-based nearest-rank rule:
the rank for quantile `p` is `ceil(p * n)`. There is no interpolation. Thus an
even-count median is the lower of the two middle observations. `p25`, median,
and `p75` use `p = 0.25`, `0.50`, and `0.75` respectively; `min` and `max` are
the first and last sorted observations.

MAD is the median absolute deviation from that v1 median: compute the absolute
difference between every raw observation and the median, sort those
differences, and apply the same nearest-rank median rule. Scaled integer
observations therefore produce exact integer summaries without an implicit
rounding mode. A future interpolated statistic requires a new schema version;
it must not silently change these bytes.

## Examples

Five cases, because each one is a distinct way to measure the wrong thing.

**Pure computation.** The whole workload is inside `b.iter`, and its result is
routed through `b.consume` — without that the optimizer is entitled to delete
the call, and the benchmark would report the cost of an empty loop.

```kofun
bench fib_30(b: Bench) {
    b.iter(fn() => b.consume(math.fib(30)))
}
```

**Setup outside the measured region.** Building the input is not part of the
workload. Everything before `b.iter` runs once and is not sampled.

```kofun
bench parse_config(b: Bench) {
    let input = fixtures.large_config()      // setup: outside measurement
    b.iter(fn() => b.consume(config.parse(input)))
}
```

**Allocation-heavy code.** Identical in shape, different in what the report
carries: allocation counters attach when a provider (#398, #476) exists for the
running backend. The benchmark does not ask for them and does not change if
they are absent — see the last case.

```kofun
bench build_index(b: Bench) {
    let words = fixtures.word_list()
    b.iter(fn() => b.consume(index.build(words)))
}
```

**Parameterized cases.** One declaration, one report entry per parameter, each
with its own samples. Sizes are stated rather than swept, so the same
declaration measures the same points on every run.

```kofun
bench sort_n(b: Bench) {
    for n in b.params([64, 4_096, 262_144]) {
        let data = fixtures.shuffled(n)
        b.iter(fn() => b.consume(sort.ascending(data.clone())))
    }
}
```

**An unavailable counter.** What a report says when a counter has no provider on
this backend. The field is present and explicitly `unavailable`; it is never
zero and never omitted, because a zero would read as *"no allocations"* and an
omission as *"nobody asked"*.

```json
{
  "schema": "kofun.bench-report/v1",
  "bench": "build_index",
  "samples": [412037, 409881, 411204],
  "counters": {
    "wall": { "unit": "ns", "clock": "monotonic" },
    "allocated_bytes": "unavailable"
  }
}
```

A consumer that cannot distinguish those three states cannot be trusted with a
comparison, which is why the schema makes the distinction rather than leaving it
to a convention.

## Alternatives considered

**Keep shell timing scripts.** Merits: zero new surface. Demerits: no
anti-elision, no clock discipline, no machine-readable identity — exactly
the ad-hoc state #640 exists to end. Rejected as the public story; the
harnesses in `kofun-lang/kofun-benchmarks` remain internal evidence.

**Statistical engine first (Criterion-style bootstrapping, outlier
rejection).** Merits: sophisticated confidence intervals. Demerits:
statistics computed from discarded samples cannot be audited; raw samples
plus deterministic summaries let any later tool re-derive better
statistics without re-running. Rejected for v1 — raw-first, stats later.

**Auto-tuning the host (CPU pinning, governor changes).** Merits: quieter
numbers. Demerits: requires elevated privileges and hides variance the
user's real environment has; noise belongs in metadata. Rejected.

**Merging profiler and benchmark.** Merits: one tool. Demerits: profiling
perturbs timing and has its own contract (#398/#476); the report format
links to profiles rather than embedding them. Rejected.

## Non-goals

Claiming significance from single runs, embedding a full profiler, silent
outlier rejection, privileged host tuning, and replacing workload-specific
methodology.

## Validation

| Check | Artifact | Expected result |
|---|---|---|
| Contract review | this document | API, schema, statistics, limits complete |
| Schema fixture | #646 fixed synthetic samples | byte-deterministic report and summaries |
| Live smoke | bounded pure/allocation cases | nonzero samples, explicit available counters |
| Charter matrix | `sh stdlib/check-capabilities.sh` | benchmark row cites this contract |
