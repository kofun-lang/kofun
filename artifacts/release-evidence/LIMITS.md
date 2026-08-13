# Release limits

Generated from `release/claims.json` by `task release-evidence`. Do not edit.

## Claims with no executable gate

| Claim | State | What is absent |
|---|---|---|
| `formatter-and-repl` | design | Design only. No formatter or REPL is shipped, and no gate claims one. |
| `general-native-lowering` | open | Unified types, unified control flow, and additional target profiles are absent. Only the enumerated native checkpoints are claimed. |
| `general-ownership-checking` | open | There is no general ownership or law pass. Only the narrow borrowed-`List` checkpoint is claimed. |
| `general-parser-type-checker` | open | The active compiler is not a general parser or type checker. Only the enumerated Stage 2 checkpoints are claimed. |

## Boundaries that fail outside a claim

| Claim | Kind | Evidence | Observation |
|---|---|---|---|
| `affine-resource-handle` | trap | `tests/ownership/affine-resource-handle/runtime_model.c` | A dead generation and the second of two adversarial copies both exit 1 with empty stdout and exact `EARH01: affine resource handle already consumed` stderr. |
| `arithmetic-core` | rejection | `tests/conformance/numeric/reject_slash_operator.kofun` | `/` on `Int` is refused with one diagnostic instead of being lowered. |
| `bindgen-c-stage1` | rejection | `tests/interop/bindgen-c/fuzz/corpus/partial-declaration.h` | A header whose macros expand to an unbalanced declaration is refused with the cause named and no output directory; the same holds for expansion past the declaration and captured-output bounds, and for a clang that never answers. |
| `borrowed-list-ownership` | rejection | `bootstrap/stage2/fixtures/borrowed_move_text.kofun` | `--check-ownership` refuses `E007` on the borrowed-`List[Text]` return, matching the pinned `borrowed_move_text.stderr` byte for byte. |
| `bounded-tzdb-producer` | rejection | `tests/stdlib/tzdb/tzdb.kofun` | Malformed magic, unsupported version, digest mismatch, invalid zone, truncation, trailing bytes, arithmetic overflow, oversized input, and transition-limit exhaustion are distinct closed values. |
| `c-abi-profile` | limit | `tests/conformance/capabilities.tsv` | Backends outside the host-C profile are recorded as unsupported with a stated reason. |
| `c11-function-calls` | rejection | `tests/diagnostics/stage2/e2s10_unsupported_statement.kofun` | Statements outside the lowered slice are refused with `E2S10` rather than mis-lowered. |
| `c11-list-int-values` | rejection | `tests/stage2/list-int-values/out_of_range_write.kofun` | A constant out-of-range write is refused as `E2S157` with no C artifact; the same gate proves dynamic out-of-range writes trap as `R023` before evaluating their right-hand side. |
| `checked-int64-contract` | trap | `tests/conformance/numeric/reject_slash_operator.kofun` | Ordinary operations that cannot be represented are refused or trapped rather than wrapping implicitly. |
| `cli-commands` | rejection | `tests/cli_stage2_outcomes.sh` | Non-Core sources produce a refusal outcome instead of a partial build. |
| `cli-framework` | limit | `tests/conformance/capabilities.tsv` | Targets outside Linux x86-64 are recorded as unsupported with a stated reason. |
| `compiled-visibility-interfaces` | rejection | `tests/diagnostics/visibility-api-leaks.sh` | Public-to-internal/private and internal-to-private signatures produce deterministic E2S145 diagnostics and publish neither a replacement nor a cold artifact. |
| `compiler-seed` | rejection | `bootstrap/selfhost/driver/corpus_builtin_rejects.tsv` | Each of the 15 profile builtins has one wrong-arity and one wrong-type row; all 30 expanded sources exit nonzero and write no C. The existing 31 typed, block, loop, Text, and index boundary fixtures remain in the same gate. |
| `decimal-arithmetic-v1` | limit | `tests/conformance/capabilities.tsv` | Every backend without this runtime has an explicit unsupported row, while Decimal `//` and `%` are refused before an artifact is produced. |
| `deterministic-fuzzing` | rejection | `tests/fuzz/semantic_differential.sh` | A divergence between the oracle and a backend fails the gate with the differing program. |
| `diverse-double-compilation` | rejection | `bootstrap/selfhost/check-diverse-double-compilation-refusals.sh` | A divergence between the two chains fails the gate instead of being reported as agreement. |
| `documentation-index` | rejection | `tests/docs/documentation_index_test.mjs` | Private/internal disclosure, wrong-package internal access, unvalidated KIF projections, malformed or oversized artifacts, trust regression, stale publication, unsafe destinations and races are refused without partial replacement. |
| `elf64-image-writer` | limit | `tests/conformance/capabilities.tsv` | Corpora outside the lowered profiles are recorded as unsupported with a stated reason. |
| `enum-matching` | rejection | `tests/conformance/syntax/issues_35_47/enum_payload_unsupported_field.kofun` | Enum shapes outside the slice — a non-`Int` payload, more than one payload field, or a payload arity the pattern does not match — are refused rather than silently accepted. |
| `http-framework` | limit | `tests/http/check.sh` | Requests beyond the bounded state machine are refused rather than buffered without limit. |
| `macho64-image-writer` | rejection | `bootstrap/native/check-macho64.sh` | Unknown CPUs, empty or oversized code, and bytes outside 0..255 refuse before image writing; magic, CPU, command-size, section-offset, and entry-offset mutations fail structural validation. |
| `module-aliases` | rejection | `tests/conformance/capabilities.tsv` | Public, per-name and external aliases are outside the profile and are refused. |
| `native-aarch64-function-calls` | skip | `bootstrap/native/check.sh` | Without `qemu-aarch64` the execution branch is reported as skipped, never as passed. |
| `native-constant-stack-returns` | limit | `bootstrap/native/fixtures/function_all_traps_pressure.kofun` | Calls outside return position remain ordinary calls and are bounded by the stack limit. |
| `native-int64-values` | trap | `tests/conformance/numeric/reject_slash_operator.kofun` | Values outside the representable range are refused or trapped, never wrapped. |
| `native-integer-division` | trap | `tests/conformance/functions/division_floor_signs.kofun` | Division by zero and non-representable quotients trap with a canonical per-operator `R010` diagnostic. |
| `native-list-int-core` | limit | `tests/conformance/capabilities.tsv` | Backends that do not lower `List` values are recorded as unsupported with a stated reason. |
| `native-text-returning-calls` | limit | `tests/conformance/capabilities.tsv` | Backends that do not lower `Text` values are recorded as unsupported with a stated reason. |
| `native-utf8-text-core` | limit | `tests/conformance/capabilities.tsv` | Backends that do not lower `Text` values are recorded as unsupported with a stated reason. |
| `native-x86-64-function-calls` | rejection | `tests/conformance/capabilities.tsv` | Corpora outside the Int Core profile are recorded as unsupported with a stated reason. |
| `nominal-records` | rejection | `tests/conformance/records/stage2_unsupported_field.kofun` | The production Stage 2 C11 path refuses a field type outside its Int/Bool/Text/List[Int] slice before emitting an artifact. |
| `pe32plus-image-writer` | rejection | `bootstrap/native/check-pe32plus.sh` | Unknown machines, empty or oversized code, and bytes outside 0..255 refuse before image writing; magic, machine, entry, and alignment mutations fail structural validation. |
| `public-re-exports` | limit | `tests/conformance/modules/re-exports/run.sh` | Chains and counts beyond the stated bounds are refused rather than truncated. |
| `reproducible-bootstrap` | limit | `bootstrap/stage1/SHA256SUMS` | A digest mismatch fails the gate instead of accepting the regenerated artifact. |
| `rust-crate-shim` | skip | `examples/rust-shim/check.sh` | Without Cargo the gate reports a skip rather than a pass. |
| `self-recompile` | rejection | `bootstrap/selfhost/driver/corpus_reject.kofun` | A source outside the profile is refused identically by both seeds and writes no C. |
| `selfhost-native-corpus` | limit | `bootstrap/selfhost/driver/corpus_reject.stdout` | The refusing corpus keeps its pinned output; a change in either path fails the gate. |
| `source-extension` | rejection | `Taskfile.yml` | A `.kf`, `.py`, `.pyc` or `.pyo` file, or a `pyproject.toml`, fails `repository-check`. |
| `stable-diagnostics` | rejection | `tests/diagnostics/registry.tsv` | A code without an executable owner, or an owner without a registry row, fails the gate. |
| `stage2-core-lowering` | rejection | `tests/diagnostics/stage2/e2s10_unsupported_statement.kofun` | A statement outside the Core is refused with `E2S10`. |
| `stage2-typed-sidecar` | rejection | `tests/typed-sidecar/authority-boundary.sh` | A compiler, KIF or cache consumer of the sidecar is refused by the authority-boundary gate. |
| `stdio-language-server` | limit | `tests/lsp/performance_test.js` | Exceeding a latency percentile or the resident-set growth ratio fails the gate. |
| `syscall-file-round-trip` | trap | `stdlib/tests/verify.sh` | A failing syscall surfaces its errno instead of returning a success value. |
| `syscall-stdlib-api` | limit | `tests/conformance/capabilities.tsv` | Targets outside Linux x86-64 are recorded as unsupported with a stated reason. |
| `test-skip-reporting` | skip | `tests/cli.sh` | A skipped case is reported as skipped and never folded into the pass count. |
| `wasm32-arithmetic-core` | rejection | `bootstrap/wasm/fixtures/unsupported_text.kofun` | `Text` values are refused by the wasm32 backend rather than partially lowered. |
| `wasm32-hostabi1-object-arena` | rejection | `examples/wasm_arithmetic.kofun` | A non-empty source is refused with no artifact instead of being silently compiled to the empty entry point. |
