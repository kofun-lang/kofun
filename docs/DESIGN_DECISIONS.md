# Initial design decisions

This is the readable narrative of what Kofun decided. It is not a status
report: a decision recorded here may be fully implemented, partly implemented,
or built only in someone's head.

[`rfcs/index.json`](../rfcs/index.json) is the machine-checked ledger that says
which. A decision indexed there carries its state, the evidence that bounds it,
and any amendment; the
[public RFC process](https://kofun-lang.github.io/kofun/docs/rfc-process/)
describes how entries move between states. Decisions that predate the ledger
are migrated into it as they become relevant, so absence from the ledger means
"not yet indexed", not "not decided".

A later entry may summarise a decision whose normative text was written
elsewhere — in `spec/`, or in a dedicated document under `docs/` — and names
it. The summary is the narrative, never a second contract: where the two
differ, the named specification is the one that decides.

Where a decision's semantics have changed, the original wording stays here and
the amendment is announced beside it by its fully-qualified id, such as
`DD-010/A01`. The ledger checker fails if a marker here has no amendment, or an
amendment has no marker, so a superseded sentence cannot sit in this file
reading as current.

## DD-001: `fn`

Use `fn` for named functions and lambdas.

Reason:

- short
- familiar from Rust, Kotlin-related ecosystems, Gleam, and modern language design
- easy to scan

## DD-002: `null` and `T?`

Use `null` as the only optional empty literal, restricted to`T?`.

Do not use `nil`, `None`, or implicit nullable references.

## DD-003: `else if`

Use two ordinary words instead of `elif` or `elseif`.

## DD-004: Square-bracket generics

Use `List[Int]` and `fn identity[T]`.

Reason:

- readable to Python/TypeScript users
- avoids angle-bracket parsing complexity
- compact

## DD-005: Hybrid memory

Use GC-managed ordinary values and affine owned resources.

Reason:

- graph/application/scientific code stays concise
- resources retain deterministic cleanup
- compiler can optimize unique managed values

## DD-006: Word-based parameter modes

Use `read`, `edit`, `take` instead of `&`, `&mut`, explicit move markers, and routine lifetime annotations.

## DD-007: Immutable by default

Use `let`; mutation requires `let mut` or `edit` access.

## DD-008: Expression-oriented control flow

`if` and planned `match` return values.

## DD-009: Practical loops

Keep `for`, `while`, indexing, and local mutation. FP is a core style, not a ban on algorithmic control flow.

## DD-010: `/` and `//`

`//` performs integer/floor division.

Amended by `DD-010/A01`: `/` is not defined on `Int`. It is reserved and
refused with one diagnostic rather than returning a fractional value, because
no fractional type exists to return. The original decision read "`/` returns
floating division"; three documents said so while four backends truncated and
one refused the operator outright, and #687 settled it in favour of refusal.
`spec/semantics.md`, `docs/SYNTAX.md` and `docs/TYPE_SYSTEM.md` state the
current meaning; `rfcs/index.json` records the amendment and its compatibility
analysis.

## DD-011: `|>` pipeline

Pass the left value as the first argument of the right call.

## DD-012: No silent backend fallback

If a backend cannot lower a construct, compilation fails with a source-located error.

## DD-013: Typed hygienic macros

No C-style textual preprocessor. Quote/unquote operates on token trees or typed public AST.

## DD-014: One standard tool

`kofun` owns build, run, check, test, format, lint, docs, packages, and profiling workflows.

## DD-015: C-speed as a measured goal

Do not claim C/Rust parity without workload-specific benchmarks. Build unboxed native paths and publish results.

## DD-016: Algebraic laws are compiler artifacts

Keep `law` as the standard term, but recognize it contextually rather than
reserving it globally. `Monad`, `Monoid`, and other family names are ordinary
library identifiers and never select compiler family-specific code.

The source model has three distinct structures: a law family containing typed
operations and equations, a named implementation supplying those operations,
and a named `check laws` request supplying domains, equality, assurance, and a
budget. V1 substitutes ground types before evaluation and does not require
higher-kinded types. A law failure fails the normal check/build path.

## DD-017: Evidence levels are never conflated

Treat `bounded-exhaustive`, `proven-finite`, and `proven` as separate assurance
levels. A finite sample can yield only `bounded-exhaustive`.
`proven-finite` requires compiler-certified complete finite carriers, complete
total-function spaces where used, and certified typed equality. `proven` is
reserved for a future trusted proof kernel. The engine computes assurance; a
requested minimum is only a build gate.

Search order and shrinking are deterministic. Equation/parameter/domain order
defines Cartesian enumeration; a failure is shrunk by structural size,
canonical encoded length, then canonical bytes. Evaluation and shrinking share
the same versioned resource budget and require an empty effect set.

## DD-018: Versioned machine-readable law evidence

The accepted target artifact is the deliberately incompatible
`kofun.law-evidence/v2`. Its purpose-separated evaluation-cache and evidence
SHA-256 identities bind compiler/evaluator semantics, law and ground types,
normalized equations, implementation and dependency digests, ordered domains,
equality, the `kofun.law-eval/standard-v1` budget, enumeration version, cases,
computed assurance, outcome, and canonical counterexample. Requested assurance,
display paths, and wall time do not change the reusable result identity.

Failed, stale, weaker, wrong-model, wrong-ground-type, or
dependency-mismatched evidence cannot authorize an optimization or cache hit.
The old `kofun.law-evidence/v1` JSON schema remains historical migration
material and is never silently interpreted as v2.

## DD-019: Self-hosting means a fixed point

The existence of compiler source written in Kofun is not by itself self-hosting. Only when Stage 1 self-recompile and Stage 1/Stage 2 artifact equivalence are both satisfied is it called a fixed-point bootstrap.

## DD-020: Two Stage 1 execution paths

In the early bootstrap stages, compare the Stage 1 output of the Stage 0 interpreter build against the Stage 1 output of the native build produced by the Stage 0 C11 backend. Agreement between the two is the differential gate that precedes Stage 2.

## DD-021: Records declare with `type` and construct with labels

Nominal records are declared `type Name = { field: Type, ... }` and constructed
`Name(field: value, ...)`. A second `record Name { ... }` declaration family and
the `Name { ... }` brace construction are both rejected.

Reason:

- one declaration vocabulary already covers aliases, sum types, and records;
- the parenthesized labelled call form cannot collide with blocks, control-flow
  conditions, loop iterables, or the still-open map literal, so records do not
  have to be sequenced behind #52/#624;
- a construction that never uses braces removes the parser-context suppression
  that brace construction forces on `if`, `while`, and `for`.

Every declared field is supplied exactly once in any written order. Arguments
evaluate left to right in written order; storage, layout, and drop follow
declaration order. Fields are immutable in v1, `take` moves a whole record, and
`take value.field` is rejected, so no partially moved record exists.
[`spec/records-v1.md`](../spec/records-v1.md) is normative.

## DD-022: Redundancy that is evidence is not duplication

Some repeated work in this repository exists *because* it is repeated. Where two
things are derived independently and a gate asserts they agree, the agreement is
the evidence, and sharing the derivation deletes it — the gate keeps passing and
proves nothing. Those sites are not refactoring targets, and DD-020 is the
general case of the rule.

Load-bearing redundancy, which must stay:

- `bootstrap/stage1/compiler.kofun` and `bootstrap/stage1/compiler.c` — the
  Kofun source and its hand-audited C transliteration. One change is written
  twice on purpose: a host C11 compiler alone must be able to start the
  Kofun-written compiler, and the differential is what says the transliteration
  is faithful.
- `valid_source` and `emit_statements` inside that seed — two structural walks
  that repeat the same block and scope bookkeeping rather than sharing it, so
  every name resolves to the binding *both* walks agreed on.
- The audited seed and the compiler built from `S.c`, compared on every accept
  and reject corpus by `bootstrap/selfhost/check-compiler-driver.sh`.

Ordinary duplication, which should be removed:

- harness scaffolding — the per-corpus setup, comparison, and execution sequence
  around a differential. Collapsing it changes how the comparison is *invoked*,
  not what is compared, so the evidence is untouched.
- parallel hand-written lists of the same set. A list beside the thing it
  describes drifts silently; derive it, and assert a count so a deliberate
  change stays reviewable. The refusal corpora are globbed for this reason.

The test that separates the two: **if this were shared, would any gate still
fail when the underlying property breaks?** If no gate would fail, the
repetition was the gate. If some gate still fails, the repetition was scaffolding.

Two copies of a *constant* are acceptable where a mismatch fails loudly —
`REJECT_FIXTURE_COUNT` is asserted in both gates, so a stale copy stops the
build. The defect DD-022 targets is silent disagreement, not repetition itself.

## DD-023: A native target declares facts, not policy

A native target supplies only what its ABI decides — its register file, its
calling convention, and its instruction emitter — and adds nothing else.
Anything derivable from those facts is written once in target-independent code,
and every target runs that one copy.

Concretely, a target declares a `TargetRegisterFile`: its caller-saved scratch
class, its call-safe class, and the value meaning "no register". It does not
bring a register allocator. The allocation policy — scratch first unless a
value must survive a call, call-safe otherwise, nothing for a binding read
fewer than twice — lives once in
[`bootstrap/native/core_compiler.c`](../bootstrap/native/core_compiler.c) and
reads the declared file.
[`docs/NATIVE_BACKEND.md`](NATIVE_BACKEND.md) is normative for the contract.

Reason:

- x86-64 and AArch64 each carried a private copy of the four `take_*_register`
  functions. After normalising the `X64_`/`A64_` prefixes the copies were
  **identical**, so the pair could not disagree and the native gate proved
  nothing about them. Under DD-022 that is ordinary duplication, not evidence:
  sharing it loses nothing and gains one tested implementation.
- Every queued codegen item is otherwise priced per target, and the multiplier
  grows with each new backend.

This decision is deliberately narrow, and DD-022 is why. It shares only the
layer whose duplicate copies were byte-for-byte the same algorithm. The
lowering pairs — `function_expression`, `function_divide`, `function_compare`
and the rest listed in `docs/NATIVE_BACKEND.md` — are **not** shared by this
decision. Those are two genuinely independent lowerings that the native gate
requires to agree on observable behaviour and on `R010` diagnostic bytes, so
the agreement is the evidence and sharing them would delete it. Whether to
share them anyway, and what would replace the lost differential, is a separate
decision this one does not make.

A new target that re-adds its own copy of the shared allocator is a defect. The
`function_register_allocation` fixture pins the leaf prologue for both targets,
so perturbing the shared path fails the native gate on each of them.

## DD-024: Four semantic namespaces

Every named declaration belongs to exactly one of four namespaces — value,
type, module, meta — and lookup is syntax-directed. Capitalization never
selects a namespace, and no implementation may add a local fifth tag: a new
kind needs a new schema domain or a compatible schema extension. The tag order
is canonical serialization order, not lookup precedence.

Reason:

- one unified namespace rejects the type/value name reuse that ordinary
  programs want;
- a namespace per declaration kind fragments lookup and tooling;
- four domains give every symbol an identity while keeping use-site selection
  teachable.

[`spec/modules/namespaces.md`](../spec/modules/namespaces.md) is normative.

## DD-025: An explicit `module` header is the only module authority

A manifest source declares `module user.service` in its header. The manifest
says which files belong to the package; the header says which module the file's
declarations belong to. A directory, filename, source root, working directory,
or discovery order never supplies a fallback name, and tooling may lint a path
convention but a lint cannot change `ModuleId`. An anonymous single-file source
carries no header and always belongs to one synthetic root module.

Reason:

- a file move stops being an API rename;
- source spelling is host-independent, where path derivation leaks host case
  and normalization rules;
- generated and nonstandard layouts declare their intent instead of imitating
  a directory tree.

[`spec/modules/source-file-mapping.md`](../spec/modules/source-file-mapping.md)
is normative.

## DD-026: One digest never does two jobs

Compiler-authoritative interfaces are a versioned length-prefixed binary
(`KIF`); JSON is dump-only. Identities and digests are SHA-256 over a framed,
domain-separated preimage, never over a bare concatenation. A target-neutral
public semantic digest, a target-neutral package-internal semantic digest, and
a target ABI digest are three distinct values with distinct domains and inputs.

Nominal layout stays opaque unless an explicit representation or foreign-ABI
contract exposes it. Compatible optional minor fields may be skipped; unknown
required or major data requires a rebuild. A 16 MiB envelope and bounded
counts and depth are validated before allocation.

[`spec/modules/module-identity.md`](../spec/modules/module-identity.md) is
normative.

## DD-027: Re-exports are explicit and never widen

A module forwards part of its public API with the existing contextual `pub`
modifier on an import: `pub import collections`, `pub from collections import
Map, Set`. An `export import` form, manifest export lists, and implicit
re-export of ordinary imports are all rejected, so an ordinary `import` stays a
private binding and an implementation dependency never becomes a compatibility
commitment by accident. `pub` on a re-export requests public reachability for
that edge; it is not a request to widen the target.

[`spec/modules/re-exports.md`](../spec/modules/re-exports.md) is normative.

## DD-028: The typed sidecar is never authoritative

Editors and developer tools read a canonical UTF-8 JSON artifact — media type
`application/vnd.kofun.typed-sidecar+json;version=1`, conventional suffix
`.kofun-semantic.json` — and every document declares `"authoritative": false`.
It is deliberately separate from the compiler-authoritative KIF interface: no
compiler, KIF, or cache consumer may treat a sidecar as input, and a partial
document says which facts it omits rather than presenting itself as complete.

[`spec/tooling/typed-sidecar.md`](../spec/tooling/typed-sidecar.md) is
normative.

## DD-029: Discovery is compiler-backed

What type does this expression have, what can be called at this position, and
why is an expected operation unavailable — one semantic service answers all
three over the `kofun.discovery.request/v1` and `kofun.discovery.result/v1`
records. This keeps the useful part of an interactive `methods` listing without
a universal `Object` hierarchy, runtime dispatch by string, or ambient
reflection metadata. A runtime adapter stays optional and separately gated, and
every result carries `"authoritative": false`.

[`docs/DEVELOPER_DISCOVERY.md`](DEVELOPER_DISCOVERY.md) is normative.

## DD-030: Unsuffixed fractional literals are `Decimal`

`Decimal` is Kofun's exact base-10 value type, so `0.1 + 0.2 == 0.3` and
`1.20 == 1.2` hold without passing through binary floating point. Decimal
arithmetic never rounds implicitly; no operation implicitly promotes between
`Int`, `Decimal`, and `Float`; every backend observes the same value, result,
diagnostic, and explicitly requested rendering; and a resource limit may reject
an operation but may not change its mathematical result. `Float` remains the
opt-in binary64 type for numerical computing and native interoperation.

[`docs/DECIMAL.md`](DECIMAL.md) is normative.

## DD-031: Type-level programming is named and terminating

Type-level logic is a module-level declaration with a stable identity —
`type fn Flatten[T: Type] -> Type { ... }` — and never an anonymous type
expression at a use site. The v1 profile `kofun.type-reduction/default-v1` is
Type-only, named, and structurally terminating.

Anonymous conditional, mapped, or inferred type expressions are rejected
because diagnostics would depend on anonymous internals. General recursive and
mutually recursive type programs are rejected because termination, cost, and
error size are not statically bounded, and Turing-complete type programming is
rejected as a goal. Higher-kinded and effectful type computation is deferred,
not refused: it needs separate kind, capability, and evidence decisions.

[`spec/type-level-programming-v1.md`](../spec/type-level-programming-v1.md) is
normative for the v1 profile.

**Amended: `DD-031/A01` (2026-08-09).** The two paragraphs above are the
original wording and are preserved as written; they are no longer current on
two points, and a reader should not take them as such.

- **General recursion is admissible, and Turing-completeness is no longer
  rejected as a goal.** [RFC-0008](../rfcs/0008-type-level-general-v2.md),
  accepted for #1130, adds the `type fn general` modifier and the
  `kofun.type-reduction/general-v2` profile. Termination is bounded by
  versioned frame, step, and node limits instead of by structure, and
  exhausting one is a deterministic type error naming the declaration, the
  limit, the measured counts, and the top consumers — a bounded diagnostic
  rather than a hang. Structural termination becomes a *checked property* of
  the unmarked `type fn` rather than the only admissible form, and a
  structural declaration may not call a general one, so a `default-v1` root
  keeps the v1 guarantee compositionally.
- **The profile is no longer Type-only.**
  [RFC-0009](../rfcs/0009-type-level-kinds-v1.md), accepted for #1133, adds
  the `Nat`, `Symbol`, and `Bool` data kinds and the
  `kofun.type-reduction/kinds-v1` profile. This narrows the "higher-kinded
  computation is deferred" sentence to the kind axis only; effectful type
  computation stays deferred.

What the amendment does **not** move: anonymous conditional, mapped, and
inferred type expressions are still rejected, for the reason originally
given. Both RFCs are `accepted`, which decides semantics and nothing else —
no compiler implements either, and `release/claims.json` remains the
authority on what the compiler can currently do.

## DD-032: `trait`, with a local-trait-or-local-outer-type orphan rule

Kofun keeps the `trait` keyword and permits a retroactive implementation only
when the implementing package declares the trait, or declares the outer nominal
type constructor of the self type. Importing, aliasing, or re-exporting an
identity never changes its owner. At most one implementation applies to one
fully resolved coherence key across the whole dependency graph, and overlap is
rejected while declarations and validated interfaces are combined rather than
deferred to execution.

Dictionary passing is the semantic baseline for a trait-bounded call, and
runtime instance search is forbidden. Monomorphization is an optional typed-IR
optimization: a specialization must preserve the observable result of the
dictionary form and must be removable without changing whether a program
type-checks. That lowering baseline is provisional — it is the one part of the
decision the specification marks as awaiting a recorded experiment.

[`spec/roadmap-31-34/generics-and-traits.md`](../spec/roadmap-31-34/generics-and-traits.md)
is normative.

## DD-033: Layout is target-parameterized, not target-identical

`Text`, `List`, flat records, and flat ADT variants get deterministic byte
layouts computed from a declared `TargetDataLayout`. Layout identity is the v1
schema plus the complete target parameters plus type identity, so one type on
two targets is two descriptors and neither is privileged: a 32-bit target gets
4-byte references and a 64-bit target 8-byte references without either one
changing source semantics.

One byte-identical layout on every target is rejected — it decides wasm32
pointer width in advance and hides that decision inside a diff that looks like
formatting. An opaque handle for every aggregate is rejected as the default
representation, because it costs an allocation and a dereference per aggregate
and forfeits the predictable native layout this contract exists to give.

[`spec/aggregate-layout-v1.md`](../spec/aggregate-layout-v1.md) is normative.

## DD-034: Validation accumulates in `Validated`, not `Result`

`Validated[T, E]` is `Valid(T)`, `Disputed(T, Issues[E])`, or
`Invalid(Issues[E])`: an ordinary eager value distinct from `Result`.
Independent combination — `map2`, `map3`, `all` — collects every issue from
every branch in deterministic left-to-right order. Dependent sequencing,
`and_then`, never invokes its continuation when the input has no value, so a
check that needs a parsed value cannot run against a value that was never
produced. Converting to `Result` treats any issue as failure and carries all
issues in order.

V1 branches and continuations are pure, one rule rather than two; admitting an
impure `and_then` marker is deferred, not rejected. There is no heterogeneous
n-ary sugar, because it depends on tuples and metaprogramming decisions that
are not made and is additive later. Arity stops at `map3` and then nests, since
a ladder is easy to extend on evidence and awkward to retract. `Issues[E]` is
opaque — ordered iteration, `first()`, `count()`, nothing else — which is what
keeps the O(N) accumulation bound, including left-associated chains, a
conformance requirement rather than an aspiration.

[`spec/effects/validation-accumulation.md`](../spec/effects/validation-accumulation.md)
is normative.

## DD-035: Laws are library declarations checked by a finite-model engine

`law`, `instance`, and `model` are ordinary contextual top-level
declarations. `Monad`, `Monoid`, `Functor`, `Applicative`, and `Semigroup`
are ordinary library identifiers; the compiler contains no branch for any
one family. Equations are data checked by a generic typed finite-model
evaluator inside a compile-time sandbox with explicit case/step/allocation
budgets, and evidence carries one of three distinct assurance levels —
`bounded-exhaustive`, `proven-finite`, `proven` — none of which is granted
by a passing sample alone.

A privileged `monad` keyword is rejected: it freezes one family's equations
into the compiler and gives other algebras nothing. Blocking on full
higher-kinded types is rejected: concrete finite instantiations
(`Optional[Bool]`, a bounded `Int` monoid) deliver a checkable engine first,
and generic laws layer on later. Beginners never need this feature for
ordinary `Result` code.

[`docs/LAW_SYSTEM.md`](LAW_SYSTEM.md) is normative, including the
`kofun.law-evidence/v2` identity and sandbox contract.

## DD-036: Result propagation is postfix `?`, monomorphic to `Result`

One initial sequencing sugar: `expr?` on a `Result[T, E]` inside a function
returning `Result[U, E]` desugars after type resolution to the four-line
`match`-and-early-return core, with single evaluation, moved operand, and
unchanged effects. `T?` optionals do not propagate — `?` on an optional is a
dedicated refusal suggesting `ok_or` — and a bare `?` on a pipeline stage is
refused with a parenthesize suggestion, which keeps the visual overlap with
DD-002's `T?` out of the diagnostics.

Gleam-style `use` flattening is rejected for v1 because its
captured-continuation desugaring carries the heaviest ownership/debugger
burden; a lawful generic bind statement is rejected for v1 because it would
block everyday errors on the DD-035 law engine; "no sugar" is rejected
because the most common error path stays a `flat_map` ladder. None of the
three is precluded later.

[`spec/result-propagation-v1.md`](../spec/result-propagation-v1.md) is
normative.

## DD-037: Streams are a library protocol with explicit demand

`Stream[T, E]` delivers serial `Next` signals bounded by explicit
`request(n)` credit and exactly one terminal `Error`/`Complete`;
`Subscription` is an affine handle whose cancellation is idempotent, prompt,
and resource-releasing. Sources are cold by default; hot fan-out and replay
are explicit adapters that demand a bounded buffer policy (`wait`,
`drop_oldest`, `drop_newest`, `coalesce`, `fail`). No reactive keyword
enters the language, no scheduler is ambient, and `flat_map` claims no
Monad law until the observation model prices in timing, demand, and
cancellation. There is no `Signal[T]` in v1 — a held current value over a
stream must first prove insufficient.

Unbounded channels as the composition story are rejected: without a demand
contract every queue is a latent leak. A ReactiveX-scale catalog and
continuous-time FRP are rejected as v1 surface.

[`docs/stdlib/stream-protocol.md`](stdlib/stream-protocol.md) is normative.

## DD-038: The standard library ships in four tiers

The prelude (essentials, no authority), the portable standard library
(toolchain-versioned, edition-compatible), platform adapters (explicit
target support, typed build-time refusal elsewhere), and official
independently versioned modules (HTTP/TLS, time-zone data, frameworks —
security updates never wait for a compiler release). Coverage is governed
by the machine-checked matrix `stdlib/capabilities.tsv` with states
`implemented`/`specified`/`planned`/`deferred`/`non-goal`, gated by
`sh stdlib/check-capabilities.sh` (`task capabilities`); an open planning
issue is never implementation evidence. YAML is a first-party non-goal;
the HTTP client, date/time, and benchmark harness contracts are the first
rows to move from `planned` to `specified`.

A Go-shaped monolith is rejected because security-critical data cannot wait
for compiler releases; a Rust-shaped minimal core is rejected because
ordinary work would immediately require unvetted dependencies; a
scripting-shaped implicit prelude is rejected because it grants ambient
authority.

[`docs/STANDARD_LIBRARY_CHARTER.md`](STANDARD_LIBRARY_CHARTER.md) is
normative.

## DD-039: The HTTP client is bounded, capability-explicit, HTTP/1.1 first

An independently versioned official module: affine `Client`-owned pooling,
stream-protocol bodies with
caller limits on every read, redirects off by default with typed
method/body rewriting when enabled, proxies only from explicit
configuration, DNS/sockets behind the `Network` capability, and TLS behind
a `TlsProvider` interface that is secure by default and takes root-store
updates on its own channel. Conformance runs only against local
deterministic transports, including smuggling-shaped and
decompression-bomb negatives.

Wrapping libcurl is rejected for its ambient-authority surface;
implementing TLS from scratch is rejected as a v1 liability; HTTP/2-first
is rejected until the HTTP/1.1 core has conformance evidence.

[`docs/stdlib/http-client.md`](stdlib/http-client.md) is normative.

## DD-040: Time is six types; zones are versioned data; clocks are capabilities

`Duration` (64-bit nanoseconds, checked), unserializable `Monotonic`,
POSIX `Instant`, civil `Date`/`TimeOfDay`/`DateTime`, fixed `Offset`, and
`Zoned` carrying the tz-db version it resolved against. DST folds and gaps
take an explicit `Resolve` rule — there is no silent default. RFC 3339 is
the first parse/format profile; locale formatting is a non-goal. Clocks are
explicit platform-adapter capabilities with injected fakes in tests; IANA
tzdata is a pinned, independently versioned module artifact updated
independently of the compiler.

A single zone-optional `DateTime` is rejected on the accumulated evidence
of instant/civil confusion; silent fold disambiguation and
compiler-bundled tzdata are rejected as wrong-answer generators.

[`docs/stdlib/date-time.md`](stdlib/date-time.md) is normative.

## DD-041: Benchmarks are declared, raw-sample-first, and honest about counters

A portable `bench` API plus `kofun bench` runner: per-sample clock identity
(wall/process/monotonic can never be mislabeled), an explicit `consume`
anti-elision primitive, deterministic warmup/stop/summary rules, and a
versioned `kofun.bench-report/v1` that always retains raw samples,
toolchain/source/host identity, and harness overhead. Missing counters are
the explicit value `unavailable`, outliers are flagged never dropped, and
no single run may claim a significant speedup. #398/#476 stay the counter
providers behind this contract.

Shell timing as the public story, statistics over discarded samples,
privileged host tuning, and an embedded profiler are rejected.

[`docs/stdlib/benchmark.md`](stdlib/benchmark.md) is normative.
