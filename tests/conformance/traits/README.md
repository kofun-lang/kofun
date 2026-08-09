# Bounded trait declaration and implementation frontend

Executable evidence for #332 and #923. `bootstrap/stage2/traits_frontend.c`
parses traits with one type parameter and any number of members, concrete
implementations supplying them, and generic functions carrying exactly one
explicit bound; it assigns
TraitId/MethodId/ImplementationId identities, elaborates the dictionary shape,
and emits typed IR.

Run:

```sh
sh tests/conformance/traits/run.sh
```

## Frontend-only boundary

The dictionary is elaborated; nothing below it is. Nothing is monomorphised, no
vtable is laid out, and no runtime search is emitted or implied — the gate
asserts the IR names no monomorphisation, vtable, or search, and that no
backend artifact is written. Executing an elaborated dictionary is a separate
follow-up, so this corpus is still evidence about typed IR and not about a
running program.

## What `foreign` means here

Cross-package loading is out of scope, so `foreign` is the synthetic stand-in
the issue calls for: it marks a trait or type declaration as belonging to
another package. It exists to make the #403 orphan rule testable in a single
file, and it is not proposed surface syntax.

`type A = B` is an alias. It is transparent for typing *and* for ownership, so
aliasing a foreign type never makes it local and never makes an implementation
admissible — `orphan_alias_ownership` pins that, and its diagnostic names the
type the alias resolves to rather than the alias.

## Identities

- `TraitId` carries the package provenance and the declaration name.
- `MethodId` is the TraitId plus the declaration-order slot.
- `ImplementationId` carries the ABI schema version, the package, the TraitId,
  the normalized concrete type arguments, the outer nominal self-type identity,
  and the implementation declaration.

## The elaborated dictionary (#923)

The typed IR is `kofun-traits-ir/v2`. Four record kinds were added, and every
v1 record kept its shape:

- `dictionary-descriptor` — one per declared trait: the ABI schema version, the
  TraitId, the slot count, and one `MethodId` per slot in declaration order.
  Every dictionary for that trait has this layout.
- `dictionary` — one per admissible implementation, with the
  `dictionary-entry` records that fill its slots. Each entry pairs the
  descriptor's slot `MethodId` with the implementation method that supplies it.
- `dictionary-parameter` — one per bound a generic function declares, in
  declaration order, recorded with the bound it discharges. `same` carries
  exactly one, for its `Equal[T]` bound.
- `dictionary-arguments` and `dictionary-parameter` on `call` — the dictionary a
  bounded call passes and the callee parameter it fills.

`method-call` gained `dictionary-parameter` and `method-slot`, so a trait method
call inside a generic body resolves to a (dictionary parameter, slot) pair
rather than through the bound alone.

### The DictionaryId is derived, not assigned

A `DictionaryId` is its `ImplementationId` with the `impl:` tag replaced by
`dictionary:` and the trailing `/decl=N` declaration ordinal dropped:

```
impl:abi1/package:local/trait:local:Equal/args=builtin:Int/self=builtin:Int/decl=0
dictionary:abi1/package:local/trait:local:Equal/args=builtin:Int/self=builtin:Int
```

Dropping the ordinal is the point. What remains is exactly the coherence key —
ABI version, package, trait, normalized arguments, self-type — which overlap
refusal already makes unique per admissible implementation. So unlike the
`ImplementationId`, a `DictionaryId` is unchanged by declaration order, and
`order_independence.kofun` compares the dictionary set and the dictionary each
call passes with no stripping at all.

The gate derives one field from the other and compares, rather than matching a
fixed string, so a dictionary that stopped agreeing with its implementation or
with the selection at its call site fails the gate.

## Resolution admits exactly one candidate

Overlap is refused where implementations are *declared*, not where they are
used, so no candidate set is ever ordered at a use site.
`order_independence.kofun` is the positive program with every implementation
declared in the opposite order; the gate compares the selected trait and
self-type of every call against the original and requires them to match, while
the declaration ordinals the identities carry do move. That is what makes
"import or source order never selects between candidates" an assertion rather
than a claim.

## Refusals

Every fixture with a `.stderr` golden is a refusal, and the gate asserts its
own list is the same size as the glob, so a fixture added without a gate entry
stops the build (DD-022). Elaboration runs last, only after every check has
passed, so none of these programs gets a dictionary: the gate requires each to
exit 1 with its exact diagnostic and to write no IR file at all.

| Fixture | Code | Refuses |
|---|---|---|
| `blanket_implementation` | E2S132 | a generic or blanket implementation |
| `default_method` | E2S132 | a default method body in a trait |
| `duplicate_trait` | E2S127 | two traits with the same name |
| `inherited_member_source` | E2S127 | a trait naming a supertrait as an inherited member source |
| `member_name_collision` | E2S127 | one normalized member name declared twice under one owner |
| `method_arity_mismatch` | E2S128 | an implementation with the wrong parameter count |
| `method_name_mismatch` | E2S127 | an implementation of a method the trait does not declare |
| `method_parameter_mismatch` | E2S128 | a parameter type that differs after substitution |
| `method_result_mismatch` | E2S128 | a result type that differs after substitution |
| `missing_implementation` | E2S129 | a bound with no candidate |
| `multiple_bounds` | E2S132 | a second bound |
| `orphan_alias_ownership` | E2S131 | an alias used to claim ownership |
| `orphan_both_foreign` | E2S131 | a foreign trait for a foreign type |
| `overlapping_implementation` | E2S130 | two implementations for one trait and self-type |
| `recursive_bound` | E2S132 | a bound whose argument is not the bounded parameter |
| `trait_arity_mismatch` | E2S127 | the wrong number of trait type arguments |
| `two_type_parameter_trait` | E2S132 | a trait with more than one type parameter |
| `unbounded_method_call` | E2S129 | a trait method called without a bound providing it |

The frontend owns `E2S127`–`E2S133`.

## The two member-scope fixtures are pinned current behaviour, not a rule

`member_name_collision` and `inherited_member_source` were added alongside
[RFC-0005](../../../rfcs/0005-trait-member-scope-closure.md), the #995 proposal
to close a trait member scope under direct declaration. **That proposal is under
review and is not accepted semantics**, so these fixtures assert nothing about
it. They record what this frontend does today, and each refuses in a scope that
is not the member scope:

- `member_name_collision` declares one normalized member name twice under one
  owner. #942 recorded that shape as refused by `E2S132` for carrying two
  methods. It is not — the parameter table is keyed by the trait rather than by
  the member, so the duplicate *parameter* is found first. The message names
  `left`, and names neither the colliding member nor its owning trait.
- `inherited_member_source` names a supertrait. No inheritance edge exists, so
  the clause is refused as punctuation and the message names a delimiter.

The gate asserts both of those facts positively *and* asserts that neither
message has started naming the member, the trait, or the inherited source — so
these goldens cannot be re-blessed into looking like member-scope diagnostics
without the assertions failing first.

If RFC-0005 is accepted after its review window closes, #942 owns replacing
these messages with member-scope diagnostics and relaxing the assertions that
currently require them to name nothing. Until then the fixtures stand as an
observation about the frontend and nothing more.
