# Deterministic compiler fuzz smoke tests

[![Scheduled fuzz](https://github.com/kofun-lang/kofun/actions/workflows/scheduled-fuzz.yml/badge.svg)](https://github.com/kofun-lang/kofun/actions/workflows/scheduled-fuzz.yml)

`grammar.sh` generates bounded random token streams and requires the Stage 2
lexer/parser to terminate with either a valid projection or a normal
diagnostic. A per-case watchdog turns hangs into failures; signals and other
abnormal statuses fail the gate.

`semantic_differential.sh` generates valid arithmetic programs and runs the
versioned semantic adapter protocol documented in
[`SEMANTIC_PROTOCOL.md`](SEMANTIC_PROTOCOL.md). The accepted
`arithmetic-model` independently calculates the result from the generator
inputs. Every backend declared in [`families/arithmetic.tsv`](families/arithmetic.tsv)
must report support and agree on explicit exit status plus exact stdout/stderr
bytes. C11, direct x86-64, and wasm32/Node are implementations under test; none
is presented as the oracle. A failure retains source, seed/case metadata,
resolved identities, tool checksums, raw observations, and an exact replay
command.

`value_if.sh` generates valid bounded Int-valued `if` programs for Stage 2,
calculates the selected result independently, and places checked
division-by-zero in every unselected branch. This catches eager branch
evaluation as well as wrong comparison or result lowering. The regular and
ASAN/UBSAN compiler builds must also emit byte-identical C, IR, and token
artifacts for every generated case.

`match_guard.sh` generates 32 valid guarded Bool `match` programs for Stage 2.
Each program independently expects two ordered guard probes followed by the
selected arm value. A division-by-zero guard is placed behind a nonmatching
pattern and another behind an already-selected matching pattern, so eager or
out-of-order guard evaluation fails at runtime. Unguarded `true` and `false`
fallbacks provide static coverage without affecting the expected output. The
regular and ASAN/UBSAN compiler builds must emit byte-identical C, IR, and token
artifacts for every case.

`match_value.sh` generates 32 Int-valued Bool `match` programs with alternating
scrutinees. Each case proves ordered guard probes, false-guard fallthrough,
nested value `if`, and selected-only arm evaluation while division-by-zero is
hidden behind nonmatching, unselected, and post-selection paths. Normal and
ASAN/UBSAN compiler builds must emit byte-identical C, IR, and token artifacts.

`match_value_invalid.sh` generates 32 invalid value matches across missing and
guard-only coverage (`E2S25`), unreachable arms (`E2S26`), invalid guards
(`E2S29`), and Void, empty, or multi-value arms (`E2S30`). Normal and
ASAN/UBSAN compilers must agree on status, diagnostic code, IR, and token tape,
write no internal stderr, and emit no C artifact.

`enum_match.sh` generates 32 valid and 32 invalid payload-free enum programs.
The valid side checks constructor selection, ordered guards, catch-all
fallbacks, and selected-only execution. The invalid side covers missing and
unreachable constructors (`E2S25`/`E2S26`), malformed or colliding declarations
(`E2S31`), and unknown or mismatched enum uses (`E2S32`). Normal and ASAN/UBSAN
compiler builds must agree on diagnostics and emitted artifacts, and both the
normal and sanitized generated C programs must produce the expected output.
The invalid corpus also crosses the 256-occurrence per-function enum-use bound
and requires `E2S32` without a C artifact.

`visibility-artifacts.sh` generates the visibility artifacts themselves — the
re-export resolver's inventory input and the KIF sidecar every source-free
consumer reads — rather than Kofun source. Five families each get an accepted
case *at* a declared budget and a refused case one past it: facade chain depth
and re-export declarations per module (both read out of
`bootstrap/stage2/re_exports.c`, so a changed limit regenerates the fixtures
and a deleted one fails the gate), malformed 32-byte identity spellings,
provenance cycles, and seeded single-byte and truncation mutants of a published
KIF. Every refusal must exit 1, name its code on stdout with an empty stderr,
publish no HIR/KIF/tooling/dump, disclose neither the checkout path nor a
private declaration name, and print the same bytes twice. The accepted chain is
then rebuilt under a different absolute prefix, from differently named sources,
with the inventory lines reversed, and every published byte must be identical.
Envelope-size and graph-work budgets are out of its runtime budget and it says
so on stdout rather than leaving a green run to imply otherwise.

The valid observable portions of `value_if.sh`, `match_guard.sh`,
`match_value.sh`, and `enum_match.sh` use the same normalized result records.
Their shell generators are the accepted bounded models, and the Stage 2 C11
outputs remain implementations under test. Family-specific sanitizer,
compiler-artifact, and invalid-diagnostic checks are retained rather than
being weakened into generic output comparisons.

Run the protocol's deterministic negative and replay fixtures separately:

```sh
sh tests/fuzz/semantic_protocol_test.sh
```

They require stdout, stderr, exit status, capability, omission, crash, timeout,
malformed output, unsupported-only coverage, missing oracle, and missing
backend failures to remain distinguishable.

Run all fuzz smoke gates:

```sh
task fuzz
```

These are bounded CI smoke budgets, not a replacement for long-running
coverage-guided fuzzing. The semantic gate uses the active C11 reference
because a general Kofun interpreter is not yet part of the Python-free
toolchain.

## Seeds

Every generator prints the seed it ran with and takes it from an environment
variable, defaulting to the value the corpus was recorded with. `task fuzz`
therefore generates the programs it always has, byte for byte, and a run that
wants different programs asks for them:

```sh
KOFUN_GRAMMAR_FUZZ_SEED=20260810 sh tests/fuzz/grammar.sh
```

| Gate | Variable |
|---|---|
| `grammar.sh` | `KOFUN_GRAMMAR_FUZZ_SEED` |
| `semantic_differential.sh` | `KOFUN_SEMANTIC_FUZZ_SEED` |
| `value_if.sh` | `KOFUN_VALUE_IF_FUZZ_SEED` |
| `match_guard.sh` | `KOFUN_MATCH_GUARD_FUZZ_SEED` |
| `match_value.sh` | `KOFUN_MATCH_VALUE_FUZZ_SEED` |
| `match_value_invalid.sh` | `KOFUN_MATCH_VALUE_INVALID_FUZZ_SEED` |
| `enum_match.sh` | `KOFUN_ENUM_MATCH_FUZZ_SEED` |
| `optional_narrowing.sh` | `KOFUN_OPTIONAL_NARROWING_FUZZ_SEED` |
| `visibility-artifacts.sh` | `KOFUN_VISIBILITY_ARTIFACTS_FUZZ_SEED` |
| `hm_levels.sh` | `KOFUN_HM_LEVELS_SEED` |

A non-integer value is refused with exit 2 rather than silently falling back,
so a lane that computes a seed cannot quietly run the default one instead.

## Scheduled lane and findings

The daily [`Scheduled fuzz`](../../.github/workflows/scheduled-fuzz.yml)
workflow runs the nine randomized gates above. It derives a separate 31-bit
seed for each generator from the GitHub run id; repeating one run id produces
the same seed plan, while the next run id rotates every seed. The normal
`task fuzz` entry point does not call this runner, so its recorded defaults and
pull-request behaviour stay unchanged.

`semantic_protocol_test.sh` is deliberately absent from the scheduled list. It
has no PRNG: it is a fixed set of negative and replay protocol fixtures, and
`task fuzz` continues to run it. Giving that test a nominal seed would claim
coverage rotation where no generated input exists.

A generator failure leaves `seeds.tsv`, the generator log and work directory,
a directly executable `reproduce-<generator>.sh`, `summary.md`, and a
schema-validated `findings.json` in the workflow artifact. The step summary and
the badge above retain the failed state without someone watching the live log.
The workflow has read-only repository permissions; it never commits a result or
opens an issue.

[`findings.json`](findings.json) is the tracked register and
[`findings.schema.json`](findings.schema.json) defines each row. At minimum a
row carries the UTC date, generator, exact seed, run id and attempt, exit
status, failure kind, severity, resolution, reproduction command, and evidence
path. Triage copies a failed-run row into the tracked register, replaces
`untriaged` with a severity, and records either `unresolved`, `resolved`, or
`false-positive`; a resolved row also requires a resolution note. The register
gate refuses untriaged rows and unresolved critical findings, so the second
half of the M4 criterion cannot silently read green.

Run the orchestration, schema mutations, seed rotation, forced failure, and
generated reproducer checks without GitHub access:

```sh
sh tests/fuzz/scheduled-check.sh
```

This makes scheduled seed rotation and critical-finding accounting measurable.
It does not yet provide a growing corpus or coverage instrumentation, and
sustained history still has to accumulate before M4 can close.
