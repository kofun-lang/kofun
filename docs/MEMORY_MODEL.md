# Memory model

## 1. Goals

Kofun's memory model aims to satisfy all of the following at once.

- ordinary application code can be written as if in a GC language
- files, sockets, locks, transactions, and GPU buffers can be released
  deterministically
- use-after-free, double free, and data races are prevented in safe code —
  data-race freedom only, never race-condition freedom; see
  [§12](#12-concurrency-stance)
- no lifetime parameters are written in everyday code
- the compiler can detect unique values and reuse them in place
- a no-GC profile can be reached for embedded, real-time, and
  high-performance use

## 2. Three memory domains

### 2.1 Copy values

The initial closed Copy set is `Int`, `Float`, `Bool`, and `Unit`. Copy is not
user-implementable. Tuples and records remain non-Copy until a later
type-directed derivation decision.

```kofun
let a = 42
let b = a
print(a)
print(b)
```

A copy does not require an explicit heap allocation.

### 2.2 Managed values

`Text`, an ordinary `List[T]`, records, closures, graph data, and the like can
live on the managed heap.

```kofun
let names = ["A", "B", "C"]
let alias = names
```

Ordinary managed values are reclaimed by the GC. The language surface is
immutable by default, so even with aliases, data races and unexpected mutation
are unlikely.

The compiler is free to apply any of the following optimizations.

- stack allocation
- scalar replacement
- arena allocation
- reference counting
- tracing GC
- promotion to owned allocation
- in-place reuse

It must not change the observable semantics, however. The boundary between
these optimizations and the semantic transfer of [§3.3](#33-take-t) is stated
precisely in [§14](#14-semantic-take-versus-optimization-only-moves).

### 2.3 Owned resources

An external resource, or a value that needs deterministic cleanup, is bound
with `own`.

```kofun
let own file = File.open("data.csv")
```

Owned values are affine.

- can be consumed zero times or once
- cannot be consumed twice
- automatically dropped at end of scope if not consumed
- the original binding cannot be used after `take`

The reason for affine rather than linear is that scope cleanup can then safely
handle early returns and unused resources.

## 3. Parameter modes

### 3.1 `read T`

A read-only, non-owning view.

```kofun
fn checksum(read bytes: Bytes) -> Int {
    # bytes cannot be mutated or consumed here
}
```

Properties:

- multiple `read` views can be held at the same time
- does not consume the original value
- in v1, a view cannot escape the function
- the compiler infers the lifetime from the lexical scope

### 3.2 `edit T`

An exclusive mutable view.

```kofun
fn normalize(edit values: Array[Float]) {
    # exclusive mutation is allowed
}
```

Properties:

- no other `read` or `edit` view can be created for the same period
- does not consume the original value
- non-escaping in v1
- the mutation is recorded as an effect

### 3.3 `take T`

Ownership transfer.

```kofun
fn send(take socket: Socket, read payload: Bytes) {
    # socket is owned by this call
}
```

Call site:

```kofun
let own socket = Socket.connect(address)
send(socket, payload)

# compile error: socket was taken
print(socket.peer())
```

Whether `take` must also be written at the call site will be decided by UX
testing. The initial proposal puts it only on the parameter declaration and
makes the ownership transfer explicit through a compiler diagnostic. A proposal
to allow the call-site annotation `send(take socket, payload)` for APIs that
need close review is also in the backlog.

## 4. `let own`

```kofun
let own file = File.open(path)
```

This binding has the following state machine.

```text
uninitialized
    -> live
    -> taken
    -> dropped
```

Forbidden transitions:

```text
taken -> read
taken -> edit
taken -> take
dropped -> any use
live + active edit -> another read/edit
live + active read -> edit/take
```

## 5. Branches

```kofun
let own socket = connect()

if should_send {
    send(socket)
} else {
    close(socket)
}
```

Because it is consumed in both branches, `socket` cannot be used after the
branch.

Even when only one branch consumes it, the conservative v1 checker forbids use
after the branch.

```kofun
if should_send {
    send(socket)
}

# compile error in v1: socket may have been taken
```

Later, state refinement will allow a boolean condition to be related to the
resource state.

## 6. Loops

When an outer owned value is consumed inside a loop, the loop may run zero
times or multiple times.

```kofun
let own socket = connect()

while condition {
    send(socket) # rejected
}
```

The safe form:

```kofun
let mut pending: Socket? = connect()

while condition && pending != null {
    let own socket = pending.take()
    send(socket)
    pending = null
}
```

A better state API will be provided once ADTs and pattern matching are
implemented.

## 7. Closures

Closure capture is classified into 3 kinds.

```kofun
fn make_reader(read data: Bytes) -> (() -> Int)
fn make_editor(edit data: Buffer) -> (() -> Void)
fn make_owner(take data: Resource) -> (() -> Void)
```

v1 rules:

- a `read` / `edit` capture cannot go into an escaping closure
- an escaping closure can only capture managed values or taken owned values
- no `Send`- or `Share`-equivalent auto trait is planned; a task captures under
  the ordinary exclusivity rule instead, for the reasons in
  [§12](#12-concurrency-stance)

## 8. GC design

The production runtime is expected to default to a generational precise
tracing GC.

### Nursery

- thread-local bump allocation
- small managed objects
- copying minor collection
- precise stack map

### Old generation

- compacting or region-based collector
- large object space
- optional concurrent marking
- pinned object support

### Compiler cooperation

- safepoint insertion
- exact root map
- write barrier insertion and elimination
- escape analysis
- object layout metadata
- ownership-based allocation avoidance

### Operational controls

```text
KOFUN_GC_NURSERY_MB
KOFUN_GC_MAX_HEAP_MB
KOFUN_GC_PAUSE_TARGET_MS
KOFUN_GC_LOG
```

The names are not final; in the production API they will be integrated into
the manifest and CLI config.

## 9. Owned-to-managed conversion

A resource wrapper meant to be shared for a long time is explicitly `share`d.

```kofun
let own client = Client.connect(endpoint)
let shared = share(client)
```

After `share`:

- the original owned binding is taken
- the shared handle can be managed by the GC or by atomic reference counting
- if a deterministic close is needed, follow the `Shared[Client]` protocol
- do not make correctness depend on finalizers alone

## 10. Finalizers

A GC finalizer is last-resort cleanup and is not used in the normal resource
protocol.

Designs that are forbidden:

- leaving a transaction commit to a finalizer
- leaving lock release timing to a finalizer
- leaving the correctness of a file flush to a finalizer

Resources are handled by scope cleanup, `take`, or a `with`-equivalent
resource scope.

## 11. Unsafe boundary

Operations that fall outside the safe language core are separated from ordinary
modules.

Planned example:

```kofun
import trusted.memory

trusted fn from_raw_pointer[T](ptr: Ptr[T], len: Int) -> Slice[T]
```

Principles:

- do not scatter `unsafe` around as a short escape hatch
- a trusted module exposes its preconditions and postconditions through types
  and contracts
- a linter measures the trusted surface area
- unsafe capabilities are recorded in the package metadata

`trusted` is the candidate keyword name; the final decision will be made by
RFC.

## 12. Concurrency stance

Recorded from the survey in
[#555](https://github.com/kofun-lang/kofun/issues/555). None of these semantics is
implemented: the compiler owns `par` as a keyword and refuses the construct by
name with `E2S154`, but no capture derivation, ownership checking, scheduling,
or lowering exists. It is written down here because a concurrency design decided later
and separately would be one the ownership rules in this document cannot check,
and because §1 promises a safety property that needs a precise name.

This section is the reasoning, not the contract. The normative form of the v1
rules — grammar, handle lifecycle, liveness, the exclusivity table, the closed
set of disjointness proofs, scope-exit drain, and the required diagnostic
classes — is
[`spec/concurrency/scoped-parallelism-v1.md`](../spec/concurrency/scoped-parallelism-v1.md),
checked by `task scoped-parallelism` and proposed as
[`RFC-0003`](../rfcs/0003-scoped-parallelism.md) with review closing
2026-08-16. Where this section and that contract disagree, the contract wins.
Passing its gate is evidence about the contract, not about a compiler:
production parsing, checking, scheduling, and lowering remain unwritten.

### Data-race freedom is not race-condition freedom

What §1 promises is **data-race freedom**: in safe code, two tasks never touch
the same storage at the same time with at least one of them writing. That is
the property the exclusivity rule can decide, and it is the only one promised.

What is **not** promised is **race-condition freedom**. A program whose result
depends on which of two correctly synchronised tasks runs first is still
wrong, and nothing in this model rejects it. Deadlock, livelock, lost updates
spread across two separately atomic steps, and check-then-act mistakes all stay
possible. Swift's actors are the standard illustration of the gap: they are
reentrant, so state can change across any `await` — data races prevented,
higher-level races not.

Read every safety statement in this document against that split.

### Scoped parallelism, and possibly only this

The first and perhaps only construct is a scoped block whose tasks join before
it exits:

```kofun
fn total(read data: List[Int]) -> Int {
    par |s| {
        let a = s.spawn(fn() => sum(data[0 .. mid]))
        let b = s.spawn(fn() => sum(data[mid .. end]))
        a.join() + b.join()
    }
}
```

The task body uses Kofun's `fn(...) => expression` lambda form from
`spec/grammar.ebnf`. There is no Rust-style `|| body` closure spelling: `||` is
the logical-or operator, so that form is not a closure here and does not parse.

The rule is one sentence: **inside a `par` block, sibling tasks are treated as
simultaneously live and §3's exclusivity rule applies unchanged.**

- any number of tasks may hold `read x`;
- at most one may hold `edit x`, and no `read x` at the same time;
- `take x` into a task removes it from the parent.

That needs no new type-system machinery. Second-class references supply what
Rust needs lifetimes for: a reference that cannot be returned or stored cannot
outlive its frame, so a task that cannot escape its block cannot outlive its
referent. Rust states the same guarantee as
`fn scope<'env, F, T>(f: F) -> T where F: for<'scope> FnOnce(&'scope Scope<'scope, 'env>) -> T`,
and `std::thread::scope` took until Rust 1.63 to stabilise.

The one real addition this needs is **disjointness for slices and fields**, so
that `edit v[0 .. k]` and `edit v[k ..]` are provably non-overlapping. That is
what makes divide-and-conquer expressible, and it is the hard part.

### No `Send`/`Sync`-equivalent trait

§7 previously listed a `Send`-equivalent auto trait for async captures and a
`Share` equivalent for cross-thread sharing. Neither is planned.

Every exception to Rust's `Send`/`Sync` auto-derivation is a form of hidden
sharing: raw pointers, `UnsafeCell` and therefore `Cell`/`RefCell`, and `Rc`'s
unsynchronised refcount. With no raw pointers in safe code, no interior
mutability, and no non-atomic refcounted pointer, the derivation has no
exceptions and the trait carries no information.

If a shared-mutable cell is ever added, mark *that type* isolation-local rather
than adding the trait — default-safe with an opt-out, rather than Rust's
default-derive with an opt-out. Swift's `@unchecked Sendable` is the warning
here: an escape hatch that needs no `unsafe` keyword becomes the migration
strategy. Any escape hatch added must be loud.

`take` also already is what Swift spent SE-0414 and SE-0430 approximating. A
moved value is disconnected by construction, so the expensive part of Swift 6's
concurrency model arrives free from ownership.

### Long-lived state, if it is ever needed

If state must outlive a scope, prefer Verona's behaviour-oriented concurrency
over actors: a `cown` wraps isolated state, and a behaviour names the cowns it
needs so the runtime acquires them atomically. That gives data-race freedom,
deadlock freedom (cowns are totally ordered, so circular wait cannot form), and
multi-resource atomicity — the two-account transfer that is awkward in every
actor system. For values crossing that boundary, Pony's three-way answer
applies: unique-and-moved (`take`), deeply immutable, or opaque identity.
Nothing else crosses, and `read`/`edit` stay inside one domain.

### Not to be built

- **Go-style channels.** [Tu et al., ASPLOS '19](https://songlh.github.io/paper/go-study.pdf)
  studied 171 concurrency bugs in Docker, Kubernetes, etcd, CockroachDB, gRPC
  and BoltDB: an almost exact 85/86 blocking/non-blocking split, **58% of the
  blocking bugs caused by message passing** rather than shared memory, and Go's
  deadlock detector catching 2 of 21 reproduced blocking bugs. Their conclusion
  is that message passing is as easy to get wrong as shared memory. (Figures via
  a secondary summary; check the PDF before quoting them publicly.)
- **Session types.** No production deployment found, and the Go analysers
  expect all goroutines to be spawned before any communication occurs, which
  excludes ordinary server code. The cheap idea worth taking is typestate on a
  single linear channel endpoint, not multiparty protocol verification.
- **Erlang-style supervision.** It needs per-process GC, hot code loading, and a
  managed runtime. HiPE, Erlang's native compiler, was removed in OTP 24 —
  direct evidence that BEAM's properties and AOT compilation are in tension.
  Isolation is obtainable from ownership; hot code loading is not.

### Where this stance hurts, stated plainly

Unstructured concurrency becomes hard or impossible. A long-lived actor, a
channel outliving its frame, a detached task — each needs a value to escape
upward, which second-class references forbid. Hylo, the closest existing
design, reached the same point and accepted it, "de facto discarding all forms
of communication except at spawn and join events"; its concurrency remains
unimplemented.

The stronger warning is Mojo, which used `borrowed`/`inout`/`owned` — nearly
these conventions — and has since added `Origin`, `MutOrigin`, `ImmutOrigin`
and a lifetime checker. The pressure that produced them was not concurrency but
ordinary library code: indexing that returns a reference into a container,
iterators, slices. This project will meet the same pressure whatever it decides
about concurrency, and the mechanism to study is Hylo's `subscript`, which
yields rather than returns.

**No language combines second-class references with a shipping concurrency
model.** Pony has capabilities but first-class references; Hylo has
second-class references and no implemented concurrency; Scala's capture
checking is experimental; Verona is research. There is no template to follow,
which is both the opportunity and the risk.

### Answered since this survey

Two questions this section left open are now settled in
[`spec/concurrency/scoped-parallelism-v1.md`](../spec/concurrency/scoped-parallelism-v1.md).

**Unstructured concurrency takes Hylo's position for v1.** Safe v1 is lexical
spawn/join only. Detached tasks, channels, actors, and behaviour-oriented
concurrency are outside the contract and are not implicit extensions of it.
Behaviour-oriented concurrency stays the preferred candidate if long-lived
isolated state is ever needed, but it returns as a separate proposal rather
than as a reading of this one.

**There is no strict mode, so there are no defaults to get wrong.** Checking
inside `par` is always on. The contract admits no optional mode, no runtime
ownership lock, no unchecked escape hatch, and no trait whose conformance can
override the exclusivity table. That closes the Swift failure this section
warned about — `@unchecked Sendable` became the migration strategy because it
was available and quiet — by not providing the hatch, rather than by choosing a
default for it.

Both answers are recorded in accepted
[`RFC-0003`](../rfcs/0003-scoped-parallelism.md), decided 2026-08-09. They are
the language's position now, and a substantive change to any normative v1 rule
reopens review rather than being folded into implementation.

### Still open

Not the decision — the implementation. Nothing in the production compiler
executes `par`: no capture derivation, ownership checking, scheduling, or
lowering exists, and the compiler refuses the construct by name with `E2S154`.

Everything v1 deliberately excludes needs its own later proposal — detached
tasks, long-lived isolated state, channels, actors, session types, a
`Send`/`Sync`-style trait, dynamic and recursive spawning, and borrowed task
results ([#571](https://github.com/kofun-lang/kofun/issues/571)).

The whole production path is unwritten. RFC-0003's implementation plan splits
it into separately gated work: parser and HIR identities for the three forms,
capture derivation from checked bodies, the liveness and place-overlap
ownership checker, numeric allocation for the six diagnostic classes, a bounded
scheduler with scope-exit drain, backend lowering, and only then capability and
release evidence.

## 13. Historical Stage 0 and current boundary

The removed Stage 0 reference prototype described a tracing-GC runtime and
experimental `let own`, `take`, use-after-take `E330`, and automatic-disposal
behavior. Those statements are historical; they are not capabilities of the
current compiler.

Current executable compiler evidence is narrower: the bounded Stage 2
ownership slice reports `E007` when a `Text` element is returned by value from
an explicitly typed borrowed `List[Text]`, while the paired `Int` Copy case
succeeds. It does not implement a general tracing collector, ownership
inference, `let own`/`take` checking, automatic disposal, borrow lifetimes,
alias graphs, or async capture.

The current slice validates one diagnostic boundary. It is not a production
memory-safety proof.

### What refuses an ownership error today

Four bounded mechanisms exist. They do not form one general ownership pass.

| Mechanism | What it refuses | Code | Gate |
|---|---|---|---|
| Stage 2 `--check-ownership` | a non-Copy element moved out of a borrowed `List` | `E007` | `sh bootstrap/stage2/check.sh` |
| production and standalone record frontends | a whole nominal record used after an explicit `take`, passed as a bare binding to a labelled `take` parameter and then transferred again, or partially/doubly moved | `E2S122`, `E2S123` | `task records`; `task call-arguments` |
| `stdlib/clock` affine handles | a consumed clock handle used again | none; the type carries it | `task clock-adapters` |
| bounded affine resource handle | use after a transition move; a stale, foreign, or adversarially duplicated generation at the host boundary | `E2S123`, `EARH01` | `task affine-resource-handle` |

The first is an opt-in subcommand of the Stage 2 binary. The second reaches the
ordinary Stage 2 C11 path for explicit, source-order whole-record moves and for
a bare binding placed in a direct top-level labelled `take` slot, while the
standalone evaluator keeps the same messages. The third is a clock library
type, and the fourth is one RFC-0010 per-type table plus a host-boundary
generation check. `bin/kofun build` therefore understands `read`/`take`
parameters and these explicit whole-binding transfer sites only in that
bounded record slice; it still has no `let own`, inferred moves, alias graph,
branch/loop ownership, borrow lifetime, destructor, or general cleanup
analysis.

`E3xx` is not a live family. No `E3xx` code has ever been in
`tests/diagnostics/registry.tsv`, and `examples/check.sh` fails any example
citing a code the registry does not carry. Where the retired numbering still
appears — the `E330` named above, and its mention in
`rfcs/0001-allocator-capability.md` as the historical neighbour of `E340`–`E342`
— it names history, not a diagnostic any compiler emits.

## 14. Semantic `take` versus optimization-only moves

Recorded from [#572](https://github.com/kofun-lang/kofun/issues/572), which
follows Nim's `sink`/`ensureMove` design. Two things are both called "moves"
and must never be confused.

**Semantic `take` is observable.** A `take` parameter or a consumed `own`
binding transfers ownership as part of the program's meaning: the source
binding becomes unusable, use-after-take is a compile error, and cleanup
obligations move with the value. No optimization level, backend, or analysis
improvement may infer a `take` away or weaken its diagnostics. §2.3 and §3.3
define this behavior; it is part of the language.

**Managed-value moves are optimization only.** When the compiler moves or
reuses the storage of a managed value (§2.2) instead of copying, retaining,
or reallocating, that choice must be invisible: disabling every such move may
change allocation counts, retain/release traffic, and code size — never
program output, error behavior, cleanup order, or what any alias observes.
No program may be correct only when the optimization fires.

Nim's "last syntactic read" rule is not sufficient here, because immutable
managed values alias freely and a tracing-GC backend keeps aliased storage
alive. The proof obligation is last use of the unique storage identity: no
later use, no live alias, no capture that can observe the storage afterwards.

### The unstable assertion: `compiler.ensure_move(value)`

**Everything in this subsection is unstable.** The name, the diagnostic code,
and the proof rule may all change; nothing here is language surface. The
assertion exists for standard-library implementation, performance regression
tests, and measured hot paths. Everyday code should never contain it.

`compiler.ensure_move(value)` is a compile-time-only statement. It produces
no value, is erased before code generation — the emitted C of a program with
and without the assertion is byte-identical — and never evaluates its
argument. Its single effect is on compilation: the build fails with
diagnostic `E2S146` unless the Stage 2 slice can prove that `value` is a
managed local binding at its last use under the narrowest sound rule it can
decide today:

- the argument is an immutable local binding of managed type (`Text` or
  `List`), named directly — not a parameter, which the caller may retain
  (borrowed view, §3.1);
- the assertion sits in the binding's own scope, or in a conditional arm
  that is **terminal** — every path after the assertion within that arm
  leaves the function through `return`, so control cannot rejoin the outer
  scope where the binding is still observable (#904). Terminality is decided
  over statements, not source order: a nested `if` counts only when both of
  its arms terminate, and a loop between the assertion and the arm's
  `return` refuses outright, because it may re-enter. An assertion inside a
  loop is decided by where its binding lives (#915): a binding declared
  inside the loop body is fresh each iteration, so the assertion is that
  iteration's last use and is accepted, while a binding declared outside is
  read again by the next iteration and is rejected. An assertion in an arm
  the binding outlives is still rejected rather than analysed;
- the binding has no use at any later byte and no use inside any lambda;
- every earlier read is provably alias-free: an operand of `==`/`!=`, or an
  argument to a call whose result is a Copy value or no value. A read that
  becomes a `let` initializer, a constructor field, a return value, or an
  argument to a managed-result call conservatively defeats the proof.

Every `E2S146` rejection names its reason using the vocabulary of #572:
`later use`, `possible alias`, `branch mismatch`, `escaping capture`, or
`backend limitation`. `unknown foreign call` is reserved; the current slice
cannot express a foreign call. A failed assertion never weakens to a
warning and never falls back to another compiler: a source file that both
contains the assertion and steps outside the Stage 2 slice is rejected by
the seed compiler, which does not accept the syntax.

The general inference — last-use over aggregates, allocation counters, and
optimization remarks — remains future work under #572, and the in-place ADT
reuse built on top of this assertion is #576. The loop-local last use is
#915, closed by the scope-chain rule above: the analysis already decided it
correctly, and what was missing was any way to run a positive loop case,
because `while` did not lower until #1128. The gate is
`tests/move-assertion/check.sh`.
