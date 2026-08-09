# RFC-0006: A module-level binding is language surface, and v1 is the immutable integer constant

- Shepherd: hjosugi
- Opened: 2026-08-05
- Status: accepted
- Decided: 2026-08-09

## Summary

`spec/grammar.ebnf` admits a binding at module level and Stage 2 refuses one
with `E2S02`. This RFC settles which of the two speaks for the language: the
grammar does. A module-level binding is intended surface, and `E2S02` on a
top-level `let` is an implementation gap rather than a statement about Kofun.

v1 admits exactly one shape — `let NAME = <integer literal>`, immutable,
`Int`-typed, internal to its compilation unit. Every other module-level binding
form the grammar's `let_stmt` production spells, including `let own`, `let mut`,
a non-`Int` type, and any initializer that is not a single integer literal,
stays refused, but is refused **by name** as a bounded v1 boundary rather than
by `E2S02`'s "expected top-level `fn` or `type`".

For someone writing Kofun this changes one thing that does not work today: a
plain integer constant beside the functions that read it starts compiling.

## Motivation

[#955](https://github.com/hjosugi/kofun/issues/955) is the decision, and
[#289](https://github.com/hjosugi/kofun/issues/289) cannot describe module
initialization order while it is undecided whether a module-level binding can
be written at all. The cost is not hypothetical, and it is not evenly spread:
it lands entirely on the standard library.

Measured on `main@2b7581ff`:

```text
$ git grep -lE '^let ' -- 'stdlib/**/*.kofun' | wc -l
15
$ git grep -cE '^let ' -- 'stdlib/**/*.kofun' | awk -F: '{s+=$2} END {print s}'
61
```

Fifteen canonical `stdlib/` sources carry sixty-one top-level `let`
declarations, and existing gates already treat those files as target-language
surfaces. They are not aspirational sketches — they are the standard library as
this repository writes it.

```text
$ cat toplevel_let.kofun
let PROT_READ = 1

fn main() -> Int {
    return PROT_READ
}

$ ./bin/kofun check toplevel_let.kofun
error[E2S02]: expected top-level `fn` or `type` at byte 0
```

So the repository is in a state where its own standard library is not in its own
language. Option 2 of #955 — narrowing the grammar to what Stage 2 accepts —
would make that permanent and require migrating or reclassifying all fifteen
sources first. This RFC chooses the other authority, because the grammar
describes the language the standard library is already written in.

## Detailed design

The grammar is unchanged. `declaration` already reaches `let_stmt` through
`statement`, and this RFC states that reachability is intended rather than an
oversight, so nothing in `spec/grammar.ebnf` is narrowed or widened here.

What v1 *implements* of that production is bounded:

```ebnf
module_constant = "let", identifier, "=", integer_literal ;
```

- **Immutable.** No `mut`. A module constant has no assignment form.
- **Not owned.** No `own`. v1 declares no module-level resource, so there is no
  module-scope affine value and no destruction order to specify.
- **`Int`-typed**, inferred from the literal. No annotation is admitted in v1,
  because an annotation that can only ever say `Int` is a syntax to support
  without a decision behind it.
- **Internal.** No visibility modifier, so a constant stays inside its
  compilation unit and adds nothing to KIF. Exported constants are a separate
  decision with a module-identity consequence, and v1 does not prejudge it.

A constant is visible to every function in its compilation unit regardless of
declaration order, so it may be declared after the functions that read it.

## Semantics

A module constant is **not a lexical binding**. Nothing in the scope HIR
resolves it, and it occupies no `BindingId`. It is a named integer whose value
is fixed at compile time and substituted at each use.

Two consequences follow, and both are deliberate:

- A function-local `let` of the same name **shadows** the constant inside that
  scope only. This is not a redefinition and not a refusal: the local is an
  ordinary lexical binding that happens to hide a name from an outer namespace,
  which is what every other shadowing case in Kofun already does.
- A constant and a function or type of the same name **collide**, because they
  share the module's declaration namespace. That is a refusal, not shadowing.

C11 lowering is one file-scope `static const int64_t` per constant.

Left deliberately undefined: initialization *order*, use-before-initialization,
and cyclic initialization. v1's initializer is a literal, so none of the three
is observable — a constant has no initialization step to order. Those questions
belong to #289 and become answerable only when an initializer can name another
declaration.

## Diagnostics

Three stable codes, each naming the constant it is about:

| Written | Code | Message |
|---|---|---|
| `let LIMIT = 1 + 2` | `E2S159` | ``module constant must be `let NAME = <integer literal>` `` |
| `let helper = 1` beside `fn helper()` | `E2S159` | ``module constant `helper` conflicts with a declaration of the same name`` |
| `let LIMIT = 1` twice | `E2S160` | ``duplicate module constant `LIMIT` `` |
| `let mut LIMIT = 1` | `E2S161` | ``module constant `LIMIT` cannot be `mut`; a top-level `let` is immutable`` |

`E2S159` covers both the initializer shape and the namespace collision because
both say the same thing to an author: this name cannot be a module constant
here. They are distinguished by the message and the span, not by the code.

The point of these three is that they replace `E2S02`. Under the current
compiler every module-level binding form gets "expected top-level `fn` or
`type`", which tells an author the declaration does not exist rather than which
part of it is unsupported. A refusal that names `mut` is actionable; `E2S02`
is not.

`let own NAME = ...` at module level has no code of its own in v1 and is
refused by `E2S159` as an initializer that is not a single integer literal. That
is honest but not informative, and it is recorded as an unresolved question
below rather than presented as a designed refusal.

## Ownership and effects

No interaction. v1 declares no module-level owned resource, so there is no
module-scope affine value to move, borrow or destroy, and no `read`/`edit`/`take`
obligation attaches to reading a constant. A constant is a compile-time integer,
which is `Copy`, so a use is not a move.

This is exactly why `own` is excluded from v1 rather than left to fall out of
the implementation: a module-level owned resource would need a destruction
order, and the destruction order of module-scope resources is a decision this
RFC does not make.

## Alternatives

**Do nothing.** The grammar and the compiler stay in contradiction, #289's
initialization row keeps its false premise, and the standard library keeps not
compiling. This is the status quo and it is the reason #955 exists.

**Option 2 of #955 — Stage 2 is authoritative.** Narrow `program` so it admits
only `fn` and `type`, and pin `E2S02` with a compile-fail fixture. This is
coherent and cheaper, and it was rejected because of what it costs elsewhere:
fifteen standard-library sources would have to be migrated or reclassified as
not-Kofun first, and the constants they declare (`PROT_READ`, error numbers,
byte limits) have no other spelling in the language today. Choosing it would
mean deciding that Kofun has no way to name an integer constant at module
scope, which is a larger language decision than the one #955 poses.

**Admit the full `let_stmt` production at module level.** Rejected for v1
because it pulls in `own` and `mut` — module-scope mutable state and
module-scope resource destruction — neither of which has a decision behind it.
An RFC that accepted them by inclusion rather than by argument would be
accepting them by accident.

**Make constants a distinct keyword, `const NAME = 1`.** Rejected because the
fifteen sources already write `let`, and because a second binding keyword needs
a reason beyond disambiguating a form the parser can already tell apart by
position.

## Drawbacks

`let` now means two related but distinct things depending on where it appears:
a lexical binding inside a function, a compile-time constant at module level.
A reader must know the position to know which. The shadowing rule makes this
visible in a way that could surprise — a local `let LIMIT` silently hides a
module `LIMIT` — and the compiler does not warn.

v1's boundaries are narrow enough that an author will hit them: no `Text`
constant, no `1 + 2`, no annotation. Each is a named refusal rather than a
misparse, which is the improvement, but three refusals is still three refusals.

Accepting the grammar as authoritative also means accepting that the rest of
`let_stmt` at module level is *unimplemented* rather than *not in the language*.
That is a larger outstanding surface than Option 2 would have left, and it will
draw further RFCs.

## Compatibility and migration

`additive`.

Every shape this RFC admits is currently `E2S02`, so no program that compiles
today changes meaning or stops compiling. The three diagnostics are new codes in
a free range; `E2S147` through `E2S157` are held by optional-construction,
const-generics, and the Text and List[Int] slices, and are untouched.

Corpus query:

```text
$ git grep -hE '^let ' -- '*.kofun' | wc -l
75
$ git grep -hE '^let ' -- '*.kofun' | grep -vcE '^let [A-Za-z_][A-Za-z0-9_]* = -?[0-9]+$'
2
```

Seventy-five top-level `let` declarations across twenty-three tracked `.kofun`
sources. Seventy-three are exactly `let NAME = <integer literal>` and are
admitted by v1. The two exceptions are `let mut LIMIT = 1` and
`let LIMIT = 1 + 2`, which are the refusal fixtures this slice adds — so no
tracked source outside the new fixtures needs migration.

## Implementation plan

Stage 2's C11 backend only. [#1008](https://github.com/hjosugi/kofun/issues/1008)
is the implementation owner for v1 and the named owner of #289's
`module/global initialization` row; [#1007](https://github.com/hjosugi/kofun/pull/1007)
is its candidate.

Acceptance of this RFC is not a commitment to a schedule, and it does not enable
anything on its own. The native and wasm32 backends are out of scope for v1 and
inherit nothing from it; a constant that never reaches them cannot break them.

Later slices, each needing its own decision rather than following from this one:
non-`Int` constant types, expression initializers, exported constants and their
KIF consequence, and any module-level `mut` or `own`.

## Validation

`task module-constants` — `tests/module-constants/check.sh` — is the gate.

It runs three accepted programs and five refusals. `values.kofun` covers
positive, negative and zero initializers; `ordering.kofun` places a constant
before, between and after a record and an enum, so a regression in any one of
the frontend's four top-level walkers fails the gate rather than surfacing later
as a confusing diagnostic about the declaration *next to* the constant; and
`shadowing.kofun` proves a function-local `let` hides the constant inside its
own scope only.

The negative fixture proving the boundary is `mutable.kofun`: `let mut LIMIT = 1`
must be refused with `E2S161` and must not be accepted as mutable module state.
`non_literal.kofun`, `function_clash.kofun`, `type_clash.kofun` and
`duplicate.kofun` pin the other four refusals to their exact codes.

The ledger's `implementation` record and the capability claims in
`release/claims.json` are written when the gate is green on the target branch,
not when this RFC is accepted.

## Unresolved questions

**`let own` at module level has no diagnostic of its own.** It falls into
`E2S159`, which reports a bad initializer for what is really an unsupported
ownership form. Settling it means deciding whether module-scope resources exist
at all, which is [RFC-0002](0002-environment-authority.md)'s and
[#569](https://github.com/hjosugi/kofun/issues/569)'s territory; until then a
dedicated code would be a refusal with nothing behind it.

**Whether a module constant should be exportable.** v1 says internal, which is
the conservative choice, but it means a constant cannot be shared between
compilation units and the standard library will want that. What would settle it
is a decision on whether a constant's *value* is part of module identity in KIF,
because that determines whether changing `1` to `2` is a breaking change to a
module's interface.

**Whether shadowing should warn.** A local `let LIMIT` hiding a module `LIMIT`
is legal and silent. This is consistent with the rest of Kofun's shadowing, and
inconsistent with the fact that the two are different kinds of thing. What would
settle it is evidence from real use, which does not exist yet.
