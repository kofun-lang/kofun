# RFC-0007: Derive v1 is a closed compiler-owned set, specified as the expansion a library derive would produce

- Shepherd: hjosugi
- Opened: 2026-08-09
- Status: proposed

Proposal for [#988](https://github.com/kofun-lang/kofun/issues/988). This
document records target semantics only. No expansion machinery, `kofun expand`
command, or derived member is implemented by it.

## Summary

`@derive(...)` in v1 names a member of a **closed set the compiler owns**. The
first member is `Eq` over concrete nominal records whose fields are `Int` or
`Bool`. `kofun expand` prints the expansion and its provenance from the day the
first derive lands, so no derived code is ever unreadable.

This is a deliberate, scoped exception to DD-013, which says `derive` is an
ordinary typed hygienic macro over a versioned public meta IR. The exception is
written to expire: every v1 member is specified as **the expansion a library
derive would produce**, so when the DD-013 system arrives each member becomes an
ordinary library derive with identical observable behaviour, and a member that
could not be written that way is a defect in this design rather than a licence
to keep it special.

For someone writing Kofun, one thing that does not work today starts working:
`@derive(eq)` on a record gives it structural equality without writing it out.

## Motivation

DD-013 is `accepted` and unimplemented. `bin/kofun` has no `expand` command;
`git grep -nw derive -- bootstrap/` finds only prose; and
`tests/security/generated-meta-access.sh` proves the current state is a
**fail-closed boundary** — `meta fn`, token macros, and `@derive` producers are
refused with exact diagnostics, publish no artifact, and disclose no private
authority.

So the choice is not between two implementations. It is between two orders of
work, and the orders differ in what they commit to before anything runs.

Taking DD-013 first means designing a **public, versioned meta IR with zero
users**: its schema, hygiene and collision rules, span mapping from call site to
generated declaration, expansion-stack diagnostics, deterministic ordering, and
the phase at which generated declarations are name-resolved, type-checked, and
ownership-checked — all before `@derive(eq)` produces one line. The first derive
is the best forcing function for what that IR must expose, and this order
removes it.

It also inverts the method every capability in this repository was built with.
Labelled calls went all-`Int` (#1097) then `Text`/`List[Int]` (#1107); Optional
went narrowing, construction, coalescing, pair; `List[Int]` went values then
signatures. Each was a bounded executable slice with its own gate. Derive is the
one subsystem with no slice at all, and starting it with a public interface
rather than a slice is the least like everything around it.

The closed set also has somewhere to generate *into*. `task
trait-dictionary-c11` executes a bounded `Equal[Int]` dictionary through C11,
and #1117 made a trait able to hold more than one member. A compiler-owned
`derive(Eq)` emits an implementation of an existing trait. A general macro
system emits into machinery that does not exist.

The cost of choosing wrong is asymmetric, and that is what decides it. A
documented exception is retired by amendment, and DD-013's own compatibility
record says that retirement is free today: category `none`, *"Nothing is
implemented, so no program changes meaning."* A published versioned interface is
not retired by amendment; it is carried. This order front-loads the cheap
mistake and defers the expensive one.

## Detailed design

### Surface

```ebnf
derive-attribute = "@derive", "(", derive-name, { ",", derive-name }, ")" ;
derive-name      = identifier ;
```

A derive attribute attaches to a `type` declaration and precedes it. Attaching
it anywhere else is refused.

```kofun
@derive(eq)
type Point { x: Int, y: Int }
```

### The closed set

v1 defines exactly one member.

| Name | Applies to | Generates |
|---|---|---|
| `eq` | a concrete nominal record whose fields are all `Int` or `Bool` | `impl Equal[T] for T` whose `equal` is the conjunction of field-wise equality, in declaration order |

An unknown derive name is refused by name. The set grows by amending this RFC,
never by a compiler change alone.

### The four subsumption requirements

These are normative, not aspirational. They are what keeps this from becoming a
second macro system, which is the failure #988 was written to prevent.

1. **Every member is specified as the expansion a library derive would
   produce.** The generated declaration is one an author could have written by
   hand, in ordinary Kofun, with no compiler-only construct. When the DD-013
   system lands, each member becomes a library derive with **identical
   observable behaviour** — same generated declaration, same diagnostics, same
   ordering.
2. **The projection `kofun expand` prints is the format the general system will
   print.** It is designed once, here, and not replaced later. A second
   provenance format arriving with the general system is the defect this
   requirement exists to refuse.
3. **Hygiene, generated-name collision, span mapping, and deterministic
   ordering are specified as general rules that happen to have one client.**
   They are not derive-specific behaviour.
4. **A compiler-owned derive that cannot be expressed as a library derive is a
   defect in this design.** It is not evidence that the member needs to stay
   special.

### `kofun expand`

```text
kofun expand SOURCE
```

prints every expansion in the file, in source order, each preceded by a
provenance header naming the derive, the type it was applied to, and the
projection version:

```text
-- derive(eq) for Point [kofun.derive-expansion/v1]
impl Equal[Point] for Point {
    fn equal(left: Point, right: Point) -> Bool {
        return left.x == right.x && left.y == right.y
    }
}
```

The output is **diagnostic, not normative**. It shows a reader what the compiler
generated; the normative artifact is the generated declaration as the compiler
sees it. Making the printed text normative would freeze a formatting contract
before the general system exists, which requirement 2 already forbids in the
other direction.

## Semantics

A generated declaration is an ordinary declaration. It is name-resolved,
type-checked, and ownership-checked **after expansion**, exactly as a
hand-written one, and it participates in coherence exactly as a hand-written
implementation does — so DD-032's one-implementation-per-resolved-key rule and
the orphan rule apply to it unchanged, and a hand-written implementation of the
same key collides with a derived one rather than silently losing to it.

Expansion happens once per attribute, before name resolution. Two derives on one
type expand in written order. The same derive named twice on one type is
refused rather than expanded twice.

Both the call site and the generated declaration carry spans, so a diagnostic
about generated code can point at either — the attribute a reader wrote, or the
declaration the compiler produced.

**Deliberately undefined in v1:** derives on anything other than a record;
derives that read other derives' output; conditional or parameterized derives;
any ordering guarantee between a derive and a hand-written declaration in the
same file beyond the two rules above.

## Diagnostics

| Code | Refusal | What the message names |
|---|---|---|
| `E380` | an unknown derive name | the name, that v1's set is closed, and the members it contains |
| `E381` | a derive applied to something other than a concrete nominal record | the target, and that v1 derives apply to records |
| `E382` | a derive whose requirements the target does not meet | the derive, the field that fails it, and why — for `eq`, a field whose type is not `Int` or `Bool` |
| `E383` | the same derive named twice on one type | the derive and both attribute spans |
| `E384` | a generated declaration colliding with an existing one | both declarations and both spans, in canonical order, with the remedy being to remove one |

`E385`–`E389` stay unallocated in this band. `E370`–`E372` are RFC-0005's,
`E390`–`E393` are RFC-0008's, `E394`–`E401` are RFC-0009's, and `E402`+ are
unclaimed.

## Ownership and effects

No interaction with `read`/`edit`/`take` beyond what the generated declaration
itself carries: `derive(eq)` generates a function taking two `read` parameters
and returning `Bool`, so it introduces no affine resource, no move, and no
effect row entry. A later member that generates something effectful states its
effect in this table when it is added.

## Alternatives

**DD-013 typed expansion first.** The alternative #988 names. It keeps the
ledger free of an exception and gives third-party derives immediately. It was
not chosen for the asymmetry in the Motivation: the exception is cheap to
retire and the published IR is not, and the first derive is the forcing function
this order would remove.

**Do nothing.** `@derive` stays fail-closed and records keep hand-written
equality. This costs nothing today and is a real option; it is not chosen
because the closed set is small, has an existing generation target, and its
absence is felt in the standard library first.

**A general macro system that is not DD-013's.** Rejected without analysis: two
accepted macro designs is worse than one accepted design with a recorded
exception.

## Drawbacks

The ledger gains an exception a reader must hold: DD-013 says one thing and
derive v1 does another for a bounded period. That is a real cost, and the four
requirements above are what bound it.

Third-party derives are blocked until the general system arrives. A library that
wants `derive(json)` waits.

There is a migration when the general system lands. Each member becomes a
library derive, and if any generated declaration differs even in spacing, a
program that depended on `kofun expand` output changes. Requirement 2 is what
keeps that migration to a re-homing rather than a rewrite.

## Compatibility and migration

**Additive.** No accepted program changes meaning and none stops compiling.
`@derive` is refused today by
`tests/security/generated-meta-access.sh`, so no program can be using it.

Compatibility query, run on `main@6b7c060f`:

```sh
git grep -c '@derive' -- '*.kofun' | wc -l
```

returns `0` — no tracked Kofun source uses the surface.

There is no migration action until an implementation enables the syntax.

## Implementation plan

In order, each independently reviewable and separately gated:

1. **The attribute surface and its refusals.** Parse `@derive(...)`, refuse
   `E380`–`E383`, and change nothing else. This can land while the expansion is
   still refused, and it replaces the current parse-level rejection with a
   named one.
2. **`derive(eq)` for `Int`/`Bool` records, plus `kofun expand`.** The first
   executable member and the projection, together, because requirement 2 makes
   them one design.
3. **`E384` collision checking against hand-written implementations.**
4. **Later members**, each an amendment to this RFC that adds a row to the
   closed set.

Acceptance of this proposal is not a commitment to a schedule, and no
implementation child is created until it is accepted.

## Validation

| Gate | Proves |
|---|---|
| `task derive` (new) | a record with `@derive(eq)` compiles, the generated implementation resolves through the existing dictionary path, and two values compare correctly through it |
| the same gate's refusal corpus | `E380`–`E384` each fire with their exact message, publish no artifact, and leave the source refused |
| `sh tests/security/generated-meta-access.sh` | `meta fn` and token macros stay fail-closed — this RFC opens `@derive` and nothing else |
| `task traits` | the generated implementation is an ordinary one: coherence and the orphan rule apply to it unchanged |
| `task verify` | repository regression |

The negative fixture that bounds the claim is a `@derive(eq)` on a record with a
`Text` field: refused as `E382` naming the field, with no generated declaration
and no artifact.

## Unresolved questions

**What `kofun expand` does with a file that has no derives.** Printing nothing
and printing the source unchanged are both defensible. Settled by the first
implementation slice, because it is the first point at which anyone runs it.

**Whether the closed set's second member is `Ord` or `Show`.** Not needed to
accept this proposal; settled by whichever the standard library reaches for
first, and added as an amendment.

Every other question this proposal raises is answered above.
