# wasm32-wasi-command1 source and runtime projection v1

#1098 froze the host-facing side of this target: the `wasi_snapshot_preview1`
import allowlist, the capability manifest model, the deterministic host
vectors, and the refusal rules. It deliberately changed no Kofun source
syntax, type, effect, entrypoint, or backend rule — which left the shipped
compiler with no normative way to say which *checked source operation* reaches
which import, or how a program's imports are derived at all.

This profile is that answer. It adds no compiler change, no runtime, no engine
installation, and no capability or release claim. `model.mjs` is the same
contract executable, so the parts an implementer is most likely to get wrong
can be mutated before any of it exists.

Option A — explicit command context and authority values — was selected on
[#1293](https://github.com/kofun-lang/kofun/issues/1293) on 2026-08-14. Option
B, compiler-only ambient builtins, contradicts the authority charter RFC-0014
accepted and bypasses #1193/#1241-#1246. Option C, a component-model/WIT
surface, exceeds the accepted Preview 1 core-module profile; its retirement
trigger lives in the host matrix policy, not here.

## What RFC-0014 already answers, quoted rather than restated

Six of this issue's eleven sub-decisions were closed by RFC-0014 after the
issue was written. This profile **quotes** them and adds nothing beside them,
because a second copy is a second thing to drift:

- the only root-aware entrypoint is `fn main(take root: RootAuthority) -> Int`,
  and a program defines that or `fn main() -> Int`, never both;
- authorities and live handles are `Owned`, and all handles and buffers are
  released on every path;
- filenames are `Bytes`, and `Text.from_utf8` is the explicit validated
  conversion;
- attenuation can only remove choices or lower limits;
- runtime failures are typed ADT variants, and host errno is bounded adapter
  detail rather than cross-platform semantic identity;
- WASI maps the same language contract to a preopen-relative adapter, and an
  implementation that cannot enforce the same stay-beneath and byte-name
  semantics refuses the profile.

## 1. Entrypoint and exit

`fn main() -> Int` keeps its exact meaning. The root-aware form is the only
one that receives authority.

A successful return of `N` exits with the **same bounded Int-to-exit-status
mapping the existing executable targets already use** — 0 through 255 — and
the observable status must match those targets in shared fixtures. Whether the
lowering reaches it through `proc_exit` or through `_start` returning is the
implementer's choice; the observable status is not.

## 2. The nine capabilities, as source operations

Each row is one checked operation requiring an authority value attenuated from
the root. **Source spelling alone never grants anything**: an operation that
cannot name an authority cannot appear in this table, and the gate asserts
that every row names one.

| operation | authority | capability | yields |
|---|---|---|---|
| `CommandContext.arguments` | command context | `arguments` | `List[Bytes]` |
| `CommandContext.environment` | command context | `environment` | `List[Bytes]` pairs |
| `Stdin.read` | stdin handle | `stdin` | `Result[Bytes, IoError]` |
| `Stdout.write` | stdout handle | `stdout` | `Result[Unit, IoError]` |
| `Stderr.write` | stderr handle | `stderr` | `Result[Unit, IoError]` |
| `MonotonicClock.now` | clock authority | `monotonic-clock` | `Result[Int, ClockError]` |
| `Random.fill` | random authority | `random` | `Result[Bytes, RandomError]` |
| `Preopen.open` | preopen directory | `preopen-read` | `Result[File, IoError]` |
| `Preopen.read` | preopen directory | `preopen-read` | `Result[Bytes, IoError]` |
| `Exit.exit` | exit authority | `exit` | `Never` |

Every one of #1098's 13 frozen imports is reachable from some row, and the
gate fails if one stops being.

## 3. Absent versus empty environment: no distinction is offered

Preview 1 cannot represent it. `environ_sizes_get` yields a count, so an absent
environment and an empty one are the same observation.

The projection therefore defines the environment as a possibly-empty pair list
and **explicitly claims no absent/empty distinction**. Refusing to fake a
distinction the ABI cannot carry is the decision, not an omission — and it is a
function in the model rather than a sentence here, so a future implementation
that invents one fails a check instead of passing a review.

RFC-0014's `unknown` key-set fact is a different question and is untouched.

## 4. Manifest

#1098's frozen manifest model is the accepted format, unchanged and
byte-frozen. Every v1 capability key is present with a Boolean value; a
missing, unknown, or non-Boolean key refuses.

The CLI takes one explicit manifest-path flag at build time. The manifest
bytes' SHA-256 binds into the artifact and the build record.

## 5. Import derivation, and the direction that matters

Emitted imports are exactly the pairs required by **checked operations
reachable in the program**, intersected with what the manifest grants.

Two consequences, and both are asserted:

- a **granted capability with no reachable operation emits nothing**;
- a **reachable operation without its grant is a compile-time refusal at that
  operation's span**, not a dropped import and not a runtime error.

Deriving imports from the manifest is the easier direction to write and it
passes every happy-path test, so the gate mutates the model to do exactly that
and requires the properties to catch it.

## 6. Trap boundary

Errno maps per RFC-0014's typed-variant rule. Adapter-contract violations trap,
and **traps are never dressed as diagnostics**. Only the explicit exit
operation reaches `proc_exit` before `main` returns. Cleanup happens on every
non-trap path.

## 7. Memory

One exported linear memory and none imported, on the existing `wasm32`
target's allocator model. The page ceiling is declared in the manifest and
enforced. Pointer, length, and alignment are checked at the adapter boundary,
and no borrowed guest memory is retained across calls.

## 8. Compatibility

Existing `wasm32` and `wasm32-hostabi1` artifact bytes stay unchanged; their
existing gates are the proof. #1098's host vectors stay byte-identical.

## The binding constraint

Per accepted RFC-0014, `check` may validate and publish typed facts while
`build` and `run` **refuse the root/environment carrier** until that carrier
exists (#1242-#1246). #1296's selector activation is therefore fail-closed
until then, which is the module-shell shape #1296 already describes.

## The gate

```sh
task wasi-command-projection-contract
```

14 properties over 10 operations and 13 frozen imports, then nine
implementation mistakes each of which must be caught **by a distinct set of
properties**. Two mistakes caught by the same set would mean the model cannot
tell them apart, and that is a failure rather than a pass.
