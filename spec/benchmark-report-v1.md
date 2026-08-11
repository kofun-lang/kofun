# Kofun benchmark report v1 executable profile

## Status and decision

This document is the normative executable profile selected by issue #1310 for
the accepted benchmark charter in [`docs/stdlib/benchmark.md`](../docs/stdlib/benchmark.md).
It preserves the charter's full ceiling of 100 raw samples. Reducing the public
contract to 64 is rejected because it would silently weaken an already accepted
limit; publishing a `v1-stage2-64` subset as full v1 is also rejected.

This profile is a contract and pure oracle only. It does not claim a production
Kofun model, codec, runner, clock, counter provider, filesystem authority, or
backend implementation.

## One report, one observation series

One `kofun.bench-report/v1` document describes exactly one suite/case/optional
parameter/metric/clock combination. A parameter is the only optional field in
v1. Omission means “this is not a parameterized case”; it is distinct from a
present value such as `"0"` or `""` (the latter is invalid because identities
are nonempty).

The first profile measures one duration series. `unit` is exactly `ns`, and
`clock` is one of `monotonic`, `process-cpu`, or `wall`. `direction` is either
`lower-is-better` or `higher-is-better`. Each raw sample is an uncorrected
elapsed duration for exactly `iterations_per_sample` iterations. Harness
overhead is recorded in `harness_overhead_ns` for the same batch shape and is
never silently subtracted.

Reports carry all of the following required groups in the order in the schema:

1. schema and logical identity;
2. clock, requested warmup/sampling/sample-count budgets, observed stop reasons,
   iteration counts, and harness overhead;
3. raw samples in acquisition order, one aligned outlier Boolean per sample,
   and the six deterministic summaries;
4. the closed counters `allocated_bytes`, `allocation_count`, `gc_collections`,
   `vm_peak_bytes`, and `cpu_cycles`;
5. toolchain, source, and artifact SHA-256 digests; and
6. a privacy-preserving host digest plus OS, architecture, CPU, affinity,
   frequency, and noise metadata.

All five counter fields are present. Each is either
`{"state":"available","value":N}` or `{"state":"unavailable"}`. Available
zero, available nonzero, and unavailable are three different values. No v1
counter is optional, so omission is a schema failure rather than a fourth
counter state. Affinity and frequency use the same explicit availability rule.

`allocated_bytes`, `allocation_count`, `gc_collections`, and `cpu_cycles` are
provider deltas across the complete recorded sampling phase, after warmup and
including harness work that occurs inside that phase. `vm_peak_bytes` is the
provider's process peak observed at the end of sampling, so it is metadata and
is not treated as an additive delta. The units are respectively bytes, events,
events, bytes, and cycles. A provider that cannot make exactly that statement
must emit unavailable rather than a proxy value.

The three digests identify the toolchain artifact, complete source-closure
artifact, and measured executable artifact selected by the producer. This
profile validates their SHA-256 spelling but does not traverse files or invent
a build-manifest format; the producer's build system owns the exact artifact
bytes behind each identity. Likewise `host_id_sha256` is an opaque
privacy-preserving host identity supplied by the runner, never a raw hostname
and never computed by this pure profile. OS, architecture, CPU, affinity, and
noise are exact provider Text, not parsed facts or comparison inputs;
`frequency_hz`, when available, is integer hertz.

## Bounds and invariants

All integers are JSON integers in `0..9007199254740991` so every conforming JSON
consumer can preserve them exactly. Negative values, fractions, exponents, and
values outside that range are invalid. Arithmetic used to compute summaries or
comparisons is checked; an unrepresentable result is `BR007`, never wraparound.

The exact bounds are exported by `benchmark-report-v1/contract.mjs`. The closed
JSON Schema mirrors structural and scalar/count bounds; the executable model
additionally enforces canonical wire bytes, UTF-8 byte lengths, scalar validity,
duplicate-key rejection, depth, and cross-field invariants:

