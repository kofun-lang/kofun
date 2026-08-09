# Security model

## Safe-by-default contract

Safe Kofun code must not produce:

- use-after-free
- double free
- invalid mutable aliasing
- data race
- uninitialized read
- unchecked null dereference
- unchecked out-of-bounds access
- silent integer narrowing
- arbitrary compile-time process execution

Stage 0 is a UX prototype and does not yet constitute a complete proof of this contract.

## Compiler threat model

Untrusted source may attempt:

- parser stack exhaustion
- exponential type inference
- macro resource exhaustion
- path traversal
- generated filename collision
- backend command injection
- malicious debug metadata
- cache poisoning
- package dependency confusion

Mitigations:

- iterative or bounded parser paths
- inference budgets and cycle detection
- sandboxed macro runtime
- canonical path checks
- no shell invocation for compiler subprocesses
- content-addressed caches
- checksummed lockfiles
- structured backend invocation
- fuzzing and corpus testing

The active host-C profiles pass link inputs as argument-vector entries and
never interpolate them into a shell command. The direct-static native CLI
application compiler does not invoke a host compiler, assembler, linker, or
shell while emitting the final ELF.

### Compiled interface visibility

KIF inputs are untrusted semantic cache material. A public fact must not gain
authority by naming an internal, private, absent, or wrong-kind identity. The
bounded KIF v2 reader resolves every nominal function and constructor-payload
reference against the validated fact set before exposing any fact. Public
references require public ADTs; package-internal references accept public or
internal ADTs; private facts never enter either view. Failure returns the
generic `visibility-leak` class without names, paths, spans, candidate counts,
or SymbolIds and cannot replace the caller's prior atomic artifact.

The compiler performs the same check against committed resolved declarations
before serialization. Same-source diagnostics identify byte spans and
requested/effective boundaries but intentionally omit hidden spellings.
Records, generics, effects, and ownership signature components are refused
until a canonical producer can classify every component rather than treating
an absent fact as public. `tests/security/module-interface-artifact.sh` is the
negative test for this refusal boundary.

## Runtime threat model

- allocation denial of service
- GC pause amplification
- adversarial hashing
- regex denial of service
- unbounded recursion
- task explosion
- deadlock
- unsafe FFI
- finalizer abuse

Runtime profiles expose limits for heap, stack, tasks, macro instructions, and execution time where feasible.

## Package security

planned defaults:

- lockfile checksums
- registry TLS and signed metadata
- package signatures as an additional signal
- dependency source shown in lockfile
- namespace conflict defense
- no install-time arbitrary script by default
- capability declaration for build plugins
- offline and vendor modes
- reproducible build metadata
- SBOM generation

## Macro security

Default macro capabilities:

```text
filesystem: declared inputs only
network: denied
process: denied
clock: denied
random: deterministic seed only
memory: bounded
instructions: bounded
```

## FFI

FFI is a trust boundary.

- ABI-safe types only across default C boundary
- explicit ownership annotations
- GC handles instead of raw managed pointers
- callback lifetime tracked
- foreign exceptions cannot cross unchecked
- thread attachment required before accessing runtime
- sanitizer build profiles

## Reporting

A production project must publish:

- security contact
- encrypted reporting path
- response targets
- supported versions
- CVE process
- disclosure policy

The bounded C ABI profile is executable, but the broader FFI policy above
remains target design. Foreign libraries and their transitive dependencies are
trusted native code; no operational security team is implied.

The Rust crate shim example keeps managed Rust values inside Rust, catches
panics before returning, and uses checked buffer/length/status records.
Vendoring and checksums improve reproducibility but do not make third-party
native code memory-safe from Kofun's perspective.

The bounded native CLI profile validates declaration sizes, command and option
uniqueness, and action shapes before serialization. Its product uses only
Linux `write`, `ioctl`, and `exit` syscalls, but process-provided argument and
environment bytes are still untrusted terminal output. See
`framework/cli/SECURITY.md` for its exact boundary.

