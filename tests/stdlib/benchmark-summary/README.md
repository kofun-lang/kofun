# Deterministic benchmark-summary fixture

This retains the original six-field golden from
[#859](https://github.com/kofun-lang/kofun/issues/859), split from #847. Under
[#1320](https://github.com/kofun-lang/kofun/issues/1320), its witness now calls
`summarize_segments` from the shared production report model instead of
maintaining a separate sorting network and summary builder.

The committed raw vector is deliberately unsorted:

```text
41, 7, 19, 3, 23, 11, 29, 17
```

The Kofun producer passes the vector as the first `List[Int]` segment with an
empty second segment to `summarize_segments`. Under the nearest-rank rule in
`docs/stdlib/benchmark.md`, the ascending vector
`3, 7, 11, 17, 19, 23, 29, 41` yields:

| field | value | evidence |
|---|---:|---|
| min | 3 | rank 1 |
| max | 41 | rank 8 |
| median | 17 | rank 4, the lower middle |
| p25 | 7 | rank 2 |
| p75 | 23 | rank 6 |
| MAD | 6 | rank 4 of sorted deviations `0, 2, 6, 6, 10, 12, 14, 24` |

The gate extracts `ReportSummary` and its six summary helpers directly from
[`benchmark-report-model/model.kofun`](../benchmark-report-model/model.kofun)
and appends this small caller. The checked, built, and executed program uses
the shared production implementation. Selecting only this function closure
keeps the original complete typed-HIR assertion within the current projector
limit. At `main@04003d9b`, checking the full concatenated model with
`--emit-typed-sidecar` fails with `ETS04: semantic HIR projection failed`
(#1360); this witness does not claim that projection works. Missing, duplicate,
or unterminated selected declarations fail extraction, and a new helper
dependency fails compilation until the extraction includes it. The duplicate `Samples8` and
`BenchmarkSummary` implementations have been removed. The
independent canonical
[`typical.json`](../../../spec/benchmark-report-v1/vectors/positive/typical.json)
retains this raw vector and its expected summaries. This focused gate makes no
codec, runner, provider, or publication claim.

Run the focused gate with:

```sh
sh tests/stdlib/benchmark-summary/check.sh
```

The gate checks named golden fields, reference/C11 byte equality, typed-HIR
completeness, repeat determinism, and absence of ambient time, file, network,
or randomness calls in the emitted program.