The deliberate model-only rules are wire byte size and exact UTF-8 decoding,
byte rather than code-point Text limits, Unicode scalar/control policy,
canonical field order/escaping/number spelling/one-LF framing, decoded-key
duplicate detection, container depth, derived summary/outlier equality, and
budget/stop/count cross-field invariants. Everything else in the closed
structure—required/unknown fields, primitive/container types, scalar/count
bounds, enums, digests, and availability shapes—is enforced independently by
both the Schema and model.

| Dimension | Bound |
| --- | ---: |
| canonical report bytes | 16,384 |
| JSON nesting below the root value | 0..16 |
| raw samples/outlier flags | 1..100, equal lengths |
| identity Text | 1..96 UTF-8 bytes |
| host OS/architecture/CPU/affinity Text | 1..128 UTF-8 bytes |
| noise note | 0..255 UTF-8 bytes |
| warmup cap | 0..500,000,000 ns |
| sampling cap | 1..3,000,000,000 ns |
| caller threshold | 0..1,000,000 basis points |

Text is valid Unicode scalar text. Identity equality is scalar-for-scalar and
no normalization is performed: canonically decomposed Text remains distinct
and retains its original UTF-8, as required by Kofun's existing Text contract.
Identity and host fields forbid C0 controls and DEL. `noise` additionally
admits TAB, LF, and CR so observations can be recorded without inventing
another string type. Digests are exactly 64 lowercase hexadecimal digits.

`sample_count` equals the raw array length, which does not exceed the requested
`sample_cap`. A `sample-cap` stop has exactly that many samples; `time-cap` has
strictly fewer but still publishes at least one. If both boundaries are
observed after the same completed sample, `sample-cap` wins. A zero warmup cap
is paired only with `disabled` and exactly zero warmup iterations; a nonzero cap
is paired with `steady` or `time-cap` and at least one warmup iteration.

Raw order is semantic and is never rewritten. Summary calculation sorts a copy
and applies the charter's one-based nearest-rank rules. Outlier flags align by
raw index and are deterministic: with `IQR = p75 - p25`, a value is flagged
only when it is strictly outside the Tukey 1.5-IQR fences. The executable rule
avoids fractions by checking `2 * distance > 3 * IQR` with checked arithmetic;
equality is not an outlier. The report never removes the corresponding raw
observation.

## Canonical bytes

The wire is UTF-8 JSON with no BOM. It has the exact field order declared in
`contract.mjs`, no insignificant whitespace, no duplicate/unknown fields, and
exactly one trailing LF. Integers use base-ten digits with no sign on zero,
leading zero, decimal point, or exponent. JSON strings escape quote as `\"`,
reverse solidus as `\\`, and BS/FF/LF/CR/TAB with their one-letter escapes.
Other U+0000..U+001F controls use lowercase `\u00xx`; printable Unicode scalar
values, including non-ASCII values and `/`, are literal UTF-8. A reader rejects
a semantically equivalent noncanonical form; it never repairs and accepts it.

Decoder failure precedence is observable and closed: wire byte limit (BR004),
then BOM/UTF-8/JSON syntax or trailing input (BR001), then a complete decoded-key
scan in which excessive container depth (BR004) supersedes any duplicate seen
elsewhere, then duplicate keys (BR002), then schema/scalar/cross-field
validation (BR003..BR007), and only then canonical-byte mismatch (BR002). Thus
a noncanonical document with an unknown field is BR003, while a duplicate plus
excessive nesting is BR004; implementations do not return whichever error a
streaming parser happened to notice first.

The schema is
[`benchmark-report-v1/kofun.bench-report.v1.schema.json`](benchmark-report-v1/kofun.bench-report.v1.schema.json).
`benchmark-report-v1/model.mjs` is the pure bounded validator, canonical codec,
summary oracle, and comparison oracle. The positive files and the digest-pinned
negative transformations under `benchmark-report-v1/vectors/` are normative
bytes, not production serialization.

## Errors and report-byte outcome

The closed, payload-free error carrier is intentionally representable by the
current Stage 2 concrete-enum profile. A production API may attach a bounded
path/detail out of band, but the category does not change.

