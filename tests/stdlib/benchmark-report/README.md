# Benchmark report certification

`task benchmark-report` composes the contract, production model, Bytes codec,
comparison, and this final source fixture on C11 Stage 2. Each component keeps
its focused task; `verify` reaches them once through the composite task.

`corpus.kofun` constructs two reports through `produce_report`, encodes each
into caller-owned Bytes, decodes those exact buffers, and compares the decoded
reports at a caller threshold of 100 basis points. The candidate halves the
baseline's raw values. The independent specification model computes the
expected improvement of 5,000 basis points with BigInt arithmetic.

The fixture observes every one of the 49 fields before and after decoding,
all 100 raw observations and flags across the 64+36 split, and every canonical
wire byte. Both documents exceed 4 KiB. An unavailable counter and an available
zero remain distinct; a decomposed Unicode parameter stays decomposed. Invalid
model and decoder outcomes have 48 neutral fields, comparison propagates their
status without a verdict, and refused/cancelled encoding preserves the complete
previous buffer or an empty destination. All observations agree with the
committed maximum vector and independent oracle at O0/O2, on repeat, and under
Clang ASan/UBSan. The codec component additionally injects every allocation
failure and exercises every prior BR001..BR012 outcome.

The strict C test entry references the three unused private Bytes helpers
emitted with that family, then calls the unchanged generated `main`. It invokes
none of those helpers and implements no report behavior. This keeps Clang's
unused-function check enabled; the codec README records why Clang is used for
sanitizers instead of GCC's optimized empty-list warning path.

This earns only the separate `benchmark-report-v1` capability: bounded
deterministic report model/codec/comparison on C11 Stage 2. The existing
`benchmark-harness` row stays specified. This path includes no filesystem
publication, runner, clocks, counters provider, generic JSON, statistical
significance, or other backend. The schema's `Bytes[65536]` carrier is used with
a report wire bound of 16,384 bytes, Text bounds of 96/128/255 UTF-8 bytes, and
integers no greater than 2^53-1.

The `benchmark-summary` witness now uses the production summary dependency
closure. Its six original eight-sample golden values, complete typed-sidecar
projection (`ReportSummary` and `List[Int]`), repeat and emitted-C observations
remain checked. The former `Samples8` sorting network and duplicate
`BenchmarkSummary` builder are removed. The full model's separate gate still
pins its located declaration-limit refusal; this small complete witness does
not claim that the whole model projects successfully. The frozen contract
vectors and model/comparison corpora remain independent oracles and regression
cases. The certification's invalid physical direction is derived through the
normative mapper and reports BR006, including comparison/encoder propagation.
