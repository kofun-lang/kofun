# Deterministic benchmark-summary fixture

This is the executable summary slice tracked by
[#859](https://github.com/kofun-lang/kofun/issues/859), split from #847. It proves
the six v1 summary calculations in a small record program. The complete
production report model/codec/comparison is now gated by
[`task benchmark-report`](../benchmark-report/README.md).

The committed raw vector is deliberately unsorted:

```text
41, 7, 19, 3, 23, 11, 29, 17
```

The Kofun producer sorts it with a fixed 19-comparator network. Under the
nearest-rank rule in `docs/stdlib/benchmark.md`, the ascending vector
`3, 7, 11, 17, 19, 23, 29, 41` yields:

| field | value | evidence |
|---|---:|---|
| min | 3 | rank 1 |
| max | 41 | rank 8 |
| median | 17 | rank 4, the lower middle |
| p25 | 7 | rank 2 |
| p75 | 23 | rank 6 |
| MAD | 6 | rank 4 of sorted deviations `0, 2, 6, 6, 10, 12, 14, 24` |

`Samples8` is a compiler regression record, not the public benchmark API.
This fixture remains because its complete typed-sidecar projection is a
positive observation the full report model's declaration-limit refusal does
not replace. Its sorting network is not used by the production report path.

Run the focused gate with:

```sh
sh tests/stdlib/benchmark-summary/check.sh
```

The gate checks named golden fields, CLI/build byte equality, typed-HIR
completeness, repeat determinism, and absence of ambient time, file, network,
or randomness calls in the emitted program. `bin/kofun run` and build use the
same Stage 2 lowering; the two invocations are not independent semantics.
The production report gates instead compare with the independent specification
model and committed vectors.