| Code | Meaning |
| --- | --- |
| `BR001` | invalid UTF-8, BOM, JSON syntax, or trailing data |
| `BR002` | valid data in noncanonical bytes, including duplicate keys |
| `BR003` | wrong schema, type, enum, required/unknown field, or availability shape |
| `BR004` | byte, count, Text, or exactly-representable integer limit exceeded |
| `BR005` | invalid Unicode scalar/control policy, identity, or digest |
| `BR006` | count, budget, stop, raw/flag, or summary invariant failed |
| `BR007` | checked summary/comparison arithmetic overflow |
| `BR008` | reports are not comparison-compatible |
| `BR009` | invalid caller threshold |
| `BR010` | benchmark execution failed before a successful report existed |
| `BR011` | benchmark execution was cancelled |
| `BR012` | bounded report-byte output failed |

`success(report)`, `failed(BR010 or a validation error)`, `cancelled(BR011)`,
and `output-failed(BR012)` are disjoint outcomes. Only success exposes report
bytes, after encoding and validating the complete at-most-16-KiB canonical
value. Every failure or cancellation is a typed non-success and never exposes
partial report bytes as success.

## Deterministic comparison

Comparison requires two valid reports with equal suite, case, optional
parameter presence/value, metric, unit, direction, clock, and
`iterations_per_sample`, plus a caller threshold in integer basis points.
Digests and host metadata may differ because comparing builds and hosts is the
purpose of a report. Both raw series must remain present even though v1 compares
their recomputed medians.

Let `base` and `next` be the baseline and candidate medians. A positive signed
change always means worse:

- lower-is-better: `(next - base) * 10000 / base`;
- higher-is-better: `(base - next) * 10000 / base`.

The magnitude is rounded to the nearest integer basis point, with exact halves
away from zero. `regressed` means change is strictly greater than the threshold;
`improved` means it is strictly less than the negative threshold; equality is
`equivalent`. These words express only the caller's threshold, never statistical
significance.

The closed result is one of:

- `comparable(verdict, change_bps, threshold_bps)`, where verdict is
  `improved`, `equivalent`, or `regressed`, signed `change_bps` is in
  `-9007199254740991..9007199254740991`, and the threshold is echoed exactly;
- `indeterminate(reason: zero-baseline, threshold_bps)`, with no fabricated
  change; or
- BR007, BR008, or BR009.

Budgets, sample counts, raw values, summaries, outlier flags, counters, digests,
and host metadata may differ and do not make reports incompatible. Both inputs
are validated first, so their summaries and flags still must match their own raw
series. Only the equality list at the start of this section is compatibility
identity.

The products above define the mathematical value; production must not evaluate
`difference * 10000` directly in `Int`. The bounded exact algorithm divides the
absolute difference by `base`, checks the whole quotient against
`9007199254740991 // 10000`, and then extracts four decimal quotient digits by
four repetitions of `remainder * 10`, `// base`, and `% base`. Each intermediate
`remainder * 10` fits signed Int64 because every report integer is at most
2^53-1. The final remainder rounds up exactly when it is at least
`base // 2 + base % 2`. The sign is applied last; any checked final magnitude
above the report integer ceiling is `BR007`. The pure oracle uses arbitrary
precision arithmetic to verify the same result independently.

If both medians are zero, the result is equivalent with change zero. If the
baseline is zero and the candidate is nonzero, the result is
`indeterminate/zero-baseline`; division is not attempted. Counter availability
does not affect v1 duration comparison because counters are not comparison
inputs. Comparing a counter requires a future version with its own raw series.

## Executable Stage 2 mapping and prerequisites

The full 100-sample contract uses a 64+36 split and does not require changing
RFC-0011's capacity-64 `List[Int]` ABI. Each logical sample/flag series uses two
existing list values: indices 0..63 in the first segment and 64..99 in a second
segment bounded to 36. Flags use integers 0/1 and map to JSON Booleans. A second
segment is nonempty only when the first has length 64. A noncanonical split, a
flag outside 0/1, or disagreement with `sample_count` is `BR006`.

