# Semantic adapter and oracle protocol

The semantic fuzz protocol is versioned as
`kofun.semantic-capability/v1`, `kofun.semantic-result/v1`,
`kofun.semantic-case/v1`, and `kofun.semantic-family/v1`. Its purpose is to
make differential evidence explicit without treating a compiler backend as a
reference interpreter.

## Family declaration

A family manifest has four header records followed by participants:

```text
protocol<TAB>kofun.semantic-family/v1
family<TAB>FAMILY
generator<TAB>GENERATOR
scope<TAB>ACCEPTED-SCOPE
participant<TAB>ROLE<TAB>IDENTITY<TAB>SUPPORT<TAB>REASON<TAB>ADAPTER
```

`ROLE` is `oracle` or `backend`. `SUPPORT` is `supported` or `unsupported`.
A supported row uses `-` as its reason. An unsupported row must give a stable
token such as `node-unavailable`; it is reported but is not differential
evidence. Exactly one supported, accepted oracle and at least one supported
backend are required. The runner invokes every declared participant's
capability action before any supported run, so a missing adapter, a silently
removed result, or a supported-to-unsupported change fails.

An oracle is accepted only when its algorithm is specified independently of
compiler lowering and its declared scope is no wider than that algorithm.
Another compiler target is a backend, not an oracle. The arithmetic declaration
uses `arithmetic-model`: shell integer operations over the generated
`left`, `right`, `factor`, and `shape` inputs. It does not invoke Kofun or
inspect compiler output. Its accepted scope is the generated positive
addition/multiplication/print subset, not the whole Int64 language.

The wrapped Stage 2 families have the following independent authorities:

| Family | Accepted oracle | Scope | Implementations |
|---|---|---|---|
| `value-if` | `value-if-shell-model` | comparison, selected branch, and printed bounded Int | `stage2-c11` |
| `match-guard` | `match-guard-shell-model` | ordered, selected-only guard probes and result | `stage2-c11` |
| `match-value` | `match-value-shell-model` | ordered guards, selected arm, nested value-if | `stage2-c11` |
| `enum-match` | `enum-match-shell-model` | constructor/guard selection and printed bounded Int | `stage2-c11`, sanitized variant |

Their existing compiler-artifact and invalid-diagnostic invariants remain
family-specific. Only the exact runtime observations are wrapped by this
protocol.

## Capability and result records

`ADAPTER capability FAMILY` writes exactly:

```text
protocol<TAB>kofun.semantic-capability/v1
implementation<TAB>IDENTITY
role<TAB>oracle|backend
family<TAB>FAMILY
support<TAB>supported|unsupported
reason<TAB>-|REASON
```

`ADAPTER run FAMILY SOURCE CASE-META RESULT-DIR WORK-DIR` writes no transport
stdout or stderr. It creates `RESULT-DIR/result.tsv`, `stdout.bin`, and
`stderr.bin`. `result.tsv` contains:

```text
protocol<TAB>kofun.semantic-result/v1
implementation<TAB>IDENTITY
role<TAB>oracle|backend
family<TAB>FAMILY
support<TAB>supported|unsupported
exit<TAB>0..255|-
reason<TAB>-|REASON
```

The `.bin` files are the unmodified observable byte streams. They avoid
escaping, newline, and empty-stream ambiguities in the tabular metadata.
Supported results require an explicit process status and `-` reason.
Unsupported results use `-` status, an explicit reason, and empty streams.
The common runner never executes a participant declared unsupported.

A result is malformed if a record is missing, reordered, duplicated, has an
unknown field/value, or lacks either byte stream. The runner compares exit
status, stdout, and stderr exactly. Signals, adapter crashes, timeouts,
malformed capabilities/results, omissions, and transport output are protocol
failures rather than semantic observations or skips.

## Toolchain preparation is not an observation

The runner's timeout bounds one adapter invocation on one generated program.
Building a compiler is not part of that observation, so a generator prepares
every toolchain it can before its first case: `semantic_differential.sh`
builds the Stage 2 compiler with `kofun_stage2_build` and exports it as
`KOFUN_STAGE2_COMPILER`, in both generation and `--replay` mode, unless the
caller already exported one. Without that, the first case on an empty
`build/` timed the compiler build (#1656).
`tests/fuzz/semantic_cold_toolchain_test.sh` holds the property without
depending on machine speed: its CC stand-in refuses a Stage 2 compiler build
wherever the runner's adapter environment is set.

## Determinism and replay

Each case metadata file records protocol, family, generator version, original
seed, case index, and generator inputs. On failure the runner retains:

- the generated source and case metadata;
- a resolved participant manifest;
- adapter checksums and adapter/tool work records;
- raw capability/run transport streams and statuses;
- all complete normalized observations;
- the failure reason and an executable `reproduce.sh`.

It also prints the exact `semantic_differential.sh --replay ARTIFACT` command.
Replay consumes the retained source, metadata, and resolved identities instead
of regenerating a selected case. This keeps source and raw mismatch evidence
available even if later generator code changes.

Run the focused gates with:

```sh
sh tests/fuzz/semantic_protocol_test.sh
sh tests/fuzz/semantic_differential.sh
```
