# stdlib/alloc

The canonical allocator contract, and nothing that grants authority.

`alloc.kofun` is the source of truth for the allocator vocabulary: `AllocError`,
`AllocKind`, `Arena`, `AllocAuthority`, `AllocDecision`, the decision functions
over them, and the scripted failing allocator. This is stage 1 of
[RFC-0001](../../rfcs/0001-allocator-capability.md)'s implementation plan.

## What is here, and what is deliberately not

Nothing in this directory allocates. `alloc_decide` answers *"would this request
be admitted, and if not why"* as a value, so the policy is testable before any
runtime exists to enforce it.

Stages 2 through 6 of the RFC own what is absent, and the gate refuses each of
them appearing here:

| Absent | Owned by |
|---|---|
| the `alloc` effect label and its inference | stage 2 |
| `with` scope parsing, the supply rule, and `E343` | stage 3 |
| region tagging and `E340`/`E341` | stage 4 |
| adoption and its measurements | stage 5 |
| the no-GC profile gate `E342` | stage 6 |

There is no allocator capability claim in `release/claims.json`, and this seed
does not add one. A seed that granted authority would make the stage boundary
decorative.

## Three roles at three layers

An allocator is not one thing, and collapsing the three is what the vocabulary
here prevents:

- **the arena** is an owned resource with deterministic cleanup;
- **the authority** is an affine capability naming *which* arena it admits
  requests to;
- **the kind** is what policy that arena implements.

`AllocAuthority` carries the arena it names and a generation. Presenting an
authority for one arena to another is `WrongAllocator` rather than an unchecked
coincidence, and a copy kept past a transition is at a dead generation — the
same shape `stdlib/clock`'s handle uses and the one #784 decided for resource
handles generally.

## Why the decision order is the reason order

`alloc_decide` checks a mismatched authority first, then a closed region, then
the budget. That order is the order of the reasons: a caller holding the wrong
capability has not asked *this* arena anything, and a closed region has no
budget to be within. Reordering them would produce a true refusal with the
wrong explanation.

The budget error depends on the kind, which is why `QuotaAlloc` exhaustion is
`QuotaExceeded` and every other kind's is `Exhausted`. A single error would
lose which policy refused the request.

`promote` moves a value out of an arena into the managed heap. A `FixedAlloc`
arena has no heap behind it, so promotion from one is `WrongAllocator` and not
`Exhausted`: the request names an operation this kind does not have, rather
than a budget it cannot meet.

## The projection, and why there are two files

The Stage 2 Core does not lower records or closed ADTs yet, so the canonical
contract above cannot execute. `tests/stdlib/alloc/alloc.kofun` is a projection
of the same decisions into the vocabulary the Core accepts today — Int
parameters and returns, no records, no ADTs, no loops, and no `&&` in an `if`
condition.

The projection keeps every decision the canonical surface makes and only spells
values differently. A refusal is a negative number carrying `-(error + 1)`
because the Core has no sum type; the canonical surface returns
`AllocDecision`.

`task alloc-contract` pins them against each other in both directions: a
decision declared on one surface and not the other fails the gate, which is
what keeps the projection from becoming a second contract as the Core grows.
When the Core reaches records and ADTs, the projection is deleted rather than
migrated.
