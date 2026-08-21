# Scoped parallelism v1

Status: accepted normative contract (RFC-0003, decided 2026-08-09) and bounded
executable model; production parsing, checking, lowering, and scheduling are
not implemented.

Issue: [#555](https://github.com/kofun-lang/kofun/issues/555)

## 1. Promise and boundary

Safe v1 supports lexical spawn/join scopes only. It promises **data-race
freedom**, not race-condition freedom, scheduling determinism, deadlock
freedom, fairness, or parallel speedup.

Detached tasks, handles that outlive their scope, channels, actors,
behaviour-oriented concurrency, session types, and a `Send`/`Sync`-equivalent
trait are outside v1. A later feature must not infer any of them from this
contract.

This document fixes source and ownership semantics so a production checker can
be implemented without reopening the safety decisions. The executable model
under `spec/concurrency/scoped-parallelism-v1/` checks this contract only. It
does not execute user code, create threads, choose a schedule, or claim a
production scheduler.

## 2. Source grammar

V1 adds exactly these forms:

```ebnf
par-expression   = "par", "|", identifier, "|", block ;
spawn-expression = identifier, ".", "spawn", "(", lambda-expression, ")" ;
join-expression  = expression, ".", "join", "(", ")" ;
```

The identifier between bars is the scope token. `spawn` is available only as
a direct operation on that token. The argument uses Kofun's ordinary `fn`
lambda spelling; v1 introduces no second closure syntax and no implicit
parameter.

```kofun
par |scope| {
    let left = scope.spawn(fn() => total(read items, 0, split))
    let right = scope.spawn(fn() => total(read items, split, len(items)))
    left.join() + right.join()
}
```

The source order of expressions remains their ordinary evaluation order. The
compiler evaluates each `spawn` argument and establishes its captures before
starting that task. A production child must assign exact precedence and
automatic-termination interactions in the grammar without changing these
three forms.

The v1 checker accepts a finite lexical set of spawn sites. Spawning in a loop,
recursively creating a scope, dynamically selecting a scope token, or joining
a handle through an alias is unsupported in v1 rather than guessed.

## 3. Scope token and task handles

The scope token and every task handle are second-class affine compiler values.
They have lexical identity but are not ordinary storable values.

The scope token:

- exists only inside its `par` block;
- cannot be returned, stored, captured by a task, passed to another function,
  serialized, or compared;
- creates a handle for each successful `spawn` in lexical order.

A task handle:

- belongs to exactly one scope and cannot be copied;
- cannot be returned, stored, captured by any task, passed to another
  function, serialized, or used after its scope;
- may be explicitly joined at most once;
- yields its task result when an explicit join succeeds;
- is still joined at scope exit if the program did not explicitly join it;
- has its result discarded when joined implicitly at scope exit.

An unused handle is therefore safe and bounded, not detached. A production
diagnostic may warn about a discarded result, but it may not turn the implicit
join into detachment.

## 4. Liveness

The capture lifetime of a task is the half-open semantic interval from the
completion of its spawn operation up to the completion of its explicit join.
If there is no explicit join, the interval ends only after the task is joined
during scope exit.

Sibling task intervals that overlap are treated as simultaneously live for
ownership checking. The checker does not shorten an interval because a chosen
runtime schedule happens to finish a task early. This keeps acceptance
independent of clocks, machine load, worker count, and scheduler policy.

An explicit join ends that task's `read` and `edit` captures. A value transferred
with `take` is not silently restored by joining. It can return only as an
explicit result bound to a new place.

Parent accesses are checked against every task interval. The parent may read a
place concurrently with task reads. It may not access a place after transferring
it with `take`, and it may not perform a conflicting access while a task capture
is live.

## 5. Captures and exclusivity

Each captured place has the existing ownership mode `read`, `edit`, or `take`.
The compiler derives the capture mode from the checked body and resolved calls;
v1 adds no user-written capture list.

For two simultaneously live accesses to overlapping places:

| Left | Right | Result |
| --- | --- | --- |
| `read` | `read` | accepted |
| `read` | `edit` or `take` | rejected |
| `edit` | `read`, `edit`, or `take` | rejected |
| `take` | `read`, `edit`, or `take` | rejected |

`take` additionally removes the original place at spawn. A later parent access
or a later task capture is rejected even after join unless a new place is
established from the taking task's explicit result. Joining ends the task's
live interval; it does not recreate the transferred place.

The rejection is static. There is no optional strict mode, dynamic ownership
lock, unsafe escape hatch, or trait whose conformance can override the table.

## 6. Place overlap

A place is a base binding followed by zero or more named-field or half-open
slice projections.

V1 proves disjointness only with these rules:

1. Different base bindings are disjoint.
2. Two projections of the same record are disjoint when the first differing
   projection names different fields.
3. Two half-open slices of the same base are disjoint when all four bounds are
   statically known integers and `left.end <= right.start` or
   `right.end <= left.start`.
4. Identical projections, a whole value and any of its projections, and slices
   with intersecting known ranges overlap.
5. Every other relation is unknown.

Unknown overlap is accepted only for `read` plus `read`. If either access is
`edit` or `take`, unknown overlap is rejected. The checker must not use runtime
values, solver timeouts, profile data, or a selected schedule to guess.

Empty half-open slices are disjoint from every slice. Invalid ranges with a
known start greater than the end are malformed input, not empty slices.

## 7. Join, panic, and cancellation

Normal explicit join waits for the named task and yields its result. Scope exit
waits for all handles that have not already been joined, discards their normal
results, then exits.

Panic and cancellation never detach work:

- A task panic begins scope unwinding. The scope requests cancellation of
  still-running siblings, joins every handle, performs ordinary cleanup, and
  then propagates a panic.
- If several tasks panic before draining finishes, the panic belonging to the
  lexically earliest spawned panicking task is the primary diagnostic. Other
  panics are related diagnostics. Runtime completion order does not select the
  primary failure.
- Cancellation of the parent requests cancellation of every unfinished task,
  joins all handles, performs cleanup, and then propagates cancellation.
- A task panic has precedence over a simultaneous cancellation request. A
  cancellation cannot hide an ownership failure or panic.
- A task that observes cancellation may return normally before the scope
  drains. V1 promises the join barrier, not immediate interruption.

The bounded model represents task outcomes as `success`, `panic`, or
`cancelled`. It validates draining and precedence but does not run callbacks or
model a cancellation API. Production cancellation tokens and panic payloads
belong to later implementation work.

## 8. Required diagnostic classes

The contract/model identifiers are stable specification classes; a production
diagnostic registry may allocate user-facing compiler numbers without changing
their meaning.

| Identifier | Required meaning |
| --- | --- |
| `SPV1-CAPTURE-CONFLICT` | two overlapping sibling captures violate exclusivity |
| `SPV1-OVERLAP-UNKNOWN` | a required disjointness proof is unavailable |
| `SPV1-PARENT-CONFLICT` | a parent access conflicts with a live task capture |
| `SPV1-USE-AFTER-TAKE` | the parent accesses a place transferred to a task |
| `SPV1-HANDLE-ESCAPE` | a scope token or handle is returned, stored, captured, or passed |
| `SPV1-INVALID-MODEL` | the bounded model input is malformed or exceeds a limit |

A conflict diagnostic names both lexical task identities, both modes, and a
disclosure-safe place description. It must not report a runtime thread ID,
completion time, chosen interleaving, absolute checkout path, or an inaccessible
binding name.

## 9. Semantic anchors for schedule tracing

The semantics expose these logical anchors to the separate trace layer owned by
[#736](https://github.com/kofun-lang/kofun/issues/736):

- `scope.enter`
- `task.spawn`
- `task.join.explicit`
- `task.join.scope-exit`
- `scope.exit`

They identify lexical ownership transitions only. They are not a schedule trace
and do not record task start, yield, wake, channel activity, worker selection,
wall time, or runnable-set order. #736 owns trace identity, replay, exploration,
budgets, and the ordering of runtime events around these anchors. Neither model
may treat the other's output as authority for ownership acceptance.

## 10. Executable model

`model.mjs` consumes a bounded JSON document with schema
`kofun.scoped-parallelism-model/v1`. A scope supplies a logical exit step, up to
64 lexical tasks, up to 64 captures per task, and up to 256 parent actions.
Projection depth is at most eight and input is at most 64 KiB.

Logical steps express liveness only. They are not clock ticks.

Each explicit spawn, join, or parent access has a unique logical step and must
occur strictly before the scope-exit step. Only implicit joins share the
scope-exit step, and they occur before the `scope.exit` anchor.
Reusing an explicit step is malformed input rather than an ordering tie for the
model to guess. Multiple implicit joins at scope exit are an unordered semantic
set canonicalized by task identity; their output order is not a runtime join
order.

The model:

1. validates the closed input shape and limits;
2. checks handle escape and join bounds;
3. computes sibling and parent conflicts from semantic intervals and place
   overlap;
4. determines explicit versus scope-exit joins;
5. applies deterministic panic/cancellation precedence;
6. emits canonical-key-order JSON observations and logical anchors.

The model performs no user-code evaluation, network, process, clock, random,
ambient-file, or thread operation. Its only CLI input is the named committed
fixture.

Run the focused gate with:

```sh
sh spec/concurrency/scoped-parallelism-v1/check.sh
```

The committed cases cover shared reads, conflicting captures, field and slice
disjointness, unknown overlap, parent use after `take`, handle escape, explicit
result join, unused-handle scope join, panic draining, cancellation draining,
and deterministic repeated output.

## 11. Compatibility and implementation handoff

This contract is additive target semantics. No released parser accepts `par`,
so this slice changes no accepted program, runtime artifact, compiler interface,
or release capability claim.

The first production slice is landed and is a refusal, not an acceptance: the
Stage 2 lexer owns `par` as a keyword, `spec/grammar.ebnf` carries the
`par_expr` production, and every entry point — structural lowering, the
scope-HIR walk, and the typed frontend — refuses the construct by name with
`E2S154` plus an `unsupported|START|END|scoped-parallelism` record, as
`bootstrap/selfhost/hir-v1.md` requires when a syntactic construct has no
frozen v1 node representation. Naming the construct replaces an incidental
`E2S35 unknown lexical binding` blamed on the scope token. Representing `par`
in the typed HIR would
require `kofun.selfhost-hir/v2` and a profile revision, so capture derivation,
place-overlap checking, the diagnostic classes in §8, scheduling, and backend
lowering all remain unimplemented.

A production implementation must be split into separately gated parser/HIR,
ownership/place analysis, runtime/scheduler, diagnostics, and backend work. It
must preserve every rejection and lifecycle rule here. Passing this model is
not evidence that any production component is implemented.

This document is the normative contract of accepted
[`RFC-0003`](../../rfcs/0003-scoped-parallelism.md), decided 2026-08-09. The
decision is in force; the feature is not shipped. No parser, ownership checker,
scheduler, or backend implements it, and the compiler refuses `par` by name
with `E2S154` — which is the separation between an accepted decision and an
implemented capability, not a gap in the decision.
