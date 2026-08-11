# RFC-0017: Rank-1 generics use static dictionaries, source-free KIF v3, and a small proof kernel

- Shepherd: hjosugi
- Opened: 2026-08-11
- Status: accepted
- Decided: 2026-08-11

This RFC jointly decides
[#1265](https://github.com/kofun-lang/kofun/issues/1265),
[#1266](https://github.com/kofun-lang/kofun/issues/1266), and
[#1267](https://github.com/kofun-lang/kofun/issues/1267). The three decisions
share identity, separate-compilation, dictionary, and proof inputs and are
recorded together so their implementations cannot invent incompatible ABIs.
Production compiler/backend work remains in #1268-#1280.

## Summary

Kofun generics v1 uses explicit rank-1 type applications, invariant nominal
constructed types, per-concrete C11 value/function specialization, and static
dictionary parameters for trait bounds. Runtime instance search and erased
value fallback are forbidden. Dictionary passing is source semantics;
monomorphic and deterministic hybrid lowering are optional equivalent
optimizations.

Separate compilation uses a new `kofun.kif/generics-v3` envelope containing
canonical type binders/TypeRefs, generic declarations, trait/implementation/
dictionary facts, and normalized typed body templates. Dependencies are
consumed with source absent. KIF v1/v2 bytes and readers are unchanged.

Generic law evidence uses an alpha-normalized pure typed-Core proposition and
an explicit certificate. Proof search/production is untrusted. Only a bounded,
deterministic decoder/checker can emit assurance `proven`. The first theorem is
generic `Result.map(identity)`: it quantifies over arbitrary payload and error
types and therefore cannot be replaced by finite ground enumeration.

## Motivation

The existing generic and trait checkpoints establish useful identities but stop
before production layout, execution, or interfaces. Choosing specialization
without dictionary semantics would make optimization decide typing. Shipping
source text in packages would make interface identity path- and parser-
dependent. Letting an SMT solver mark its own output `proven` would make a huge,
nondeterministic search engine part of the trusted computing base.

A systems-language toolchain that aims to replace Rust/Zig needs generics and
traits across real native builds, but it also needs reproducible builds and an
auditable proof boundary. This profile selects the smallest coherent slice.

## Detailed design

### 1. Source and execution profile

The profile is `kofun.generics-execution/v1`.

- Applications are explicit rank-1 `name[T]` or `Type[T]`. V1 has no generic
  argument inference, higher kinds, associated types, blanket implementations,
  negative implementations, or specialization semantics.
- The first product/function admits at most two type parameters. A declaration
  admits eight concrete instantiations, constructed nesting depth eight, two
  dictionary parameters, and two ordered method slots per dictionary.
- Type parameters are invariant. Admissible arguments are canonical primitive
  or nominal TypeRefs whose ownership/layout is available for the target.
- Aliases normalize before identity. Shadowing uses declaration-scoped binder
  identity; a display name never identifies a binder.
- A constructed nominal type has a distinct AggregateLayout for each canonical
  argument tuple. Direct or mutual by-value layout cycles fail before code or
  interface output. Reference-indirected recursion remains a later profile.
- Generic functions and nominal values specialize per concrete tuple on C11.
  There is no erased fallback for a representation-dependent value.
- A trait bound adds one immutable statically shaped dictionary parameter in
  bound order. Method slots follow declaration order fixed into the dictionary
  ABI, not source discovery or implementation order.
- The resolver selects exactly one coherent ImplementationId over the complete
  dependency graph before lowering. Runtime instance search is forbidden.

Dictionary passing is the mandatory semantic form. The three selectable
lowering modes are:

| Mode | Requirement |
|---|---|
| `dictionary` | retain the dictionary parameter and indirect static slot call; no direct-call substitution |
| `monomorphic` | specialize the same typed call and replace an exact selected slot with its implementation body |
| `hybrid` | apply a versioned deterministic rule over typed size/call-count facts; never timing, host state, or hash order |

Removing specialization cannot change type checking, ownership/effects,
ImplementationId, failures, side effects, or cleanup. Where generated code
differs, mode/profile enters artifact/cache identity but not source semantic
identity.

Generated symbols are at most 255 bytes. A symbol is a printable projection of
the stable instantiation ID plus a bounded hint; truncating the hint never
changes the ID.

### 2. Canonical identity algebra

Every preimage uses length framing: `frame(label, bytes)` is UTF-8 label length,
label bytes, value length, then value bytes, all lengths unsigned big-endian
64-bit. Concatenation without frames is forbidden. IDs are SHA-256 over an
ASCII domain plus framed fields.

| ID | Normative preimage |
|---|---|
| `TypeParameterId` | `kofun.type-parameter/v1`, owner DeclarationId, kind, ordinal |
| `ConstructedTypeId` | `kofun.constructed-type/v1`, declaration TypeId, ordered canonical TypeRefs |
| `FunctionInstantiationId` | `kofun.function-instantiation/v1`, FunctionId, ordered canonical TypeRefs, selected profile |
| `BoundId` | `kofun.trait-bound/v1`, owner declaration, ordinal, TraitId, canonical arguments/self TypeRef |
| `ImplementationId` | existing module identity inputs plus trait/self canonical TypeRefs, binder/constraint facts, coherence mode |
| `DictionaryAbiId` | `kofun.dictionary-abi/v1`, TraitId, ordered MethodIds and canonical signatures, ABI version |
| `DictionaryArgumentId` | BoundId, exact ImplementationId, DictionaryAbiId |
| `BackendSymbolId` | target ABI, FunctionInstantiationId or ConstructedTypeId, mode/version, runtime ABI |

Paths, spans, display names, source order, import/re-export order, hash-table
order, host addresses, and compiler process identity are excluded. Semantic
body/interface/compiler digests remain separate facts; one ID never does two
jobs.

### 3. Substitution, layout, ownership, and effects

Substitution is capture-avoiding over fields, ADT payloads, function parameters
and results, bounds, nested constructed TypeRefs, ownership kind, effect
summary, and cleanup plan. The typed template records the binder environment,
so source text is never reparsed.

Each concrete record/ADT tuple is classified through RFC-0004 and laid out by
AggregateLayout. An owned argument makes a containing instance owned wherever
the generic definition stores it. Copy/managed/owned constraints are checked
before backend work. Cleanup is specialized from the same substituted layout
and runs in the accepted reverse/variant order on every exit.

Effects are substituted facts, not re-inferred from emitted C. A dictionary
method's effect must fit the bound signature. Optional direct calls preserve
the dictionary-form effect and authority requirements exactly.

### 4. KIF generics v3 envelope

The new envelope name is `kofun.kif/generics-v3`. It does not extend or
reinterpret KIF v1/v2. Old readers reject the new required version; new readers
continue to parse v1/v2 under their exact old schemas and never project v3
generic facts into them.

After the common package/module/digest header, v3 records use
`kind:u16be`, `length:u32be`, then canonical payload bytes. Records sort by
stable semantic ID and kind tie-break, never declaration/import order. The
closed v3 record set is:

| Kind | Record | Required payload |
|---:|---|---|
| `0x0101` | `TypeBinder` | TypeParameterId, owner DeclarationId, kind, ordinal |
| `0x0102` | `ConstructedTypeRef` | ConstructedTypeId, declaration TypeId, ordered argument TypeRefs |
| `0x0103` | `GenericTypeDeclaration` | TypeId, visibility, binders, record/ADT shape, body-availability policy |
| `0x0104` | `GenericFunctionDeclaration` | FunctionId, visibility, binders, parameters/result/modes/effects, bounds, body availability |
| `0x0105` | `TraitDeclaration` | TraitId, owner PackageId, visibility, binders, ordered methods/laws |
| `0x0106` | `TraitMethod` | MethodId, TraitId, slot, canonical signature/effects/ownership |
| `0x0107` | `Implementation` | ImplementationId, owner, trait/self TypeRefs, binders/bounds, coherence key, visibility, method bodies |
| `0x0108` | `DictionaryAbi` | DictionaryAbiId, ABI version, ordered MethodId/signature slots |
| `0x0109` | `GenericBodyTemplate` | declaration ID, normalized typed Core, binder map, layout/effect/cleanup inputs, body digest |
| `0x010A` | `PublishedInstantiation` | instantiation ID, declaration, arguments, availability, artifact/body/ABI digests |
| `0x010B` | `GenericLawReference` | law/proposition IDs, required implementation/body/interface digests, evidence availability |

TypeRef is a canonical tagged graph:

```text
primitive(PrimitiveTypeId)
parameter(TypeParameterId)
nominal(TypeId, ordered TypeRef arguments)
constructed(ConstructedTypeId)
function(ordered parameter TypeRefs, result TypeRef, modes, effect summary)
```

Graph nodes are ID-addressed. Forward links are allowed; every link must close
before publication. A value cycle requiring infinite layout is rejected;
interface reference cycles are accepted only through an explicit ID edge and
within the declared strongly connected component.

The separate-compilation strategy is a normalized typed body template plus
optional provider-published closed instantiations. A consumer can type-check,
instantiate, select a dictionary, and lower with provider source deleted. A
consumer-created instantiation retains the provider declaration/body owner and
cannot mint visibility, coherence, or law authority.

Hidden/internal facts are retained only in the exact-package view. They cannot
satisfy an exported bound. Combining package graphs completes overlap checking
before selection; import order cannot choose a candidate.

Limits are 65,536 records, TypeRef depth 64, 65,536 text bytes per bounded text
field, 8 MiB per typed body, and 262,144 links. Unknown version/kind, duplicate
or missing IDs, invalid binders, dangling links, forbidden cycles, visibility
leaks, slot/ABI mismatch, digest mismatch, downgrade, replay into a different
package graph, cancellation, and limit overflow produce no artifact. Writes
are temporary-plus-atomic-rename after the full graph validates.

### 5. Generic propositions and proof obligations

The proposition profile is rank-1 quantification over type and value binders,
selected trait dictionaries, pure total typed Core, equality, conjunction, and
implication. Display names and spans are diagnostics only. Terms retain
canonical TypeRefs, TermIds, exact body/interface/compiler digests, and selected
ImplementationIds.

V1 refuses effects, unchecked partial primitives, opaque calls without an exact
previously proven rewrite, higher-rank/higher-kind binders, general recursion,
coinduction, quotient/extensional equality, and ambient solver axioms. Checked
Int operations may appear as Result values; a proposition may not pretend an
overflowing operation is total.

A `ProofObligationId` hashes the alpha-normalized proposition, binder kinds,
dictionary hypotheses, body/interface/compiler digests, requested assurance,
and kernel profile. Alpha renaming, path changes, and declaration/import order
preserve it; semantic/type/body/implementation changes alter it.

### 6. Certificate grammar and trusted checker

The certificate envelope is
`kofun.generic-proof-certificate/v1` and contains the obligation ID, kernel
profile, canonical node table, root node, and certificate digest. A node is one
of this closed rule set:

1. hypothesis;
2. reflexivity;
3. symmetry;
4. transitivity;
5. typed congruence for a named Core constructor;
6. typed beta reduction;
7. typed let reduction;
8. ADT case reduction over a constructor hypothesis; or
9. application of a named previously `proven` rewrite bound to its exact IDs
   and digests.

Every node states its typed conclusion and premise node IDs. The checker
reconstructs the rule result; it never trusts the stated conclusion. Nodes are
acyclic and canonical by ID. Reordering the serialized node table produces the
same normalized certificate/evidence bytes.

Definitional normalization is deterministic beta/let/case reduction under
explicit fuel. No recursive unfolding occurs in v1 certificates. Opaque calls
remain opaque unless rule 9 supplies a matching proven rewrite. Certificate
limits are 8 MiB, 100,000 nodes, depth 1,024, 1,000,000 rewrite/normalization
steps, and 65,536 text bytes. Limits are checked before unbounded allocation or
recursion.

The producer, proof search, SMT solver, and optimizer are untrusted. Only the
canonical decoder, typed rule checker, normalized obligation reconstruction,
and evidence encoder are trusted. They are deterministic and have no wall
clock, random seed, host path, network, filesystem, or environment input beyond
the explicitly supplied bytes.

On success the checker emits `kofun.law-evidence/generic-v3` with assurance
`proven`. `ProofId` commits to proposition, compiler, interface, every body,
every ImplementationId, certificate digest, and kernel profile. Existing
`bounded-exhaustive` and `proven-finite` v2 artifacts remain byte-identical and
can never substitute for or be upgraded to this result.

The first required theorem is:

```text
forall T: Type, E: Type, r: Result[T, E],
    Result.map[T, E, T](r, identity[T]) == r
```

Its certificate performs ADT case reduction for `Ok(value)` and `Err(error)`,
then typed beta and reflexivity. `T` and `E` remain arbitrary; enumerating Bool,
Int, or a bounded List specialization cannot discharge the obligation.

### 7. Failure taxonomy and counterfeit corpus

The checker distinguishes malformed envelope, unsupported version/rule,
ill-typed term, wrong obligation, wrong binder/kind, wrong proposition, wrong
ImplementationId, wrong body/interface/compiler/certificate digest, unavailable
body, invalid premise, rule mismatch, duplicate node, cycle, noncanonical order,
truncation/corruption, and budget exhaustion. Cancellation produces no evidence.

The adversarial corpus mutates every envelope field and rule family and includes
a valid ground specialization, a different dictionary implementation, a
different body with the same display name, a lower-assurance artifact, premise
reordering, node duplication, cycles, truncation, unknown versions, and every
budget edge. None can emit `proven`.

Parser/HIR/obligation work belongs to #1278. Decoder/checker/counterfeit work
belongs to #1279. A parser, producer, optimizer, or search engine has no API
that sets assurance `proven`.

## Semantics

Generic source semantics is the statically selected dictionary form. Concrete
layout specialization is required to represent values, while direct method
specialization is optional and observationally equivalent. KIF carries checked
meaning rather than source spelling, allowing source-free compilation without
moving declaration ownership.

`proven` means only that the trusted v1 checker derived the exact canonical
obligation from the supplied certificate under the bound identities/digests. It
does not mean a general theorem prover, termination checker, or mathematics
beyond the closed rule set exists.

## Diagnostics

Frontend/backend failures name the declaration, canonical bound/type tuple,
limit/profile, and source span. They sort candidates by stable ID and redact
hidden facts. A backend that lacks the profile refuses before output.

KIF and proof failures are artifact diagnostics with phase, record/node ID, and
failure class. They never repair from display text or source, never publish a
partial artifact, and never expose hidden declarations through candidate lists.

## Ownership and effects

Generic substitution carries RFC-0004 ownership kind and the checked effect
summary. Dictionary descriptors are immutable managed metadata; captured
method state follows the selected implementation's declared ownership. A
specialization cannot drop, duplicate, or hide an owned value differently from
the dictionary form.

Proof propositions are pure. Certificate checking owns bounded decoder memory
and releases it on every failure/cancellation. Proof search may have arbitrary
effects outside the trusted boundary, but its bytes grant no authority until
the checker accepts them.

## Alternatives

Erasure/shared representation is rejected for v1 because records/ADTs have
argument-dependent layout. Monomorphization as source semantics is rejected
because it ties type checking and separate compilation to optimization.
Runtime instance search and ordered fallback are rejected because they destroy
coherence and reproducibility.

Publishing dependency source is rejected; KIF exists to carry checked meaning.
Publishing only closed instances is too restrictive for libraries, while a
shared ABI cannot represent all v1 values, so typed templates plus optional
closed instances are selected.

Trusting SMT/proof search is rejected. A much richer calculus, recursion, and
function extensionality are deferred until their soundness and resource model
can be audited.

## Drawbacks

The bounded profile admits only two parameters/eight instantiations/two slots
and requires a new KIF version. Typed templates increase interface size and put
more compiler logic in consumers. Per-concrete layouts can increase code size.
The proof kernel proves a deliberately small class and may require verbose
certificates.

## Compatibility and migration

Category: `additive`. Current production paths refuse the new generic/trait
shapes or stop before backend output. KIF v1/v2, const-generic identities,
standalone frontend goldens, self-host fixed point, and law-evidence v2 remain
unchanged. No old artifact is reinterpreted as v3.

## Implementation plan

The authoritative child DAG is #1268-#1280:

1. production generic nominal/function HIR and C11 concrete layouts;
2. trait HIR, dictionaries, and bounded calls;
3. KIF v3 codec/model, then production producer/resolver;
4. dictionary/monomorphic/hybrid modes and reproducible measurements;
5. generic obligation HIR/evidence envelope;
6. trusted proof decoder/checker and counterfeit corpus; and
7. one integrated production matrix, cleanup, capability truth, and release
   evidence.

Each child consumes these IDs/ABIs and may not invent a second profile.

## Validation

Focused contract gates are:

- `task generics-execution-profile`;
- `task kif-generics-profile`;
- `task generic-proof-kernel-profile`; and
- the existing generics, traits, dictionary, KIF, module identity/visibility,
  law/evidence, AggregateLayout, ownership, RFC, repository, and full verify
  gates.

The model mutates runtime search, target/KIF version, visibility/coherence,
trusted-producer status, identity inputs, rules, and every fixed limit. The
production children add executable C11, source-absent, sanitizer, fuzz, O0/O2,
repeat/path/order, and counterfeit evidence.

## Unresolved questions

Inference, higher kinds, associated types, recursive generic values, dynamic
dispatch, blanket/negative implementations, specialization semantics, richer
proof calculi, recursive proofs, proof search, and cross-language generic ABIs
are future amendments. The v1 identity, static dictionary, KIF, and trusted
kernel boundaries are closed.
