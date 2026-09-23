# Benchmark report codec

`codec.kofun` implements the pure bounded `kofun.bench-report/v1` codec on
C11 Stage 2. Concatenate it with `../benchmark-report-model/model.kofun`.
`decode_report(read source: Bytes)` returns the model's complete `BenchReport`;
every refusal has its BR001–BR012 status and 48 neutral fields.
`encode_report(report, edit destination: Bytes)` returns that status as `Int`.
The destination must satisfy the shared Bytes unique-owner profile.

The parser validates the whole UTF-8/JSON document before reporting nesting,
then compares decoded keys before reading schema fields. Its stack and token
ends are bounded Bytes buffers indexed by wire offsets. It does not recurse
with input depth or accumulate temporary Text for keys. Text conversion occurs
only after Unicode scalar, byte-length, and control validation, in that order.
Required/unknown fields and cross-field invariants follow the specification's
semantic traversal; numeric BR codes do not define error priority. Encoding
checks physical mapping invariants before that logical traversal. Numeric validation
uses decimal integer arithmetic. The shipped list profile has no dynamic
append or resize: `codec_zero_segment` selects a literal length 0–64 before
filling it, and the decoder retains the required 64+36 split.

Encoding validates the complete report and derived summaries/flags, builds a
private canonical buffer, then reserves the destination's final capacity.
Reserve failure preserves all destination fields. After successful reserve,
clear and in-bounds append need no allocation. No partial prefix is exposed
on refusal. A preexisting outcome, including BR011, returns before allocation.
The codec reads no cancellation token, file, clock, or provider.

`task benchmark-report-codec` compiles the production source once and runs its
emitted C at O0 and O2, plain and under ASan/UBSan. The independent specification
oracle supplies all 49 expected fields, three canonical positives, 44
digest-pinned negatives, combined precedence cases, an 8,000-deep input, and
every sample count 1–100. The 1,978-document corpus includes the independent
review's 790 single/schema/scalar cases and 1,000 seeded paired mutations,
plus canonical available-zero frequency. A separate 1,521-case physical-model corpus
mutates every non-status field and 1,000 deterministic pairs; `fromStage2Outcome`
and `encodeReport` supply independent statuses and complete canonical bytes.
Each is exercised with both empty and pre-existing destination storage.
The three contract positives repeat the full decode/encode path 128 times in
one process. A C test seam fails every encoder/decoder allocation in a fresh
process and compares input/destination pointer, capacity, length, and all prior
bytes; all twelve preexisting error outcomes are propagated before allocation.
Empty, short, equal-length, and larger destinations are exercised. This is
codec evidence; it makes no filesystem publication or capability claim.

`CC` selects the strict ordinary C11 builds; `SANITIZER_CC` defaults to Clang
for the strict sanitizer builds. Both retain `-Wall -Wextra -Werror -pedantic`.
GCC 16.2.1's optimized sanitizer build warns about the shared model's existing
zero-length list literal inside `kofun_list_int_value`; ordinary GCC O2 and
Clang's O0/O2 sanitizer builds accept that same emitted C. The gate uses both
compiler paths without suppressing that warning or changing the shared ABI.