## Compile-time law execution

The active compiler does not execute laws. It rejects the retained historical
`law monad` examples with `E2S02`, so there is currently no active
law-evaluator attack surface, evidence producer, optimizer input, or release
gate.

The accepted replacement treats every operation, equation, custom equality,
domain enumerator, and shrinker as untrusted compile-time logic. Each must have
an empty effect set. Print/debug output, clock and time, randomness,
environment and process arguments, file/network/process access, FFI, async
work, and global mutation are denied. Possessing a runtime capability does not
grant an exception.

The versioned `kofun.law-eval/standard-v1` sandbox has these hard caps:

| Resource | Cap |
| --- | ---: |
| planned cases | 100,000 |
| evaluator steps | 10,000,000 |
| recursion depth | 256 |
| allocations | 1,000,000 |
| live heap | 64 MiB |
| one rendered or serialized value | 1 MiB |
| total diagnostic text | 64 KiB |

A source-level custom budget may only reduce those caps. Cancellation is
checked at least every 1,024 evaluator steps and emits no reusable evidence.
A wall-clock watchdog may abort compilation, but wall time is not a semantic
budget and cannot turn an incomplete run into evidence. Case, step, recursion,
allocation/byte, forbidden-effect, cancellation, and insufficient-assurance
failures have distinct stable diagnostics and fail the normal check/build
path.

`bounded-exhaustive` covers only the declared finite sample.
`proven-finite` additionally requires compiler-certified complete finite
carriers, complete total-function spaces where used, and certified typed
equality. `proven` is reserved for a future trusted proof kernel.

`kofun.law-evidence/v2` uses purpose-separated SHA-256 cache and evidence
identities. Consumers must recompute the identities and validate compiler and
evaluator versions, ground types, normalized equations, implementation and
dependency digests, ordered domains, equality, budget, enumeration algorithm,
outcome, assurance, and canonical counterexample. Display paths, wall time, and
requested assurance are not semantic identity inputs. Failed, cancelled,
resource-exhausted, forbidden-effect, stale, weaker, or dependency-mismatched
evidence grants no compiler, optimizer, package, or cache authority.

The retained `kofun.law-evidence/v1` schema is historical and must never be
silently accepted as v2. Signature or provenance checks may strengthen
distribution trust, but do not replace recomputation of semantic identity.

## Bootstrap security

The trusted computing base is the checked-in Kofun sources, C11 seeds and C ABI
compiler, the host C compiler/linker, and the operating system. Stage 1, Stage
2, and C ABI artifact checks are reproducibility gates, not a defense against a
malicious seed and host compiler acting together.

`task selfhost-diverse-double-compilation` removes one member of that set from
the part that has to be trusted alone. It builds the generation chain under two
host C compilers that are different binaries reporting different identities and
requires the resulting Kofun compilers to emit byte-identical C and to agree on
every driver corpus case, so a payload present in **only one** of the two host
compilers is caught rather than pinned.

The rest of the base is unchanged, and the gate is worth reading for what it
leaves behind:

- a payload in the **checked-in seed** is not caught. Both chains build the
  seed from the same `bootstrap/stage2/compiler.c`, so a seed payload is shared
  by both and reproduces identically.
- a payload **shared by both host compilers**, or living **below** them — in
  libc, the kernel, or the operating system — is likewise shared and invisible.
  Both chains run on one machine.
- reproduction by a builder that did not produce the evidence, B6
  ([#274](https://github.com/kofun-lang/kofun/issues/274)), remains open. It is
  what would narrow the machine-shared part of the base, and diverse double
  compilation does not substitute for it.

What the gate changes is that the pinned artifact checks are no longer the only
evidence. Those compare this checkout against evidence recorded by one
toolchain, so a payload present when that evidence was recorded is pinned along
with it and passes forever; diverse double compilation is the one chain gate
that runs a compiler which did not produce the baseline.
