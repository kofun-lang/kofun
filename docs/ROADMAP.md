# Roadmap

## Release rule

Kofun advances milestones by correctness gate, not by feature count.

- never silently fall back on unsupported behavior
- attach a negative test and a threat model to every safety claim
- attach a reproducible benchmark to every performance claim
- distinguish the strength of law evidence as `bounded`, `proven-finite`, or `proven`
- do not call the project "self-hosting complete" before the Stage 2 fixed point

A milestone is advanced by evidence, not by a decision having been accepted.
The [RFC process](https://kofun-lang.github.io/kofun/docs/rfc-process/) records
public semantic decisions and keeps `accepted` separate from `implemented`;
an accepted RFC carries no schedule and moves no milestone until
[`release/claims.json`](../release/claims.json) evidences the capability. The
RFC sets named here are decision work, and appear on this roadmap only once
they have implementation evidence to advance.

## Current critical-path order

The frozen-profile fixed point is reached. The smallest compiler source `S`,
its typed profile, and deterministic C11 lowering produce `C1/A1`, `C2/A2`,
and `C3/A3`, and `task selfhost-fixed-point` proves `C2 == C3` and `A2 == A3`
byte for byte — the criterion decided on
[#271](https://github.com/kofun-lang/kofun/issues/271), with `C1/A1` as
hash-pinned runnable provenance — closing
[#272](https://github.com/kofun-lang/kofun/issues/272) and B4/B5.

Diverse double compilation, B7
([#1136](https://github.com/kofun-lang/kofun/issues/1136)), is closed:
`task selfhost-diverse-double-compilation` builds the chain under two host C
compilers that are different binaries reporting different identities and
requires the resulting Kofun compilers to emit byte-identical C and to agree
on every driver corpus case. It is the only chain gate that runs a toolchain
which did not produce the checked-in evidence, which is what a payload
recorded into that evidence hides from every other gate.

The remaining bootstrap path is independent clean-builder reproduction, B6
([#274](https://github.com/kofun-lang/kofun/issues/274)). B7 does not narrow
it: both of its chains share one machine, one libc, and one kernel, so it
bounds the trusted set rather than emptying it.

Widening the fixed point past the frozen profile to the full language is
separate from both, and is what the language slices below feed.

The closed gate uses one declared, normalized host C11 compiler. Direct
x86-64 and AArch64 compiler reproduction is a separate strengthening track;
both native backends already execute bounded Int, function, `List[Int]`, and
UTF-8 `Text` profiles. The [implemented-status matrix](MVP_IMPLEMENTED.md) is
the authority for their exact active boundary.

The heterogeneous record design is settled, not pending: [#546](https://github.com/kofun-lang/kofun/issues/546)
closed once [`spec/records-v1.md`](../spec/records-v1.md) was accepted, and
`task records` gates it. What stays open is lowering records past the bounded
frontend ([#783](https://github.com/kofun-lang/kofun/issues/783)).

The concrete-first law system, `Result` sequencing, and the small-core reactive
protocol are settled the same way, as DD-035, DD-036 and DD-037 in
[Design decisions](DESIGN_DECISIONS.md); what remains for each is implementation
rather than design. Function-call ergonomics
([#625](https://github.com/kofun-lang/kofun/issues/625)) is settled the same
way: [`spec/syntax/call-arguments-v1.md`](../spec/syntax/call-arguments-v1.md)
is the accepted contract, its surface and front end landed, and labelled calls
execute for `Int`/`Text`/`List[Int]` carriers — what remains is the lowering
shapes #882 still owns. Read `docs/DESIGN_DECISIONS.md` rather than an issue
number for whether a design is settled — issues close as their decisions land,
so a list of numbers here rots. None of this expanded the frozen
string-scanning profile before B4/B5, and widening it now is deliberate,
gated work rather than a side effect. Advanced effects, dependent or
refinement types, concurrency runtime implementation, and an optional second
backend remain later. The
evidence and keep/defer/reject decisions are indexed in the
[implemented-status matrix](MVP_IMPLEMENTED.md).

## M0 — Specification and UX validation

Deliverables:

- working title decision process
- syntax RFC set
- memory model RFC
- type/effect/law model RFC
- standard library naming guide
- error code policy
- executable reference semantics corpus
- one-day tutorial user tests
- concrete-first finite-law checker design and executable status audit
- bootstrap stage manifest

Exit criteria:

- no unresolved P0 ambiguity in the core syntax
- ownership examples can be explained without Rust experience
- null/optional behavior is fixed
- the coding interview sample set is complete
- law assurance labels do not mislead
- bootstrap status can be verified machine-readably

Current foundation:

- Kofun-written nested-block Int/Bool/Text/List[Text] Core compiler seed
- frozen self-host profile and runnable first compiler generation
- direct x86-64 and AArch64 bounded native checkpoints
- compiler-wide stable diagnostic and semantic-oracle gates
- affine ownership prototype; the general checker remains design work
- historical bounded-Monad examples, finite-model artifacts, and JSON schema;
  active compiler integration remains open in
  [#551](https://github.com/kofun-lang/kofun/issues/551)

## M1 — Bootstrap compiler

Deliverables:

- lossless parser
- module resolver
- stronger type inference
- MIR-based ownership checker
- bytecode VM
- C11 backend expansion
- full CLI skeleton
- package manifest and lockfile draft
- formatter and language server prototype
- Stage 1 frontend written in Kofun
- Stage 1 type, ownership, and law checker written in Kofun
- Stage 1 C11 backend written in Kofun
- Stage 2 self-recompile pipeline
- normalized Stage 1/Stage 2 artifact comparison

Law deliverables:

- Functor, Applicative, Semigroup, and Monoid law families
- deterministic model checker budgets
- type-directed counterexample shrinking
- finite ADT enumeration
- evidence serialization and cache keys

Exit criteria:

- self-contained medium programs run
- compiler never silently accepts unsupported backend behavior
- lexer/parser/checker fuzzing is continuous
- 1,000+ conformance tests
- Stage 1 compiles its own source
- Stage 2 rebuilds an equivalent compiler artifact
- Stage 0/Stage 2 diagnostics and semantics agree on the bootstrap corpus

## M2 — Alpha native runtime

Deliverables:

- generational GC
- deterministic owned resources
- native backend
- ADT, match, generics, traits
- Result/error propagation
- effects phase 1
- standard collections
- async runtime prototype
- C/Python interoperability
- N-dimensional arrays phase 1
- lawful trait declarations
- small generic proof kernel
- proof certificate format

Exit criteria:

- safe subset memory safety audit
- VM/native differential tests
- benchmark suite against C, Rust, Python, Julia, and Go where meaningful
- Linux/macOS primary support
- generic optimizer rewrites require checked proof evidence
- malformed proof certificates cannot crash or escape the kernel

## M3 — Beta ecosystem

Deliverables:

- package registry
- signed packages and lockfiles
- language server
- debugger/profiler integration
- typed hygienic macros
- scientific stack phase 2
- Windows support
- Wasm/WASI support
- documentation generator
- migration and edition tooling
- external SMT/proof-search adapters that emit kernel-checkable certificates
- cross-package law evidence ABI
- reproducible bootstrap and diverse double compilation

Exit criteria:

- no open P0/P1 compiler correctness bug
- stable package and module model
- production pilot projects
- reproducible builds
- active security response process
- bootstrap provenance can be independently audited
- law-based optimizations have differential and certificate tests

## M4 — 1.0

[`docs/RELEASING.md`](RELEASING.md) sends a reader here to learn what 1.0
requires, so this section states not only the list but where each item stands.
Every row was measured on `main@a654f7fe` and carries the command that
measured it, because a milestone list with no status cannot tell anyone how
far away 1.0 is — which is the question the list exists to answer.

The verdicts are `absent`, `partial`, and `present`. Re-run a row's command
rather than trusting its verdict; that is what the command is for.

### Deliverables

| Deliverable | Verdict | Measured | Command |
| --- | --- | --- | --- |
| language and runtime stability policy | absent | no document. `RELEASING.md` is deliberately the opposite — "No compatibility promise exists at `0.x`" — and defers the policy to this milestone | `grep -rniF "stability policy" docs/ *.md` → 1 hit, this list |
| stable ABI boundaries where promised | partial | 9 versioned boundaries, 8 gated in `task verify`; every one either has no backend behind it or explicitly refuses a stability promise, so **zero are promised stable today** | `git grep -hoE 'kofun[.:][a-z0-9._-]+/v[0-9]+' \| sort -u \| wc -l` → 118 identity strings; 6 tracked JSON Schemas |
| long-term support plan | absent | no document, and no release cadence to build one on: releases are tag-triggered and ad hoc | `grep -rniF "long-term support" docs/ *.md` → 1 hit, this list |
| complete specification | partial | 36 specification documents, 9,249 lines, covering 8 areas. No `spec/` document for the standard library, the ownership and memory model, metaprogramming, general type inference, or the C ABI. Traits and generics have only `spec/roadmap-31-34/generics-and-traits.md`, which calls its own lowering decision provisional. 12 of 41 design decisions carry a `spec/` pointer | `find spec -name '*.md' \| wc -l` → 36; `grep -cE '^## DD-[0-9]+' docs/DESIGN_DECISIONS.md` → 41 |
| conformance suite | partial | 537 `.kofun` cases under `tests/conformance/`, of which 176 are refusal fixtures. Only 7 corpora carry an `expectations.kofun` and so enter the cross-backend matrix: 87 declared cases, 17 of 35 backend×corpus cells supported. M1's "1,000+ conformance tests" exit criterion is not met | `git ls-files 'tests/conformance/**/*.kofun' \| wc -l` → 537; `find tests/conformance -name expectations.kofun \| wc -l` → 7 |
| multi-platform release | partial | Linux x86-64 only. AArch64 is cross-built and executed under `qemu-aarch64`, and skips (exit 125) without it. No macOS and no Windows exist. All seven CI jobs run on `ubuntu-latest`. Releases ship a source archive and its SHA-256, never a binary | `grep -rn "runs-on" .github/workflows/` → 7 × `ubuntu-latest` |
| adoption guide | absent | `docs/GETTING_STARTED.md` onboards contributors to the compiler, not teams adopting the language. Blocked behind the `general-parser-type-checker` claim, whose state is `open` | `grep -rniF "adoption guide" docs/ *.md` → 1 hit, this list |
| compatibility and edition process | partial | the compatibility half exists as two per-decision ledgers — `rfcs/index.json` with a typed four-value category and 20 of 32 rows carrying a corpus query, and `release/claims.json` with free-text prose and no enum. The edition half is **entirely unbuilt**: a reserved KIF tag, an `unspecified` package-id field, no syntax, no flag, no tool, no policy | `git grep -c -- "--edition" -- bin tooling package` → no matches |
| audited proof kernel | absent | no kernel. `docs/LAW_SYSTEM.md` opens by stating the active compiler does not parse, type-check, evaluate, or emit evidence for its design. The `proven` assurance level is defined as unreachable by any current path; the one live artifact is `bounded-exhaustive`. Its M2 prerequisites — proof kernel and certificate format — are not started | `grep -oE "proven-finite" release/claims.json \| wc -l` → 0 |
| audited bootstrap chain | partial | All 13 gates in `bootstrap/manifest.json` read `working` — diverse double compilation closed with [#1137](https://github.com/kofun-lang/kofun/issues/1137) — and since [#1108](https://github.com/kofun-lang/kofun/issues/1108) every one of them is joined to a published claim, so a gate cannot flip without its claim moving. What no gate supplies is the audit: no record exists of who reviewed the 31,808 lines of seed C, when, or against what. [#1138](https://github.com/kofun-lang/kofun/issues/1138) removed the word from the documents that claimed it, and `task audited-claim` refuses it there while this row stays open | `test -f bootstrap/AUDIT.md` → absent |

### Exit criteria

| Exit criterion | Verdict | Measured | Command |
| --- | --- | --- | --- |
| external security audit | absent | no audit report exists for anything in the repository | `git ls-files '*AUDIT*'` → no matches |
| sustained fuzzing without unresolved critical findings | partial | `task fuzz` retains its recorded defaults, while a daily lane now rotates bounded, reproducible seeds across its 9 randomized generators. A failed run preserves its exact seed, log, work tree, validated finding and executable reproducer as an artifact and step summary; a tracked register refuses untriaged rows and unresolved critical findings. This is measurable but not yet *sustained*: no growing corpus or coverage instrumentation exists, and run history still has to accumulate | `sh tests/fuzz/scheduled-check.sh` → seed rotation, forced failure/finding, and exact reproduction pass |
| performance regression gates | absent | one gate runs in CI, and it asserts **fixed absolute ceilings** rather than a baseline, so a hover that slows from 4 ms to 40 ms passes. The real 5%-regression gate left this repository with the benchmark corpus in [#1139](https://github.com/kofun-lang/kofun/issues/1139) and is now owned by [`kofun-lang/kofun-benchmarks`](https://github.com/kofun-lang/kofun-benchmarks), where nothing schedules it yet. This milestone cannot close on a gate this repository does not run | `git ls-files benchmarks \| wc -l` → 0 |
| independent production use | absent | no adopter is recorded anywhere | `git grep -ril "adopter\|production use" -- '*.md'` → this list only |
| governance and funding model | absent | no document. An RFC process and a security reporting process exist as components; neither is a governance model | `grep -rniF "governance" docs/ *.md .github/` → 1 hit, this list |
| fixed-point self-hosting artifacts reproduced by independent builders | open | B6, [#274](https://github.com/kofun-lang/kofun/issues/274). The producer-owned half landed as #1114; reproduction by a builder that did not produce the evidence has not happened | `task selfhost-declared-inputs` passes; nothing measures the consumer half |

### What the measurement says

Three things, none of which is visible from the list alone.

**Nothing here is overstated, and one thing is understated.** Every gap above
is already disclaimed by the document that owns it — `RELEASING.md` on
binaries, `tests/fuzz/README.md` on coverage, `LAW_SYSTEM.md` on the kernel.
The exception ran the other way: `benchmarks/native-functions/benchmark.sh`
implemented a complete regression gate, with a 5% ceiling and per-workload
improvement budgets, that nothing invoked. #1139 decided that against wiring
it in — the corpus moved to `kofun-lang/kofun-benchmarks`, because a
machine-dependent measurement does not belong in a tree whose `task verify`
must reproduce anywhere. So it is no longer the cheapest item on this page;
it is an item this repository no longer owns.

**Four items are not late, they are blocked behind earlier milestones.**
macOS is an M2 exit criterion and Windows an M3 deliverable, so
"multi-platform release" cannot start here. The proof kernel and certificate
format are M2 deliverables, so "audited proof kernel" has nothing to audit.
The adoption guide waits on a general parser and type checker, which
`release/claims.json` records as `open`. M4 is not the next milestone.

**Six of the sixteen items are documents nobody has started**, and four of
those — stability policy, LTS plan, adoption guide, governance and funding —
need a decision before they can be written, not engineering time. They are the
part of 1.0 that no amount of gate work reaches.

## Performance milestones

### P0 correctness baseline

- interpreter is source of truth
- no unsafe optimization
- unsupported constructs fail explicitly
- bounded law evidence is never treated as a generic proof

### P1 numeric baseline

- unboxed primitive loops
- C/Rust-compatible integer and float semantics
- measured bounds checks
- native math library calls

### P2 allocation baseline

- escape analysis
- stack allocation
- owned reuse
- generational nursery
- collection specialization

### P3 scientific baseline

- contiguous arrays
- broadcasting
- SIMD
- BLAS/LAPACK
- kernel fusion
- parallel execution

### P4 production tuning

- PGO
- LTO
- cross-module specialization
- GC pause targets
- CPU and allocation profiler
- proof-backed algebraic rewrites

## Self-hosting milestones

```text
B0  Stage 0 type-checks Stage 1 source
B1  Stage 1 compiles a useful Kofun Core subset
B2  Stage 1 contains the full frontend
B3  Stage 1 contains safety and law checking
B4  Stage 1 compiles itself
B5  Stage 2 artifact is equivalent
B6  independent reproducible bootstrap
B7  diverse double compilation
```

Current status: B4 and B5 are closed. The `selfhost-fixed-point` gate proves
`C2 == C3` and `A2 == A3` byte for byte — the criterion decided on
[#271](https://github.com/kofun-lang/kofun/issues/271), with `C1/A1` as
hash-pinned runnable provenance — and the full driver corpus agrees across
all three executable generations. B6 (independent reproduction) and B7
(diverse double compilation) remain open strengthening tracks.

## Law verification milestones

```text
L0  bounded exhaustive Monad model                     historical evidence; active gate open
L1  complete finite Bool/Optional[Bool] model           historical evidence; active gate open
L1.5 versioned JSON evidence and assurance build gate  schema/artifacts only; active gate open
L2  user-defined finite ADT enumeration                planned
L3  Functor/Applicative/Monoid families                planned
L4  typed proposition IR                               planned
L5  small proof-term kernel                            planned
L6  external certificate-producing solvers            planned
L7  proof evidence ABI and law-aware optimizer         planned
```

## Backlog mapping

Every open issue carries one of these milestones, and the GitHub milestone of
the same name is the tracker's copy of it:

```text
M0-spec
M1-bootstrap
M2-alpha
M3-beta
M4-1.0
```

The tracker holds curated issues only. A curated issue states its own `State`,
`Priority`, `Size`, and `Kind`, so the milestone it sits in can be read as work
rather than as a heading.

The generated subject grid — 27 areas of 25 subjects, each with a 20-step
lifecycle, 13,500 issues at full expansion — is not held open in the tracker.
Its placeholders carried no state, size, priority, or kind, so they could not be
picked up, estimated, or scheduled, and they outnumbered the curated issues
roughly five to one. Expand a subject into a curated issue when the work is
about to start; that is the point at which the fields above can be answered
honestly.