The complete physical outcome is one 49-field flat nominal record, not a nested
record or a record-list. Its exact declaration-order names and current-profile
types are exported as `STAGE2_REPORT_FIELDS` in `contract.mjs`: four
`List[Int]` fields plus only `Int`, `Bool`, and `Text`, below the current
128-field ceiling. Schema identity and unit are implicit constants of the
nominal v1 type. Clock, direction, and stop reasons use the closed integer tags
in `STAGE2_VALUE_TAGS`. Optional parameter and available states use a Bool plus
payload; absence requires empty Text or zero Int, so there is one physical
encoding for each logical value.

`status_tag` is 0 only for a valid complete report and 1..12 for BR001..BR012.
Every nonzero outcome requires all other fields to be their neutral values
(zero, false, empty Text, or empty list), so an error/cancellation cannot carry
a partial report. `toStage2Outcome`, `fromStage2Outcome`, and
`stage2ErrorOutcome` execute every positive/error mapping. This flat tagged
outcome is the representable Stage 2 realization of the logical payload-free
error enum plus successful report; it does not require an unsupported nested
record or record-payload ADT.

The wire cannot fit in the current 255-byte `Text` carrier. #1312 therefore
consumes the shared #1315 byte-exact `Bytes` work on C11 Stage 2 with capacity
exactly 65,536 bytes, so the same implementation also satisfies the already
accepted stdlib/HTTP byte requirement. Benchmark code itself accepts at most
16,384 bytes. `Bytes` remains an RFC-0004 `Managed`, non-Copy language value;
this profile may reclaim a private three-word allocation directly only while a
bounded Stage 2 analysis proves that storage has no alias or escape. It admits
fresh locals, nonescaping read/edit borrows, proven-unique explicit take, and
fresh/proven-unique terminal return. Ordinary managed aliasing remains valid
Kofun and is refused only by this bounded backend slice before C emission until
a general managed runtime exists. Direct reclamation is an unobservable backend
storage choice, not a new `Owned Bytes` type or a language-level deterministic
cleanup promise. Arbitrary 0x00..0xff, explicit length/capacity, and no implicit
Text conversion remain required. A benchmark-only byte type or a second
16-KiB implementation is forbidden.

That shared work must not hide a general-generics dependency. The current
Stage 2 concrete-enum slice cannot carry `Bytes` inside generic
`Result[Bytes, E]`, so its bootstrap surface uses a total empty constructor and
transactional `edit Bytes` destinations with a concrete one-`Int` status enum.
Byte reads use a concrete one-`Int` outcome, while checked Bytes-to-Text uses a
flat `Int`/`Text` outcome record with empty Text on error. Because current Stage
2 Text is NUL-terminated, that conversion rejects the first embedded NUL with a
distinct status and byte offset; NUL remains valid in Bytes and is never
misclassified as malformed UTF-8 or silently truncated. The Bytes work does not
widen Text. Those monomorphic adapters live beside the accepted generic stdlib
API and preserve its semantics; they neither add a second Bytes identity nor
claim general `Result`, a Bytes-bearing record/ADT, or generic lowering.

The production encoder exposes one complete canonical Managed Bytes value only
on success. Every failure or cancellation is a typed non-success and never
exposes partial report bytes as success. This pure profile defines no
filesystem, path, publisher, temporary-file, rename, synchronization, or
durability contract. #1316 and #1317 are independent downstream consumers and
do not gate the report model, codec, comparison, or certification. After this
decision, #1312 waits only for #1311's model and the complete shared Managed
Bytes profile. The sample/model slice #1311 needs no Bytes support: its entire
flat outcome uses the already executable `Int`/`Bool`/`Text`/`List[Int]`
record slice.

Generic `stdlib/json` is not a dependency. The current module is not generated
by Stage 2, and a host serializer may serve only as the independent oracle used
by this contract gate.

## Compatibility and non-goals

The 100-sample ceiling, raw-order retention, nearest-rank summaries, explicit
unavailability, no overhead subtraction, and no successful partial report are
preserved from the accepted charter. Fixing one case/metric per document and a
closed counter set is a compatible first-profile choice because the charter did
not define a collection wire. Adding fields, counters, units, optionality, a
collection envelope, interpolation, or another comparison statistic requires a
new schema version.

No live runner, clock/counter provider, profiler, filesystem authority, compiler
lowering, backend, or capability/release promotion is implemented here.
