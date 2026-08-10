# RFC-0010: A resource handle is an affine per-type protocol with a closed transition table

- Shepherd: hjosugi
- Opened: 2026-08-10
- Status: accepted
- Decided: 2026-08-10

Proposal for [#784](https://github.com/kofun-lang/kofun/issues/784), the
producer prerequisite named by [#644](https://github.com/kofun-lang/kofun/issues/644).
This proposal records target semantics only. No parser, checker, classifier,
diagnostic, backend, standard-library type, or release capability is
implemented by it, and `docs/MVP_IMPLEMENTED.md` continues to record general
ownership and law checking as `open` with "no active general pass".

Measured against `origin/main@43d53d38ef30ec5ef234eb976c3e39a7ae949bb5`.

## Summary

A resource whose state must not be duplicated is declared as an ordinary Kofun
type carrying a **generation token**, and its state machine is a closed table of
ordinary functions that each `take` the handle and return its successor. There
is no new keyword, no `own` domain, and no new compile-time diagnostic: a
transition consumes its handle, so a copy kept behind is refused by the move
checking that `spec/records-v1.md` already specifies, and a forged or foreign
transition that reaches the runtime is refused by one generation check.

`read` observes without consuming and cannot advance state. `write`, `drain`,
`close`, and `cancel` consume. Normal completion returns a successor handle and
the resource is reusable; **cancellation is terminal** and returns a copyable
summary only. Draining is the transition that converts an unfinished transport
into a reusable one, so "this resource may be reused" is a property the type
grants explicitly rather than one a caller infers.

For someone writing Kofun, the visible consequence is that a transport-shaped
API has exactly one live handle at every point in a program, and the compiler
already knows how to say so.

## Motivation

[#644](https://github.com/kofun-lang/kofun/issues/644)'s bounded HTTP client
needs a handle whose owned state cannot be duplicated across write, read,
drain, close, cancel, and reuse. Three bounded precedents exist and none of
them is that handle:

- **`task records`** executes whole-record moves through Stage 2 C11, binds and
  lowers `read` parameters, and rejects partial move (`E2S122`), double take,
  and use after move (`E2S123`). It is not a reusable resource-state protocol
  and defines no transition authority.
- **`task clock-adapters`** executes a type-specific affine clock handle and
  deterministic cancellation through the reference and C11 backends.
  `tests/stdlib/clock-adapters/README.md` names this issue as the open general
  affine-handle decision rather than pre-empting it.
- **`task affine-resumption`** provides an executable checker and model for
  one-shot continuation consume, transfer, drop, and escape refusal, with a
  runtime double-resume backstop. That contract deliberately does not define
  transport write/read/drain/close/reuse states.

The cost of leaving this undecided is that each new resource invents its own
answer. `stdlib/clock/adapters.kofun` already carries a generation token with a
comment explaining the rule; nothing says whether that is the language's
position or one module's habit. This proposal makes it the position.

## Detailed design

### The declaration

A resource handle is a nominal record with a generation field. No new surface:

```kofun
type Transport = {
    identity: TransportIdentity,
    generation: Int,
}
```

The generation is the affine token. An operation accepts only the live
generation and advances the handle to the next one, so a copy kept behind is at
a dead generation and every later use of it is a named refusal rather than a
second live owner. This is exactly the shape `stdlib/clock/adapters.kofun`
implements for `MonotonicClock` and `SystemClock`, and which
`docs/MEMORY_MODEL.md` records in its ownership table as "none; the type
carries it".

### The transition table

The table is declared on the type as ordinary functions. A transition consumes
the handle it is given and returns either a successor handle or a terminal
value:

| Transition | Consumes | Produces | Reuse after |
|---|---|---|---|
| `read` | no — observes | an observation | unchanged |
| `write` | yes | successor handle | yes |
| `drain` | yes | successor handle | yes |
| `close` | yes | copyable summary | no successor |
| `cancel` | yes | copyable summary | no successor |

The table is **closed**: a transition that is not in it does not exist for that
type. A type whose table a general ownership pass could not express is a defect
in that type's design, not an extension of this one.

### Terminal observation

`close` and `cancel` return a plain copyable summary value carrying the
observable outcome. The handle is gone. The summary is an ordinary managed
value and may be copied, stored, and returned freely.

## Semantics

A program is well-formed under this proposal when, at every point, at most one
live handle denotes one resource state.

- **Consumption.** `write`, `drain`, `close`, and `cancel` consume their handle.
  After the call the consumed binding is dead, exactly as `take record` makes a
  record binding dead in `spec/records-v1.md`.
- **Observation.** `read` borrows and may not advance the generation. A `read`
  that would change state is not a `read`.
- **Succession.** `write` and `drain` return a handle whose generation is the
  successor of the consumed one. No two live handles ever carry the same
  generation for one resource.
- **Termination.** `close` and `cancel` produce no successor. The resource has
  no live handle afterwards and cannot be reused through this type.
- **Reuse.** Reuse is available exactly when a successor handle exists.
  Normal completion yields one; cancellation does not. An unfinished transport
  becomes reusable only by `drain`; one that cannot be drained can only be
  closed.

Deliberately left undefined: what a *specific* transport does on a partially
drained body, how many bytes `drain` is permitted to discard, whether a summary
carries timing, and the behaviour of any transition across a thread boundary.
Those belong to the type that declares the table, not to this proposal.

## Diagnostics

This proposal adds **no new compile-time code**. That is a decision, not an
omission: the static half is already registered and owned.

| Situation | Refusal | Owner |
|---|---|---|
| use of a handle after a transition consumed it | `E2S123` | `tests/diagnostics/registry.tsv`, gate `records` |
| partial move of a handle field | `E2S122` | `tests/diagnostics/registry.tsv`, gate `records` |
| a transition reached with a dead generation | `EARH01` — new, runtime | the deciding change |

`EARH01` is the runtime backstop and the only new code. It takes the shape
`spec/effects/affine-resumption.md` already uses for `EAFR01`, and the shape
`stdlib/clock` uses for `StaleClockHandle`:

```
stderr: EARH01: affine resource handle already consumed\n
```

The backstop exists because a transport crosses a host boundary that a static
proof does not reach. Static checking is the contract; `EARH01` catches a
forged or foreign transition, and a program that only ever holds handles the
compiler gave it can never observe it.

## Ownership and effects

`read` is the borrowing mode and is the only transition that does not consume.
`take` is how every other transition receives its handle. `edit` is not used:
a transition that mutates in place would leave the original binding live, which
is the property this proposal exists to remove.

Against [RFC-0004](0004-ownership-kind-classification.md), accepted: a handle's
ownership kind is `Owned`, and RFC-0004's structural join already gives the
right answer for every composite built over one — a record, tuple, ADT payload,
or `Optional` containing a handle is itself owned, with no rule restated here.
This proposal decides *transition* authority, which RFC-0004 explicitly does
not; the two compose, and the kind half is RFC-0004's.

Against [RFC-0002](0002-environment-authority.md), accepted: obtaining a
resource is an authority question and is out of scope. This proposal says what
happens to a handle once held, not who may obtain one.

There is no interaction with the effect discipline. A transition's effects are
whatever the transport's own signature declares.

## Alternatives

**Extend the executable record move checker to one named resource type.**
Rejected. `validate_move_uses` in `bootstrap/stage2/compiler.kofun` is
deliberately source-order only, and its own comment names
[#915](https://github.com/kofun-lang/kofun/issues/915) and
[#922](https://github.com/kofun-lang/kofun/issues/922) as the owners of loops,
branches, and inferred moves, recording that "a binding moved on one path and
used on another is not proved safe here." A transport protocol needs `drain`
and `cancel`, which need loops and branches. This option would either wait on
#915/#922 or quietly widen a pass that documents its own limits.

**Make this the first slice of a general ownership pass.** Rejected. It
contradicts three published statements at once: `docs/MVP_IMPLEMENTED.md`
records general ownership and law checking as `open` with "no active general
pass"; `release/claims.json`'s `general-ownership-checking` says "There is no
general ownership or law pass. Only the narrow borrowed-`List` checkpoint is
claimed."; and `docs/ROADMAP.md` lists the MIR-based ownership checker as
unbuilt work. #784's own acceptance criteria forbid claiming a general pass.

**Do nothing.** Rejected. #644 stays blocked on a producer nobody may build,
and each new resource keeps inventing its own answer — which is how
`stdlib/clock`'s generation token became a working rule that no document was
willing to call the language's rule.

## Drawbacks

The table is per-type, so two transports state their own tables and nothing
mechanically checks that they agree. That is the price of not building a
general pass, and it is why the subsumption rule below is normative rather than
aspirational.

A generation token costs a field and a comparison per transition, and it is
observable: `Transport` is not `Copy`, and its generation is visible to anyone
who can read the record. A future general pass should be able to make the token
an implementation detail; this proposal cannot.

`EARH01` is a runtime failure in a language that prefers static refusal. It is
reachable only by handles the compiler did not produce, but it is reachable.

## Compatibility and migration

`none`. Nothing is implemented by this proposal, so no program changes meaning
and none stops compiling. The declaration shape it blesses — a nominal record
with an `Int` generation field, consumed and returned by ordinary functions —
is surface the language already has and that `stdlib/clock/adapters.kofun`
already uses. `E2S122` and `E2S123` keep their current meaning and messages,
and `EARH01` is reachable from no tracked program because no type declares a
transition table yet.

No migration is required. `stdlib/clock`'s existing handles already satisfy the
rule and are not restated by it.

## Implementation plan

The decision is separable from any schedule, and acceptance commits to none.
When it is built, the order is:

1. one declared handle type with its closed table, in the reference backend;
2. the same type executing through Stage 2 C11, since a reference-model result
   is not backend execution proof;
3. `EARH01` registered in `tests/diagnostics/registry.tsv` with an executable
   owner;
4. an adversarial fixture proving no transition produces two live owners;
5. a scripted fixture printing the terminal state and reuse decision after
   normal close and after cancel, with the two observations differing.

The static refusals need no compiler change and are not part of this order.

### Subsumption

The transition table is specified as a description of what a general ownership
pass would prove, not as a competing mechanism. When that pass lands, the
per-type table becomes redundant checking rather than contradicted checking,
and the type keeps its states as ordinary API. A table a general pass could not
express is a defect in this design.

## Validation

The gate is a new focused target named by the deciding change, holding the
positive transitions and the exact refusals. The boundary is proved negatively:
a fixture that reuses a dead generation must fail with `EARH01`, and a fixture
that uses a handle after a consuming transition must fail with `E2S123`.

The existing precedents stay green and are part of the gate set: `task records`,
`task clock-adapters`, `task affine-resumption`, `task diagnostics`,
`task release-claims`, and `task verify`.

This proposal records no `implementation` in the ledger, because nothing is
implemented. `release/claims.json` is not edited by it, and
`general-ownership-checking` keeps its current wording.

## Unresolved questions

Two, both owned elsewhere and neither blocking this decision:

- **#644's response-body stream projection is specified-only** — no stream
  operators, scheduler, or adapters exist, and its owner row is unfilled. The
  terminal-observation rule above must be checked against whichever issue owns
  that projection before a concrete transport's states are frozen. This
  proposal fixes the rule for handles in general; it does not fix `Response`'s
  table.
- **Whether the generation token survives a general ownership pass** as a
  visible field or becomes an implementation detail. Settled by that pass, not
  here.
