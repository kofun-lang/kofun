# Examples

[`docs/REPOSITORY_GUIDE.md`](../docs/REPOSITORY_GUIDE.md) says an example is
owned by "the example plus its nearest check". Eleven of these files had no check
of any kind, so nothing but the Tree-sitter corpus gate — which proves only
that a file *parses* — stood between them and silent rot.

This table is that missing binding, and `sh examples/check.sh` (`task
examples`) enforces it. Every `.kofun` file under `examples/` appears here
exactly once and every row names a file that exists, so an example cannot be
added without declaring how it is checked.

## Status vocabulary

| Status | Meaning | What the gate does |
|---|---|---|
| `owned` | another subsystem's check already runs it | asserts the named check exists and still names the example |
| `runs` | compiles and runs on the Stage 2 Core path today | builds it, runs it, and compares stdout to the committed `.expected` file |
| `illustrative` | written in accepted syntax that the Stage 2 Core slice does not lower yet | asserts `bin/kofun check` still refuses it with the stated code |

`illustrative` is a falsifiable claim, not a shrug. The gate fails if such a
file starts checking cleanly, which is the signal to move it to `runs` and give
it an expected output. None of these files uses retired syntax — every
construct in them traces to a current entry in
[`docs/DESIGN_DECISIONS.md`](../docs/DESIGN_DECISIONS.md), and `task
tree-sitter` parses the twenty files outside `stdlib/` without an `ERROR` or
`MISSING` node.

The `stdlib/` subdirectory holds the executable standard-library samples:
for every stdlib module, `stdlib/<module>_sample.kofun` runs today with a
committed golden, and `stdlib/<module>_sample_test.kofun` is its kotest unit
suite (see [`tooling/kotest/README.md`](../tooling/kotest/README.md)), run by
`kofun unittest` and owned by `tests/stdlib/kotest/check.sh` (`task kotest`).

## Examples

| Example | Status | Evidence |
|---|---|---|
| `api_server.kofun` | owned | `tests/http/check.sh` |
| `broken_list_monad.kofun` | illustrative | `E2S02` |
| `cli_tool.kofun` | owned | `framework/cli/check.sh` |
| `coding_interview.kofun` | illustrative | `E2S10` |
| `fibonacci_native.kofun` | owned | `bootstrap/native/check.sh` |
| `hello.kofun` | runs | `hello.expected` |
| `lambdas.kofun` | owned | `tests/conformance/syntax/issues_35_47/run.sh` |
| `lawful_list_monad.kofun` | illustrative | `E2S02` |
| `native_answer.kofun` | runs | `native_answer.expected` |
| `null_and_else_if.kofun` | illustrative | `E2S12` |
| `ownership.kofun` | illustrative | `E2S15` |
| `pipeline.kofun` | illustrative | `E2S16` |
| `project/src/bench.kofun` | runs | `project/src/bench.expected` |
| `project/src/main.kofun` | owned | `spec/package-roots/check.sh` |
| `proven_optional_bool_monad.kofun` | illustrative | `E2S02` |
| `rust-shim/graphemes.kofun` | owned | `examples/rust-shim/check.sh` |
| `science.kofun` | illustrative | `E2S16` |
| `stdlib/array_sample.kofun` | runs | `stdlib/array_sample.expected` |
| `stdlib/array_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/binary_heap_sample.kofun` | runs | `stdlib/binary_heap_sample.expected` |
| `stdlib/binary_heap_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/clock_sample.kofun` | runs | `stdlib/clock_sample.expected` |
| `stdlib/clock_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/csv_sample.kofun` | runs | `stdlib/csv_sample.expected` |
| `stdlib/csv_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/date_time_sample.kofun` | runs | `stdlib/date_time_sample.expected` |
| `stdlib/date_time_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/decimal_sample.kofun` | runs | `stdlib/decimal_sample.expected` |
| `stdlib/decimal_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/json_sample.kofun` | runs | `stdlib/json_sample.expected` |
| `stdlib/json_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/list_sample.kofun` | runs | `stdlib/list_sample.expected` |
| `stdlib/list_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/logging_sample.kofun` | runs | `stdlib/logging_sample.expected` |
| `stdlib/logging_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/map_sample.kofun` | runs | `stdlib/map_sample.expected` |
| `stdlib/map_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/random_sample.kofun` | runs | `stdlib/random_sample.expected` |
| `stdlib/random_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/regex_sample.kofun` | runs | `stdlib/regex_sample.expected` |
| `stdlib/regex_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/set_sample.kofun` | runs | `stdlib/set_sample.expected` |
| `stdlib/set_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/testing_sample.kofun` | runs | `stdlib/testing_sample.expected` |
| `stdlib/testing_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/toml_sample.kofun` | runs | `stdlib/toml_sample.expected` |
| `stdlib/toml_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/tuple_sample.kofun` | runs | `stdlib/tuple_sample.expected` |
| `stdlib/tuple_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `stdlib/vector_sample.kofun` | runs | `stdlib/vector_sample.expected` |
| `stdlib/vector_sample_test.kofun` | owned | `tests/stdlib/kotest/check.sh` |
| `tui_dashboard.kofun` | owned | `framework/tui/check.sh` |
| `wasm-browser/app.kofun` | owned | `docs/tour/check.sh` |
| `wasm_arithmetic.kofun` | owned | `bootstrap/wasm/check.sh` |

## Why the illustrative files do not run

They are not stale spellings. Each one is blocked on a slice boundary the
Stage 2 Core path states for itself:

| File | Boundary |
|---|---|
| `broken_list_monad.kofun`, `lawful_list_monad.kofun`, `proven_optional_bool_monad.kofun` | `law` declarations (DD-035) are not a Stage 2 Core top-level form |
| `ownership.kofun` | `read`/`take`/`own` parameter modes (DD-005, DD-006) parse, but the general ownership pass is open |
| `coding_interview.kofun` | The `List[Int]` signature now lowers, then the ordinary `while` reaches the exact `E2S10` unsupported-statement boundary at byte 120 |
| `null_and_else_if.kofun` | `Int?` construction and `??` coalescing lower to Core; the Text-valued `return if ... else if ...` remains outside Stage 2 value-return lowering and stops at `E2S12` |
| `pipeline.kofun` | `|>` is accepted design (DD-011); `map`, `filter`, and `sum` are not Core functions |
| `science.kofun` | `linspace` and the numeric surface it uses are not Core functions |

## Evidence binding

`artifacts/optional-bool-monad.evidence.json` records a `source.sha256` for
`proven_optional_bool_monad.kofun`. It had not matched since 2026-07-30 — the
example was edited and the evidence was not regenerated — and nothing compared
the two, which is how an artifact went on reporting `status: passed`,
`proven-finite`, and 264 of 264 cases for bytes that no longer existed. #875
resolved it by reducing the artifact to what is still true (`unverified`, exact
hash, no result asserted), and `examples/check-law-evidence.sh` holds that
exact shape.

The gate here is the general net beside it: **any** artifact under `artifacts/`
that binds itself by hash to a file under `examples/` must still match, and the
check fails rather than passing quietly if no such artifact exists at all. The
next one to drift is caught without waiting for someone to notice.
