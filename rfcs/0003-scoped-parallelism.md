# RFC-0003: Scoped parallelism uses lexical spawn/join ownership

- Shepherd: hjosugi
- Opened: 2026-08-02
- Status: accepted
- Decided: 2026-08-09

Proposal for [#555](https://github.com/kofun-lang/kofun/issues/555). Review opened with the ledger's announced window; it closes when the
shepherd closes it, and the ledger records that day. This proposal
records target semantics only. Production parsing, checking, lowering,
scheduling, diagnostics, backend support, and release capability remain
unimplemented.

## Summary

Kofun v1 concurrency is a lexical `par` scope with second-class scope tokens
and affine task handles. A task is created only by calling `spawn` directly on
the scope token, and every task is joined before the `par` block exits. Existing
`read`/`edit`/`take` exclusivity is applied to all simultaneously live task and
parent accesses. Different named fields and statically disjoint half-open
slices can be edited in parallel; an unknown overlap fails closed. The promise
is data-race freedom, not scheduling determinism or race-condition freedom.

Detached tasks, channels, actors, behaviour-oriented concurrency, session
types, and `Send`/`Sync`-style traits are not implicit extensions of this
proposal. They require later RFCs if concrete needs appear.

## Motivation

[`docs/MEMORY_MODEL.md`](../docs/MEMORY_MODEL.md) already states three facts
that a concurrency proposal must preserve:

1. safe Kofun promises data-race freedom, never race-condition freedom;
2. ownership access uses `read`, `edit`, and `take` rather than first-class
   lifetime-bearing references;
3. scoped sibling work can reuse the existing exclusivity rule if spawned work
   cannot escape and the scope joins before exit.

Issue #555 previously left the unstructured-concurrency choice open. That made
the documentation useful research but not an implementation contract: a parser
author could not know the source forms, an ownership author could not know the
liveness interval, and a runtime author could not know whether an unused handle
detaches or drains.

The bounded contract and executable model at
[`spec/concurrency/scoped-parallelism-v1.md`](../spec/concurrency/scoped-parallelism-v1.md)
now make those choices concrete. This RFC records the public decision without
turning the model into evidence of a production implementation.

## Detailed design

### Source forms

V1 adds exactly these forms:

```ebnf
par-expression   = "par", "|", identifier, "|", block ;
spawn-expression = identifier, ".", "spawn", "(", lambda-expression, ")" ;
join-expression  = expression, ".", "join", "(", ")" ;
```

The identifier between bars is the lexical scope token. `spawn` is available
only as a direct operation on that token, and its argument is an ordinary Kofun
`fn` lambda. V1 adds no second closure spelling and no implicit parameter.

```kofun
par |scope| {
    let left = scope.spawn(fn() => total(read items, 0, split))
    let right = scope.spawn(fn() => total(read items, split, len(items)))
    left.join() + right.join()
}
```

Expressions retain source evaluation order. Each spawn argument and its
captures are established before that task begins. The v1 checker accepts a
finite lexical set of spawn sites. Loop spawning, recursive scope creation,
dynamic scope-token selection, and joining through an alias are unsupported
rather than inferred.

### Scope tokens and task handles

A scope token is a second-class compiler value that exists only inside its
`par` block. It cannot be returned, stored, captured, passed, serialized, or
compared. Each successful `spawn` creates one lexical task identity and one
second-class affine handle.

A task handle:

- belongs to one scope and cannot be copied;
- cannot be returned, stored, captured, passed, serialized, or used after its
  scope;
- may be explicitly joined at most once;
- yields its task result when an explicit join succeeds;
- is joined at scope exit if not explicitly joined; and
- discards its result when joined implicitly.

An unused handle therefore remains bounded work; it never denotes a detached
task. A compiler may warn that an implicit join discards a result, but it may
not reinterpret that case as detachment.

### Semantic liveness

A task's capture interval starts after its spawn completes. It ends when its
explicit join completes, or at the scope-exit join barrier if no explicit join
exists. Two intervals that overlap are simultaneously live for ownership
checking even if one chosen runtime schedule would finish a task sooner.

An explicit join ends that task's live `read` and `edit` captures. It does not
restore a place transferred with `take`. A transferred value can return only
as an explicit task result bound to a new place.

Parent accesses participate in the same liveness calculation. The parent may
read a place alongside task reads. It may not access a taken place, and it may
not perform an access that conflicts with a live task capture.

### Capture modes and conflicts

The checker derives captures from checked task bodies and resolved calls. V1
has no source-written capture list. Every captured place uses the existing
`read`, `edit`, or `take` mode.

For simultaneously live accesses to overlapping places:

| Left | Right | Decision |
| --- | --- | --- |
| `read` | `read` | accept |
| `read` | `edit` or `take` | reject |
| `edit` | `read`, `edit`, or `take` | reject |
| `take` | `read`, `edit`, or `take` | reject |

`take` also removes the original place at spawn. A later parent access or task
capture remains rejected after join unless the taking task explicitly returns
a value that is bound as a new place. There is no optional strict mode,
run-time ownership lock, unchecked escape hatch, or conformance trait that can
override this table.

### Place overlap

A place is a base binding followed by named-field and half-open slice
projections. V1 decides overlap only as follows:

1. Different base bindings are disjoint.
2. Two paths are disjoint when their first differing record projection names
   different fields.
3. Two slices of the same base are disjoint when all four bounds are statically
   known integers and either end is less than or equal to the other start.
4. Identical projections, a whole place and its projection, and intersecting
   known slices overlap.
5. Every other relation is unknown.

Empty half-open slices are disjoint. A statically known start greater than the
end is malformed, not an empty slice. Unknown overlap is accepted only for
`read` plus `read`; if either side is `edit` or `take`, it is rejected. No
runtime value, selected schedule, solver timeout, or profile data may turn an
unknown relation into a proof.

### Join, panic, and cancellation

A normal explicit join waits for its task and yields the result. Normal scope
exit joins every remaining handle, discards each unconsumed result, and exits
only after the join barrier completes.

A task panic begins scope unwinding: the scope requests cancellation of
unfinished siblings, joins every handle, performs ordinary cleanup, then
propagates a panic. If several tasks panic, the lexically earliest spawned
panicking task is primary and the remaining panics are related diagnostics;
runtime completion order cannot choose the primary failure.

Parent cancellation requests cancellation of unfinished tasks, joins every
handle, performs cleanup, then propagates cancellation. A task panic has
precedence over simultaneous cancellation. A task may observe cancellation
and return normally while the scope drains; the proposal promises the barrier,
not immediate interruption.

### Trace boundary

The ownership semantics expose only these logical anchors to the separate
trace/replay work in [#736](https://github.com/kofun-lang/kofun/issues/736):

- `scope.enter`
- `task.spawn`
- `task.join.explicit`
- `task.join.scope-exit`
- `scope.exit`

They identify lexical ownership transitions, not a runtime schedule. RFC-0003
does not define task start, yield, wake, worker selection, runnable-set order,
wall time, replay, or exploration. #736 owns those facts and may not use its
chosen schedule to change RFC-0003 ownership acceptance.

## Semantics

Evaluation of `par |scope| { body }` establishes a lexical join scope, evaluates
`body`, and cannot produce its result or propagate its failure until all task
handles have been joined. `scope.spawn(lambda)` creates a lexically identified
task after evaluating the lambda and establishing its checked captures.
`handle.join()` consumes the handle, waits for that task, ends its `read` and
`edit` capture interval, and yields its successful result.

Ownership acceptance is computed over semantic intervals, not task completion
times. A program is accepted only when every simultaneous parent/task and
task/task access either refers to a proven-disjoint place or satisfies the
`read`/`read` exception. A rejected ownership graph does not run.

Scope exit is a join barrier on every unconsumed handle. Panic and cancellation
select their primary outcome by the fixed precedence above and do not bypass
the barrier. The proposal deliberately does not specify worker count, fairness,
execution order between tasks, speedup, or a deterministic schedule.

## Diagnostics

The following stable semantic classes are required. A production diagnostic
registry may allocate user-facing compiler numbers, but must preserve these
meanings and deterministic precedence.

| Class | Required meaning |
| --- | --- |
| `SPV1-CAPTURE-CONFLICT` | overlapping sibling captures violate exclusivity |
| `SPV1-OVERLAP-UNKNOWN` | a required disjointness proof is unavailable |
| `SPV1-PARENT-CONFLICT` | a parent access conflicts with a live task capture |
| `SPV1-USE-AFTER-TAKE` | the parent or later task accesses a transferred place |
| `SPV1-HANDLE-ESCAPE` | a scope token or task handle escapes its lexical boundary |
| `SPV1-INVALID-MODEL` | executable-model input is malformed or over budget |

A conflict diagnostic names both lexical task identities, both modes, and a
disclosure-safe place description. It never reports runtime thread identity,
completion time, a chosen interleaving, an absolute checkout path, or an
inaccessible binding name.

## Ownership and effects

This proposal reuses `read`, `edit`, and `take` without adding a `Send`, `Sync`,
or shareability trait. The lexical join barrier and second-class handles supply
the non-escape fact that lifetime-bearing first-class references would
otherwise require. Ownership checking is always enabled inside `par`.

The effects of the task body remain the effects of its ordinary checked calls.
RFC-0003 does not introduce an ambient scheduler capability, erase task
effects, classify concurrency itself as `io`, or pre-empt the effect-inference
work in #556. A later production integration may expose panic and cancellation
through that accepted effect vocabulary, but may not weaken the ownership,
join, or failure-precedence rules recorded here.

## Alternatives

1. **Detached tasks in v1.** Rejected. Detachment removes the lexical join fact
   that makes second-class captures sufficient and would require a separate
   authority, lifetime, cleanup, and shutdown design.
2. **A `Send`/`Sync`-style trait.** Rejected for v1. Safe Kofun currently has no
   raw pointers, interior mutable cells, or non-atomic shared reference counts
   requiring per-type exceptions. A trait would add syntax without changing
   this scoped decision.
3. **Go-style channels as the primary abstraction.** Rejected. Channels do not
   provide the ownership or join guarantee needed here and would add blocking,
   closure, and protocol semantics outside this issue.
4. **Actors or behaviour-oriented concurrency.** Deferred. They address
   long-lived isolated state, not the bounded divide-and-conquer case. They may
   return as separate research if scoped parallelism proves insufficient.
5. **Schedule-sensitive exclusivity.** Rejected. Acceptance depending on a
   runtime interleaving would make data-race safety non-reproducible.
6. **An unchecked or optional strict mode.** Rejected. It would make the escape
   hatch the easiest migration path and invalidate the safe-language promise.
7. **Do nothing.** Rejected. It leaves the existing concurrency stance without
   implementable grammar, liveness, overlap, and cleanup decisions.

## Drawbacks

- Server-style background work cannot be expressed as a detached task in v1.
- Dynamic loop spawning and recursive scope creation are refused even when a
  particular runtime could bound them.
- Slice disjointness is intentionally incomplete; symbolic bounds fail closed
  for `edit` and `take` until a later proof system is proposed.
- Implicit scope joins can delay failure propagation and block scope exit while
  a cooperative task drains.
- The fixed panic precedence is deterministic but may not match wall-clock
  completion order observed while debugging.
- The executable model proves the contract, not performance, deadlock freedom,
  fairness, parser integration, or scheduler correctness.

## Compatibility and migration

The proposal is **additive**. No released parser accepts the `par` form and no
tracked Kofun source uses the proposed `par`, `.spawn(`, or `.join(` surface.
At the current proposal integration base
`516e8fb3925088dd64b291e8cd749764a41891b1`:

```sh
git grep -nE '\bpar[[:space:]]*\||\.spawn\(|\.join\(' -- '*.kofun'
# no output; exit 1

git ls-tree -r --name-only 516e8fb3925088dd64b291e8cd749764a41891b1 \
  | awk '/\.kofun$/ { count++ } END { print count + 0 }'
# 799
```

Existing accepted programs keep their meaning. There is no migration action
until a later implementation enables the new surface. Any experimental parser
landing before that implementation must either match this proposal or keep the
forms refused; it cannot claim a different meaning under the same syntax.

## Implementation plan

Acceptance does not implement this RFC. Production work is split so each
authority boundary can be reviewed independently:

1. add parser and HIR identities for `par`, direct scope `spawn`, and consuming
   `join`, with exact recovery and precedence;
2. derive captures from checked bodies and resolved calls;
3. implement semantic liveness, projection overlap, `take` removal, and parent
   conflicts in the ownership checker;
4. allocate stable compiler diagnostics corresponding to the six classes;
5. add a bounded scheduler and scope-exit drain behavior for the enabled target;
6. lower the forms in each backend only after the frontend/runtime boundary is
   gated; and
7. add capability and release evidence only for targets that actually execute
   the production semantics.

The parser, compiler pair, Taskfile, release evidence, and runtime are not
changed by this proposal. The RFC ledger carries no `implementation` object and
no release claim.

## Validation

The committed bounded model consumes
`kofun.scoped-parallelism-model/v1` and emits canonical
`kofun.scoped-parallelism-model-result/v1`. Its hard limits are 64 KiB input,
64 tasks, 64 captures per task, 256 parent actions, projection depth eight, and
96 UTF-8 bytes per identifier/result text. It performs no user-code, process,
network, clock, random, ambient-file, or thread execution.

| Layer | Command | Evidence |
| --- | --- | --- |
| Contract/model | `sh spec/concurrency/scoped-parallelism-v1/check.sh` | positive and negative fixtures, stable diagnostics, canonical repeated output, scope drain and failure precedence |
| RFC schema/ledger | `node tests/rfc/validate-registry.mjs schema` and `node tests/rfc/validate-registry.mjs validate` | RFC-0003 is proposed for 14 days and carries no implementation record |
| RFC mutations | `sh tests/rfc/check-registry.sh` | acceptance, implementation, review, path, and compatibility boundaries fail closed |
| Repository contracts | `task repository-check` | repository metadata and contracts remain coherent |

Passing these gates proves only that the proposal and model agree. It is not
evidence that a released parser, ownership checker, scheduler, runtime, or
backend accepts or executes `par`.

## Unresolved questions

No v1 syntax, ownership, disjointness, handle-lifecycle, scope-exit, panic,
cancellation-precedence, or safety-promise question remains open.

Detached tasks, long-lived concurrency, dynamic spawning, numeric compiler
diagnostic allocation, cancellation-token APIs, borrowed task results (#571),
and the production effect spelling are deliberately outside RFC-0003. Each
requires a later proposal or implementation issue and cannot silently widen
the v1 contract during review.

A substantive change to any normative v1 rule restarts the review window rather
than being folded into implementation. Until review closes on 2026-08-16 and
the ledger state is updated after an explicit decision, RFC-0003 remains
`proposed`.
