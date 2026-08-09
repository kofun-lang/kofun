# RFC-0008: Type-level programming v2 — general type functions under a versioned fuel profile

- Shepherd: hjosugi
- Opened: 2026-08-09
- Review closed: 2026-08-09
- Decided: 2026-08-09
- Status: accepted

Proposal for [#1130](https://github.com/kofun-lang/kofun/issues/1130). This
document records target semantics only. No parser, reducer, or trace producer
implements it. Acceptance decides the semantics and nothing else: the
`kofun.type-reduction/general-v2` profile, the `general` modifier, the
`kofun.type-reduction-trace/v2` schema, and `E390`–`E393` are decided target
semantics with no implementation behind them, and `release/claims.json`
remains the authority on what the compiler can actually do.

Acceptance supersedes the rejection row in
[`spec/type-level-programming-v1.md`](../spec/type-level-programming-v1.md)
for the general class only. That supersession is recorded as ledger amendment
`DD-031/A01` rather than as an edit to the decision text, so a reader of
DD-031 sees the semantics moved instead of reading a superseded sentence as
current. Everything the row rejects outside the general class — anonymous
conditional, mapped, and inferred type expressions — is untouched by this
proposal and stays rejected.

This is one half of the decision split recorded on #1130. This document owns
the **termination axis**: whether recursion whose measure is not a structural
subterm is admissible, and what bounds it. The **kind axis** — `Nat`,
`Symbol`, and `Bool` as type-level data — is
[RFC-0009](0009-type-level-kinds-v1.md), accepted for
[#1133](https://github.com/kofun-lang/kofun/issues/1133) on the same day as
this one, so the conditional passages below that ask "if RFC-0009 is also
accepted" all resolve to yes. Stated plainly, as
the #1130 analysis requires: **accepted alone, this proposal does not deliver
the typed router or the units library.** Those are kind-blocked first. What
this proposal alone delivers is the recursion class that no kind can:
fixpoint transformations, and descent on a measure that shrinks without being
a subterm.

## Summary

A `type fn` may opt out of structural termination by declaring
`type fn general`. A general declaration may recurse on constructed
arguments and may be mutually recursive with other general declarations. A
root reduction that can reach a general declaration runs under a new named
profile, `kofun.type-reduction/general-v2`, whose frame, step, and node
limits are fixed by this document — versioned language semantics, not
implementation settings. Exhausting a limit is a deterministic type error
that names the declaration, the limit, the measured counts, and the top
consumers. The unmarked `type fn` keeps every v1 rule and every v1 guarantee,
checked exactly as before, and a structural declaration cannot reach a
general one, so the old guarantee stays compositional rather than becoming a
comment.

## Motivation

V1 selects structurally terminating type functions, and the audit merged as
[#1131](https://github.com/kofun-lang/kofun/issues/1131) made the three
surfaces describing that profile say what is decided, what is implemented
(nothing), and what is under challenge (#1130). This document is the
challenge's design.

What structural termination removes is the recursion class where the
decreasing measure is not a subterm: iterate-to-fixpoint transformations,
`gcd`/division-style descent, worklist passes over nominal graphs, and —
once RFC-0009 exists — every string or numeric algorithm whose remainder is
recomputed rather than peeled. Measured against the restated corpus in
[kofun-lang/kofun-type-challenges](https://github.com/kofun-lang/kofun-type-challenges),
this class is concentrated in the `hard` and `extreme` tiers; the `medium`
tier is mostly kind-blocked and is RFC-0009's evidence, not this document's.

The precedent evidence, stated the way the #1130 analysis corrected it: GHC
and TypeScript are not testimony for unbounded type computation. GHC
termination-checks type families, spells the opt-out `UndecidableInstances`,
and keeps `-freduction-depth` (default 200) underneath it. TypeScript became
Turing-complete by accident, answered with an instantiation-depth limit and
`ts(2589)`, and then added tail-recursion elimination in 4.5 so the
well-behaved recursions fit under the limit. The settled practice is: admit
the recursion, bound it with a counter, report against the counter. Both
languages leave the counter implementation-defined; that is the one part
this design refuses to copy, because it is the part that actually forfeits
deterministic checking.

## Detailed design

### Cost classes

Every type-level function declaration has a **cost class**, written at the
declaration:

- **structural** — the unmarked `type fn`. Every v1 rule applies verbatim:
  acyclic call graph, direct self-recursion only on a strict matched subterm,
  the v1 validation sequence unchanged.
- **general** — `type fn general`.

```kofun
# structural: the checker proves descent, exactly as v1 states
type fn Flatten[T: Type] -> Type { ... }

# general: fuel-bounded, and the reader sees it at the declaration
type fn general Normalize[T: Type] -> Type { ... }
```

The design grammar changes one production of v1; everything else is
unchanged:

```text
type-function-declaration :=
    "type" "fn" ["general"] TypeName "[" type-parameter ("," type-parameter)* "]"
    "->" "Type" "{" type-match "}"
```

Class rules, checked statically before any reduction:

1. A structural declaration may call only structural declarations (`E391`).
2. A call-graph cycle is permitted only when every declaration on the cycle
   is general (`E392`). Acyclicity remains the law for structural
   declarations.
3. A general declaration keeps every other v1 form rule: named module-level
   declarations only, explicit kinds, exhaustive non-overlapping arms with at
   most one final `_`, no anonymous forms, no guards, no reflection, effects,
   or I/O. `general` changes the termination discipline and nothing else.

The cost class is part of the declaration's semantic cache identity.

### Root profile selection

A root reduction runs under `kofun.type-reduction/general-v2` if and only if
its statically resolved call graph reaches at least one general declaration.
Otherwise it runs under `kofun.type-reduction/default-v1` verbatim — same
limits, same guarantees, same trace schema. Rule 1 above is what makes the
old guarantee compositional: a structural root cannot reach a general
declaration, so "this root is structural" is decidable from the declaration
graph and means what v1 says it means.

RFC-0009 introduces a third profile, `kofun.type-reduction/kinds-v1`, for
structural roots that reach type-level data. If both proposals are accepted,
a root reaching both a data kind and a general declaration selects
general-v2, and the budget table below is deliberately **≥ kinds-v1 in every
dimension**, so widening the reachable graph never narrows the budget. If
RFC-0009 is not accepted, the two-profile rule in the previous paragraph is
the whole selection rule.

### The general-v2 budget

| Resource | default-v1 | general-v2 | Exact count |
| --- | ---: | ---: | --- |
| Active frames | 32 | 1,024 | entered alias/type-function frames not yet returned, after tail replacement |
| Logical steps | 256 | 1,048,576 | alias expansions plus fired type-function arms |
| Constructed logical nodes | 256 | 1,048,576 | nodes constructed during the root reduction |

The logical step and node definitions are v1's, unchanged, and they are
**open to other accepted proposals**: a form that another proposal defines as
charging a logical step charges it under every profile it is reachable from,
including this one. Concretely, if RFC-0009 is also accepted, a builtin
application is one step and one node here exactly as it is under kinds-v1. A
step-charging form that were free under one profile and charged under another
would make the same reduction produce two different traces. Limits are
checked before entering frame 1,025, performing step 1,048,577, or
constructing node 1,048,577. There is no command-line, manifest,
source-language, editor, or environment option that raises a limit — v1's
sentence, kept deliberately, because under this design the budget is
observable semantics: a legitimate program can be refused for exhausting it,
so the numbers belong to the named profile and version with the language.
Changing a number is a new profile name and a reviewed language change. Two
conforming compilers accept and refuse exactly the same programs.

The frame number is the one worth deriving, because with tail replacement it
bounds only *non-tail* nesting: a recursion whose call sits inside a
constructed result grows the stack by one per level, so 1,024 is the depth of
such a recursion this profile admits. Deeper than that, an author rewrites in
accumulator-passing style and is bounded by steps instead. The step and node
numbers are the same power-of-two ceiling, sized so that the per-level work
of a 1,024-deep transformation has three orders of magnitude of headroom.

Crossing a limit is a deterministic type error (`E390`). It must never
produce `Any`, an unknown type, a partial type, a successful interface, an
object file, or a cacheable successful result.

### Tail calls and frame accounting

When the entire result expression of a fired arm is a single type-function
call, entering the callee **replaces** the current frame rather than
stacking on it, and the active-frame count does not grow. This rule is
normative, not an optimization, because frame counts are observable — they
decide `E390`. Steps are still charged. This is TypeScript 4.5's lesson made
deterministic: an accumulator-shaped recursion is bounded by steps, not by
depth, so the frame limit binds only genuinely nested expansion.

If RFC-0009 is also accepted, a result expression that is a single builtin
application is a tail call under the same rule, and RFC-0009 states it in
that form for its own profile. Nothing else about the rule differs between
the two profiles.

### Cycle detection

Cycle detection is mandatory and is not charged as steps, as in v1. A
**state** is a declaration identity together with its fully reduced
arguments. The reducer is pure, so re-entering a live state can only repeat
forever. Entering a declaration is therefore tested, *before* any frame
replacement, against two sets:

1. the **active frames**, and
2. the **tail witness ring of the frame being replaced** — the 64 most
   recent states that frame has been replaced *into*, in entry order,
   evicting oldest-first.

A match in either is a definite cycle, refused immediately as `E393` without
burning the remaining fuel.

The ring belongs to the frame, not to the root: a tail chain is one frame
replaced over and over, so its ring is that chain's history. A frame pushed
by an ordinary stacking call starts with an empty ring, and when a frame
returns its ring is discarded with it. That is what keeps the test to
**live** states, which is the whole justification for treating a repeat as
definite. A ring that outlived its chain would refuse an honest program: a
declaration that tail-calls `Q[Int]`, returns, and is then called a second
time from the same enclosing arm reaches `Q[Int]` twice, and neither
occurrence is a cycle.

The ring exists because tail replacement and cycle detection would otherwise
defeat each other: a two-declaration tail loop `A[T] => B[T]`,
`B[T] => A[T]` keeps exactly one live frame, so an active-stack-only test
would never see the repeat. A genuine tail cycle never returns, so it never
discards its ring.

The resulting boundary is exact, and worth tracing once because it is
observable:

- **Period 1** — a self tail call with unchanged arguments. The caller's
  frame is still active when the test runs, so it is caught on the *first*
  repeat.
- **Period 2 through 64.** Each state is evicted only after 64 further
  entries, so on the *second* traversal the re-entered state is still in the
  ring and the cycle is caught there.
- **Period 65 and above.** By the time a state is re-entered, 64 later
  entries have evicted it, and every subsequent traversal repeats that. The
  cycle is never witnessed: it is bounded by fuel and reported as `E390`,
  not `E393`.

One construction detail decides the exact step, so a fixture must pin it.
The state a chain was *entered on* — the one the enclosing call stacked — is
never appended to the ring, and the chain's first replacement takes it off
the active frames, so by the time the cycle comes back around it is in
neither set. A cycle entered by a stacking call therefore witnesses at its
second state rather than its first, one entry later than the same cycle
entered by a tail call. Both witness on the second traversal; only the step
index differs.

That boundary is stated rather than hidden precisely because which of the
two codes fires is observable semantics — a conforming reducer must
reproduce this split, and the step count at which it fires, exactly. A ring
size chosen per implementation would make two compilers disagree on a
program's diagnostic.

So: fuel bounds progress that never repeats a state, or that repeats one too
far apart to witness; the cycle check bounds the repeats it can see, and
turns the common ones into an immediate, precise refusal.

### Attribution

During a general root's reduction the reducer maintains per-declaration
aggregates: arms fired and nodes constructed, keyed by declaration
`SymbolId`. The aggregates are a pure function of the logical step sequence,
so they are deterministic and cache-independent.

- The `E390` diagnostic renders the top eight declarations by steps,
  descending, with `SymbolId` bytes as the tie-break.
- The structured trace carries up to 64 aggregates in the same order, plus
  an explicit count of elided declarations.

This is what "diagnosable and attributable" means concretely: an exhaustion
at step 900,000 names which declarations spent the budget, not merely that
it is gone.

### Structured trace contract v2

`kofun.type-reduction-trace/v2` is a **new sibling schema to v1, jointly
defined by this proposal and RFC-0009**, with a schema file, validator, and
example vectors under
[`spec/type-reduction-trace/`](../spec/type-reduction-trace/). The two
proposals contribute disjoint field sets, and v2 lands containing the
contributions of whichever proposals are accepted — if this one is accepted
alone, v2 is v1 plus exactly the deltas below. Roots that reduce entirely
under default-v1 keep producing the v1 trace, byte for byte, under either
proposal.

The two structural changes v2 makes to v1's frame:

- `profile` and the limit record become **values rather than constants**. V1
  pins both to `default-v1`; v2 carries whichever profile the root selected
  and that profile's three limits, which is what lets one schema serve every
  profile beyond default-v1.
- **Bounded retention.** At most 256 step records are retained. When the
  reduction took at most 256 steps, all are retained and retention equals
  v1's. When it took more, the first 128 and last 128 are retained, and the
  root records the exact `elided_steps` count and the boundary indices. This
  supersedes, for v2 roots only, v1's every-step retention sentence and its
  requirement that `cumulative_steps` equal the record index — it is the
  trace cap independent of the fuel budget that #1130 asks for.

This proposal's own field contributions:

- each step record carries a `cost_class` — the fired declaration's class,
  or `builtin` on a `builtin-application` record if RFC-0009 is also
  accepted — and `tail: true` when the frame was entered by tail
  replacement, so a reader can see which discipline each frame was under;
- the root carries the `step_attribution` aggregates described above, keyed
  by declaration `SymbolId` or, for builtin steps, by builtin name.

RFC-0009 contributes the `builtin-application` step discriminant and the
data-kind value forms; this document does not define them, and a v2 producer
built from this proposal alone never emits them.

`authoritative: false`, the canonical JSON byte rules, and the 4 MiB cap are
unchanged — and with retention statically bounded at 256 records the cap is
now satisfiable by construction rather than by producer failure.

### Rendering budgets

Unchanged from v1: type displays and diagnostics are at most 4,096 UTF-8
bytes; a rendered diagnostic shows at most eight trace frames, the first
four and last four, with the exact omitted count. An error at step 900,000
renders eight frames and the attribution table within the same budget.

### What v2 still refuses

Everything in v1's rejected-forms list except the two recursion rules this
document changes: anonymous conditional types and `infer` chains; mapped and
template-literal types; type lambdas and higher-kinded parameters (still
deferred, exactly as DD-031 records); implicit union distribution; match
guards, overlapping arms, a misplaced `_`; user-supplied fuel or any option
raising a limit; value reflection, effects, clocks, randomness, and every
form of I/O; and implicit invocation of trait, law, refinement,
associated-type, const, or shape solvers. V2 changes the termination
discipline of named forms. It does not admit an expression language.

### The v1 review checklist

[`spec/type-level-programming-v1.md`](../spec/type-level-programming-v1.md)
requires every type-system RFC to answer ten items:

| # | Item | Where |
| --- | --- | --- |
| 1 | name, owner, kinds, grammar delta | Cost classes; profile `kofun.type-reduction/general-v2`; kinds unchanged |
| 2 | why v1 forms are insufficient | Motivation: the non-structural recursion class |
| 3 | termination proof and accounting | Semantics: fuel is the proof; the budget table plus the tail rule is the accounting |
| 4 | deterministic evaluation and cache identity | Root profile selection; cost class in cache identity; v1 reduction order unchanged |
| 5 | named rendering | Rendering budgets: v1 rules unchanged |
| 6 | new trace records or schema | Trace contract v2 |
| 7 | executable vectors | Validation |
| 8 | CLI/LSP/debugger consumers | same structured facts; `kofun type eval`/`explain` unchanged in shape |
| 9 | maximum diagnostic and trace sizes | 4,096 bytes and 4 MiB, unchanged |
| 10 | compatibility and migration | Compatibility and migration |

## Semantics

The trade this document makes, stated the way the #1130 analysis corrected
it: **a fuel-bounded reducer terminates.** Every general reduction ends in
at most 1,048,576 steps. Checking under v2 is decidable and deterministic.
What v2 gives up is different: a legitimate program can be refused for
exhausting the budget, which makes the budget part of the language's
observable semantics rather than an implementation detail. That is why the
numbers above are profile constants that change only with a profile name,
never per compiler, per invocation, or per environment. The tail rule and
the 64-state tail witness ring are semantics for the same reason: both change
which programs are accepted and which code refuses them.

The meaning of a program under v2:

- a structural root means exactly what v1 says, including its limits;
- a general root either reduces to the normal form every conforming reducer
  finds, or is refused as `E390` or `E393` with identical structured facts
  everywhere.

Memoization and interning remain physical-only, as v1 states: a cache hit
must reproduce the same logical counts, selected arms, result bytes, and
trace bytes as a cold reduction. Cross-root sharing is implementation
freedom bounded by that rule.

Deliberately left undefined: whether the v2 constants are adequate for the
corpus's `extreme` tier is a measurement, not an assertion — see Unresolved
questions — and nothing else.

## Diagnostics

| Code | Refusal | What the message names |
| --- | --- | --- |
| `E390` | a general-v2 limit crossed | which limit; measured frames, steps, and nodes; all three limits; the last declaration, arm index, and span; the top-eight step attribution |
| `E391` | a structural declaration calls a general declaration | both identities and spans, and the remedy: mark the caller `general` or remove the call |
| `E392` | a call-graph cycle with a non-general member | the cycle in canonical identity order and each non-general member on it |
| `E393` | a definite reduction cycle | the repeating declaration and its arguments in named form, whether it was witnessed on the active stack or in the tail witness ring, and the cycle's members |

`E394`–`E401` belong to RFC-0009. `E402`+ are unclaimed.

## Ownership and effects

No interaction. Type-level reduction is pure and produces types and
diagnostics; it introduces no value, no affine resource, no
`read`/`edit`/`take` obligation, and no effect-row entry. This stays true by
construction because v2 keeps v1's rejection of value reflection and
effectful type computation.

## Alternatives

**Do nothing — v1 forever.** A real option, and cheaper than it looks
because RFC-0009 alone delivers the kind-blocked majority of the corpus
under structural termination. It is not chosen because the residue is real
— fixpoints and non-subterm measures admit no structural spelling at any
kind — and because #1130 would stand as a permanently open challenge to an
accepted decision, which the ledger is designed to refuse.

**Per-declaration numeric fuel** — the shape #1130 first sketched. Rejected:
budgets on declarations do not compose (a caller cannot sum its callees), the
numbers get copied between libraries as incantations, and the accounting
either nests unreviewably or loses to the root's budget and means nothing.
The declaration declares its *class*; the profile owns the *number*.

**Implementation-defined limits** — GHC's `-freduction-depth`, TypeScript's
internal depth. Rejected because the same source then checks under one
conforming compiler and fails under another. That, and not general
recursion, is where deterministic checking is genuinely lost; it is the
defect this design exists to avoid, so importing it as the mechanism would
concede the point.

**Raiseable limits** (CLI flag, manifest key, pragma). Rejected for v1's
reason, now sharper: the budget is semantics, and a knob makes a program's
meaning a property of its build environment.

**No tail replacement.** Simpler, and it would let cycle detection be an
active-stack test with no window. Rejected because it makes the frame limit
bind accumulator-passing recursions, which are the well-behaved ones —
TypeScript 4.5 added the same rule for the same reason.

**Growing builtin escape hatches instead** — admit no general recursion and
add builtin type functions per demanded pattern. Rejected: it relocates
Turing-completeness into an unversioned builtin surface, every new shape
waits on a compiler release, and RFC-0009 deliberately bounds its builtins
to constant-step data operations to keep them from becoming this.

## Drawbacks

The constants will be wrong for someone. 1,048,576 steps is generous for
routers and unit exponents and thin for the corpus's `extreme` tier;
revising a constant is a language version, which is slow by design. That
slowness is the price of the budget being semantics.

The 64-state tail witness ring is a visible seam. A four-declaration tail
loop is caught; a hundred-declaration one exhausts fuel and reports the less
precise code. Any finite ring has that boundary, and stating it is better
than an implementation-defined one, but it is a rule a reader must hold —
including its two smaller asymmetries: period 1 is witnessed on the active
frames rather than in the ring, and a cycle entered by a stacking call
witnesses one entry later than the same cycle entered by a tail call.

Class inflation is a social risk: authors may write `general` defensively,
eroding the structural guarantee callers read at declarations. Tooling can
prove a general body structural and report the demotion, but nothing in
this design forces it.

Elision is a real debugging cost. A defect at step 500,000 may fall inside
the elided window; the path back is the attribution table plus re-rooting a
suspect subterm through `kofun type eval`, and that is worse than reading a
complete trace.

Two trace schemas coexist until a separately reviewed transport change, and
every structured consumer grows a version switch.

## Compatibility and migration

**Additive.** No accepted program changes meaning and none stops compiling.
The surface does not parse today.

Compatibility query, run on `main@a654f7fe`:

```sh
git grep -nE '^type fn ' -- '*.kofun' | wc -l
```

returns `0` — no tracked Kofun source declares a type-level function, so no
program can observe the new class, the new profile, or the new schema. The
default-v1 profile, its trace schema, and every existing sidecar and
semantic-event format are untouched; trace v2 is a new schema name, not an
extension in place.

If this proposal is accepted, DD-031 gains a ledger amendment announcing
that its rejection row — "Turing-complete type programming, rejected as a
language goal" — is superseded for the general class by this document, and
the under-active-challenge pointers recorded by the #1131 audit flip to
pointing at the amendment. There is no migration action for any program
until an implementation enables the syntax.

## Implementation plan

In order, each independently reviewable and separately gated:

1. **Trace v2 schema, validator, and vectors** — success, exhaustion, and
   cycle examples under `spec/type-reduction-trace/`, with a
   dependency-free check gate. The contract is provable before any reducer
   exists, exactly as v1's was.
2. **The surface and its refusals.** Parse the `general` modifier, run the
   class validation, refuse `E391`/`E392`, and keep reduction itself
   refused. Fail-closed, mirroring the derive plan in RFC-0007.
3. **The structural reducer** — owned by v1/#657 as it already is; nothing
   in this document changes that obligation or its gates.
4. **The general reducer**: fuel accounting, tail replacement, the two-set
   cycle test, `E390`/`E393`, attribution, trace v2 production, and
   `kofun type eval`/`explain` over general roots.
5. **The conformance corpus.** Adopt kofun-lang/kofun-type-challenges as
   tracked evidence, recording per problem which of RFC-0008 and RFC-0009
   unblocks it, so each proposal's delivered value is measured rather than
   asserted.

Acceptance of this proposal is not a commitment to a schedule, and no
implementation child is created until it is accepted.

## Validation

| Gate | Proves |
| --- | --- |
| the v2 leg of `task type-reduction-trace` | the schema vectors validate, canonical bytes are stable, `profile` and the limit record carry the selected profile, and retention/elision arithmetic is exact |
| a future `task type-level` gate | a general function that exhausts the step budget is refused as `E390` with exact counts and attribution; a warm-cache rerun produces byte-identical trace and diagnostic |
| the same gate's refusal corpus | `E391` and `E392` fire statically with both identities; `E393` fires without consuming the remaining fuel, for a self-tail cycle on its first repeat and for a two-declaration tail cycle on its second traversal |
| the same gate's ring-lifetime fixture | an arm whose result constructs two applications of a declaration that tail-calls one shared callee reduces successfully — the ring dies with its frame, so a repeated but dead state is not a cycle |
| the same gate's ring-boundary fixtures | a period-64 tail cycle entered by a tail call reports `E393` at the step the second traversal re-enters its first state; the same cycle entered by a stacking call reports it one entry later; a period-65 cycle exhausts fuel and reports `E390` — the stated seam on both sides and its one construction dependence, executable, so none of it can drift into an implementation detail |
| the same gate's structural leg | a structural root still binds to the v1 limits — 33 frames or 257 steps stays refused exactly as v1 states |

The negative fixture that bounds the claim is the pair:

```kofun
type fn general Loop[T: Type] -> Type { match T { _ => Loop[T] } }
type fn         Loop2[T: Type] -> Type { match T { _ => Loop2[T] } }
```

The first is admitted statically and refused at reduction as `E393` — the
call is in tail position, and because the cycle test runs before the
replacement it is caught at the first repeat, without burning fuel. The
second is refused statically by v1's strict-subterm rule, unchanged. The
pair proves the classes stay separate: `general` buys a bounded runtime
verdict, never a silent pass.

## Unresolved questions

**Are 1,024 frames and 2²⁰ steps/nodes the right constants?** Settled by
running the adopted corpus on the first general reducer before review
closes; the numbers freeze at acceptance and change afterward only as
`general-v3`.

**Is 64 the right tail witness ring size?** Same measurement: the corpus says
what cycle periods real mistakes have. It is semantics either way, so it
freezes with the rest.

**Do default-v1 roots eventually migrate to trace v2 so consumers hold one
schema?** Settled by the first structured consumer beyond the CLI — the LSP
work — as a separately reviewed transport change; this document deliberately
does not decide it.

**Is a "provably structural, consider demoting" tooling report worth a
gate?** Settled by whether class inflation is actually observed while
porting the corpus.

Every other question this proposal raises is answered above.
