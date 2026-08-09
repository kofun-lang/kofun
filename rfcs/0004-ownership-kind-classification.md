# RFC-0004: Ownership kind is classified structurally through ADTs, tuples, and generic instantiation

- Shepherd: hjosugi
- Opened: 2026-08-02
- Status: accepted
- Decided: 2026-08-09

Proposal for [#907](https://github.com/kofun-lang/kofun/issues/907), the bounded
child of [#570](https://github.com/kofun-lang/kofun/issues/570). Review opened with the ledger's announced window; it closes when the
shepherd closes it, and the ledger records that day. This proposal
records target semantics only. No parser, checker, classifier, diagnostic,
backend, standard-library type, or release capability is implemented by it, and
`docs/MVP_IMPLEMENTED.md` continues to record general ownership checking as
`open`.

## Summary

Every Kofun type gets exactly one **ownership kind**, `Managed` or `Owned`, and
the kind of a composite is computed from its parts rather than declared. A
record, tuple, ADT constructor payload, closure capture, `Optional[T]`, or
generic instantiation that can contain an owned value is itself owned, and an
owned kind absorbs: `join(Managed, Managed) = Managed`,
`join(K, Owned) = Owned`. `spec/records-v1.md` already states this rule for one
shape — "a record containing an affine owned field is itself affine" — and this
proposal is that sentence generalized to every shape the language has, with the
generic-substitution case stated as well.

`Copy` is **not** a third point on that lattice. It stays an orthogonal
property of a `Managed` type, fixed by the closed set of
[`docs/MEMORY_MODEL.md`](../docs/MEMORY_MODEL.md) §2.1. The candidate relation
`Copy <= Managed` from #570 is rejected, with the reasoning below.

For someone writing Kofun, the visible consequences are four. A composite built
over a resource is a resource, and gets scope cleanup, single consumption, and
reverse-declaration-order drop without writing anything. `List[T]` refuses an
owned `T` in v1 rather than becoming a finalizer-dependent list. A generic
parameter with no constraint is treated as owned, so a passthrough is written
once and stays correct when someone instantiates it over a socket. And every
refusal names the field, variant, capture, or type argument that made the type
owned, so the answer to "why is this owned" is a path, not a verdict.

## Motivation

The rule already exists for exactly one shape, and stops there.
[`spec/records-v1.md`](../spec/records-v1.md) §"Ownership, mutation, and drop"
states three facts as accepted normative design, gated by `task records`:

- "A record containing an affine owned field is itself affine."
- "Dropping a whole record drops its owned fields in reverse declaration
  order."
- "`take record` transfers the whole record. Partial moves such as
  `take record.field` are **rejected** in v1" — `E2S122`, with `E2S123` for use
  after `take`.

[`docs/MEMORY_MODEL.md`](../docs/MEMORY_MODEL.md) §7 adds one more shape: "an
escaping closure can only capture managed values or taken owned values."

Nothing states the corresponding fact for a tuple, for an ADT constructor
payload, for `Optional[T]`, for `List[T]`, or for `Pair[Int, File]`. That gap
is not academic; it already deforms landed code.

**The standard library simulates affinity because the type system cannot carry
it.** [`stdlib/clock/adapters.kofun`](../stdlib/clock/adapters.kofun) is the
landed affine-capability idiom, and its own header states the rule it wants:
"A handle is affine. Every read, sleep, advance, and cancel consumes the handle
it was given and leaves exactly one next handle in its place, so there is no
way to observe two different times through the same capability state." The
mechanism it actually uses is a generation counter inside an ordinary record:

```kofun
# The monotonic clock capability. `generation` is the affine token: an
# operation accepts only the live generation and advances the handle to the
# next one, so a copy kept behind is now at a dead generation and every later
# use of it is StaleClockHandle rather than a second reading.
type MonotonicClock = {
    identity: ClockIdentity,
    generation: Int,
}
```

Both fields are `Copy`, so the record is `Managed`, so nothing stops a second
use — and the module recovers affinity at run time, as a typed
`StaleClockHandle` error. That is a good engineering answer to a missing
language rule, and it is the wrong place for the check: a compile-time property
is being paid for with a run-time comparison and a per-operation counter field.
The module cannot do better today, because there is no way to say that
`MonotonicClock` is owned.

**A generic ADT over a resource already appears in tracked source.**
`stdlib/tests/file_roundtrip.kofun` binds an owned file out of a `Result`:

```kofun
let own file = match file_create(
    "kofun-syscall-roundtrip.fixture",
    384,
) {
    Ok(opened) => opened
    Err(_) => syscall_failure()
}
```

`Result[File, IoError]` is a generic ADT instantiated with a resource type. No
document says what its kind is, whether it may be stored, whether dropping it
unmatched closes the file, or what happens if the same value is matched twice.
The program is correct, and it is correct by the author's care rather than by a
stated rule.

**The parent issue's own measurement bounds what a first artifact can be.**
#570 records, measured on `main`, that `let own x = 1` is refused by Stage 2
with ``error[E2S11]: expected `=` ``, and that
`git grep -nE 'OwnershipKind|ownership kind|kind lattice'`
over `*.kofun`, `spec/**`, and `docs/**` returns no matches. The owned domain is
not expressible in the compiler slice, so a classification pass cannot be the
next artifact and no fixture can exercise the rule yet. A decision document can
be, and is what #907 asks for.

## Detailed design

### The kind lattice

There are exactly two ownership kinds.

```text
Managed   -- reclaimed by the managed heap; duplicable as a reference;
             no cleanup obligation travels with the value
Owned     -- affine; consumed at most once; dropped deterministically at
             scope exit if not consumed
```

The join is defined by absorption:

```text
join(Managed, Managed) = Managed
join(Managed, Owned)   = Owned
join(Owned,   Managed) = Owned
join(Owned,   Owned)   = Owned
```

`Owned` is the top element and the identity is `Managed`, so a join over an
empty set of components is `Managed`. That is why a payload-free ADT
constructor and an empty record are `Managed` without a special case.

**`Copy` is not a point on this lattice.** It is a separate predicate over
`Managed` types, whose extension is fixed by `docs/MEMORY_MODEL.md` §2.1: "The
initial closed Copy set is `Int`, `Float`, `Bool`, and `Unit`. Copy is not
user-implementable. Tuples and records remain non-Copy until a later
type-directed derivation decision." Every member of that set is `Managed`, but
that is an observation about four types, not an edge the classifier computes or
may extend. The `Alternatives` section states the rejected `Copy <= Managed`
formulation and why it is rejected.

### The classification rules

Each rule has a name so a diagnostic can cite the one that fired.

**K-BASE.** A value bound with `let own`, a `take` parameter, and any type
whose declaration names it as a resource are `Owned`
(`docs/MEMORY_MODEL.md` §2.3). Every other primitive, `Text`, and every
ordinary managed-heap value is `Managed` (§2.1, §2.2).

**K-JOIN.** The kind of a record, a tuple, or one ADT constructor payload is
the join over its component kinds. Declaration order does not affect the kind;
it affects drop order only (`spec/records-v1.md`: reverse declaration order).

**K-ANY.** The kind of an ADT is the join over every constructor's payload
join. An ADT is `Owned` if **any** inhabitant can contain an owned value, not
only if every one does. A `match` that reaches a managed constructor of an
owned ADT still consumed an owned value, because the constructor is not known
until run time and the drop obligation is a property of the type.

**K-SUBST.** Substituting an owned type argument into a generic constructor
propagates `Owned` through it. `G[A1, ..., An]` is classified by applying
K-JOIN and K-ANY to `G`'s declaration with each parameter replaced by its
argument's kind. Nesting is resolved innermost-out, so `G[H[T]]` classifies
`H[T]` first and then substitutes the result. The only exception is a
constructor that declares an **explicit, verified ownership transformation**
(K-SHARE is the sole instance in v1); an undeclared or unverified claim is
refused rather than trusted.

**K-PARAM.** An unconstrained type parameter classifies as `Owned`. This is the
conservative direction: a body checked as if its parameter were owned is sound
when a managed value arrives, whereas the reverse silently drops a cleanup
obligation. A constraint may prove a weaker classification, and only a
constraint may.

**K-SHARE.** `share` is the one ownership transformation from the owned domain
to the managed domain, and it consumes its binding
(`docs/MEMORY_MODEL.md` §9: "the original owned binding is taken"). Placing an
owned value into a position that requires `Managed` is a **refusal**, not an
implicit conversion. The result of `share` is `Managed`; deterministic close
after sharing follows the `Shared[T]` protocol §9 names.

**K-LIST.** `List[T]` requires `T` to be `Managed`. An owned `T` is refused in
v1. §10 forbids "leaving the correctness of a file flush to a finalizer", and a
managed `List` of resources has no other cleanup mechanism to offer; the
alternative — an owned collection with deterministic per-element cleanup —
needs drop ordering, partial-consumption state, and panic-path semantics that
no accepted document states. The refusal is explicit so the shape cannot arrive
by accident, which is exactly what #570 asks for: `List[File]` "must never
become an ordinary finalizer-dependent managed list by accident."

**K-COPY.** `Copy` is decided by `docs/MEMORY_MODEL.md` §2.1 and by no rule in
this document. "Contains no owned value" does not derive `Copy`.

### Normative classification table

Every shape #907 §Scope 1 names, with its kind and the rule that produced it.
`M` abbreviates `Managed` and `O` abbreviates `Owned`.

| # | Shape | Kind | Rule |
|---|---|---|---|
| 1 | `Int`, `Float`, `Bool`, `Unit` | `M`, and `Copy` | K-BASE, K-COPY (§2.1 closed set) |
| 2 | `Text`, an ordinary `List`, a graph value | `M`, not `Copy` | K-BASE (§2.2) |
| 3 | a `let own` binding, a `take` parameter | `O` | K-BASE (§2.3) |
| 4 | record, every field `M` | `M` | K-JOIN over fields |
| 5 | record, at least one field `O` | `O` | K-JOIN; this is the rule `spec/records-v1.md` already states |
| 6 | empty record | `M` | K-JOIN over no component is the identity |
| 7 | tuple, every component `M` | `M` | K-JOIN over components |
| 8 | tuple, at least one component `O` | `O` | K-JOIN |
| 9 | ADT, every constructor payload-free | `M` | K-ANY over empty payloads |
| 10 | ADT, single-payload constructor, payload `M` | `M` | K-JOIN then K-ANY |
| 11 | ADT, single-payload constructor, payload `O` | `O` | K-JOIN then K-ANY |
| 12 | ADT, multi-field constructor, every field `M` | `M` | K-JOIN over that constructor's fields, then K-ANY |
| 13 | ADT, multi-field constructor, any field `O` | `O` | K-JOIN then K-ANY |
| 14 | ADT with one `O` constructor and several `M` constructors | `O` | K-ANY: any inhabitant that can contain an owned value decides the type |
| 15 | non-escaping closure capturing `read`/`edit` of an `O` value | `M` | the capture is a borrow, not a transfer; the closure holds no cleanup obligation. Non-escape is §3.1/§7's existing rule, not this one |
| 16 | non-escaping closure capturing only `M` values | `M` | K-JOIN over captures |
| 17 | escaping closure capturing only `M` values | `M` | K-JOIN over captures; §7 permits it |
| 18 | escaping closure capturing a taken `O` value | `O` | K-JOIN over captures; §7 permits the capture, and the obligation travels into the closure |
| 19 | escaping closure capturing `read`/`edit` | refused | §7 already refuses this; no code is allocated here |
| 20 | `Optional[T]`, `T` = `M` | `M` | K-ANY over `None` and `Some(T)`; `Optional[T]` is an ordinary two-constructor ADT per `spec/aggregate-layout-v1.md` |
| 21 | `Optional[T]`, `T` = `O` | `O` | same rule; `Some` can contain an owned value |
| 22 | `List[T]`, `T` = `M` | `M` | K-BASE (§2.2) |
| 23 | `List[T]`, `T` = `O` | refused (`E362`) | K-LIST |
| 24 | `G[T]` for user generic `G`, `T` = `O`, `G` declares no transformation | `O` | K-SUBST |
| 25 | `G[H[T]]`, nested, `T` = `O` | `O` | K-SUBST innermost-out |
| 26 | `G[H[T]]`, nested, every leaf `M` | `M` | K-SUBST innermost-out |
| 27 | `Result[File, IoError]` — the tracked case | `O` | K-SUBST then K-ANY: `Ok(File)` can contain an owned value |
| 28 | unconstrained type parameter `T` | `O` | K-PARAM |
| 29 | `T: Copy[T]` | `M`, and `Copy` | K-PARAM with a constraint |
| 30 | `T: Managed[T]` | `M` | K-PARAM with a constraint |
| 31 | `T: Owned[T]` | `O` | K-PARAM with a constraint |
| 32 | `share(x)` where `x` is `O` | `M` | K-SHARE, the sole transformation (§9) |

No shape in #907 §Scope 1 is left implicit. Rows 15–19 split closures by escape
because §7 already splits them; rows 24–27 split generics by nesting and by
whether the constructor declares a transformation because K-SUBST does.

### Constraint vocabulary

The four bounds #570 asks for, spelled as DD-032 traits and each with a case
that needs it.

DD-032 keeps the `trait` keyword and a local-trait-or-local-outer-type orphan
rule; `docs/TYPE_SYSTEM.md` §Traits lists "auto traits for send/share/copy"
among planned trait capabilities. `docs/MEMORY_MODEL.md` §12 removes the
`send`/`share` members of that list — "No `Send`/`Sync`-equivalent trait" —
which leaves the auto-trait mechanism available for exactly the kind and copy
axis this RFC needs. Kind traits are therefore **method-free auto traits
derived by the classifier**, never written by a user:

```kofun
fn swap[T](take left: T, take right: T) -> Tuple[T, T]        # accept any
fn max[T: Copy[T]](left: T, right: T) -> T                    # must be Copy
fn push[T: Managed[T]](edit values: List[T], value: T) -> Void # must be managed
fn with_close[T: Owned[T]](take value: T) -> Void             # must be owned
```

The spelling `T: Trait[T]` is the one the landed trait frontend accepts;
`tests/conformance/traits/positive.kofun` writes
`fn same[T: Equal[T]](left: T, right: T) -> Bool`, and
`tests/conformance/traits/multiple_bounds.stderr` shows that a second bound is
refused today with "a second bound is unsupported in this trait frontend
slice". The four kind bounds are mutually exclusive single bounds, so they fit
that shape without needing conjunction: `Copy[T]` already implies `Managed[T]`
as a fact about §2.1's closed set, so no program needs to write both.

| Bound | Meaning | A case that needs it |
|---|---|---|
| none | accept any; the body is checked as if `T` were `Owned` (K-PARAM) | a passthrough that neither duplicates nor discards its argument, such as `swap`, which must stay correct when someone instantiates it over a socket |
| `T: Copy[T]` | `T` is in §2.1's closed set | generalizing the landed collections. `stdlib/list/list.kofun` states it is "deliberately specialized to `List[Int]`. Int is Copy, so reads, callback arguments, and returned elements do not pretend that generic non-Copy element borrowing is already specified or implemented"; `stdlib/array/array.kofun` and `stdlib/tuple/tuple.kofun` carry the same note. `T: Copy[T]` is the bound those three comments describe |
| `T: Managed[T]` | `T` carries no cleanup obligation | any element type of `List[T]` (K-LIST). `FakeClock.waiters: List[Waiter]` in `stdlib/clock/adapters.kofun` is the landed instance: the list is legal exactly because `Waiter` is managed |
| `T: Owned[T]` | `T` must carry a cleanup obligation | a scope-cleanup combinator whose entire purpose is deterministic close. Unconstrained `T` would accept a managed argument and silently do nothing useful; `T: Owned[T]` refuses it at the call site |

The difference between "no bound" and `T: Owned[T]` is direction, and both are
needed. No bound means *may be owned, so treat it as owned*; `T: Owned[T]`
means *must be owned, so a managed argument is rejected*.

DD-032's orphan rule does not bind here, because no package writes
`impl Managed[T] for X`: the classifier is the sole derivation source, one
derivation per fully resolved type, so the coherence key DD-032 defines has
exactly one inhabitant by construction. This RFC **references** DD-032 as the
eventual carrier and does not depend on it: if kind bounds ship before traits,
they ship as a closed built-in constraint set with the same four meanings, and
migrate to traits without changing which programs are accepted.

### Diagnostics name a path, not a verdict

Every owned classification is reported as the chain of steps that produced it,
because "this type is owned" is not repairable information. The path notation:

| Step | Written | Meaning |
|---|---|---|
| record field | `Session.socket` | the field `socket` of record `Session` |
| ADT constructor payload | `Frame.Open.handle` | the payload field `handle` of constructor `Open` of ADT `Frame` |
| tuple component | `(Int, File)#2` | the component at 1-based position 2 |
| type argument | `Pair[Int, File]#2` | the type argument at 1-based position 2 |
| closure capture | `closure.file` | the capture named `file` |

Steps compose left to right with ` -> `, ending at the owned leaf:

```text
Session.frames -> List[Frame]#1 -> Frame.Open.handle -> File is owned
```

A path is required, and is required to be minimal: the first owned component
found in declaration order, then the first owned component of that, and so on.
Reporting a different owned component on a rerun is a defect, because a
classification a reader cannot reproduce is not an explanation.

### Interaction with the existing affine rules

The classification decides *which types are affine*. What affinity then means
is unchanged and is not restated here:

- consumption, drop at scope exit, and the `uninitialized -> live -> taken -> dropped`
  state machine are §2.3 and §4;
- branch, loop, and early-return cleanup are §5 and §6;
- drop order inside a composite is reverse declaration order,
  `spec/records-v1.md`;
- partial moves and use-after-`take` are the conditions `spec/records-v1.md`
  registers as `E2S122` and `E2S123` for records. This RFC widens the set of
  types those conditions apply to; it allocates no new code for them, because
  the condition is the same condition.

One clarification the widening forces, stated normatively below: consuming
destructuring is accepted and projection without consumption is not.

## Semantics

Let `kind(T)` be the ownership kind of type `T`, computed by K-BASE, K-JOIN,
K-ANY, K-SUBST, K-PARAM, K-SHARE, and K-LIST. Classification is a property of
the type, is decided before any value exists, and is identical in every
backend, at every optimization level, and under monomorphized or dictionary
lowering — `spec/roadmap-31-34/generics-and-traits.md` requires a specialization
to "be removable without changing whether a program type-checks", and kind is
part of type-checking, so the two lowerings agree by that rule rather than by a
second one written here.

A program is accepted only if every position that requires `Managed` receives a
`Managed` type. The positions that require `Managed` in v1 are: the element
type of `List[T]`; any type argument bound `Managed[T]` or `Copy[T]`; and the
argument of any construct that produces a managed aggregate from it. Everything
else accepts either kind.

**Constructing an owned composite is accepted.** Building a record, tuple, or
ADT constructor over an owned component produces an owned value. The refusal
arrives at the point where `Managed` is required, not at the construction. This
is the precise reading of #570's "merely placing an owned value in a GC object
must not silently make cleanup nondeterministic": the object stops being a GC
object, and if the position demanded a GC object, the program is refused.

**Consuming destructuring is accepted; projection without consumption is not.**
`match owned_adt { Ok(handle) => ... }` consumes the scrutinee and rebinds its
payload, which is one whole-value transfer plus a binding, and is accepted —
this is what `stdlib/tests/file_roundtrip.kofun` already writes. `take pair[0]`
and `take record.field` are projections that leave the container partially
consumed, and are refused under the existing partial-move condition. A `match`
on an owned scrutinee consumes it on every arm, including arms whose
constructor carries no payload.

**Drop of an owned composite** drops its owned components in reverse
declaration order, recursively, and drops nothing for managed components. For
an ADT, the components are those of the constructor the value actually holds.

**`share` is the only transition.** `share(x)` consumes `x` and yields a
`Managed` value. There is no implicit transition in either direction: a
`Managed` value never becomes `Owned`, and an `Owned` value becomes `Managed`
only through `share`.

Deliberately left undefined: the byte encoding of any kind (it is a property of
the type, not of the value — `spec/aggregate-layout-v1.md` states that
`pointers` and `drop` are "properties of `TypeLayout`, not bytes inside the
object", and kind joins that group); the order in which independent owned
components of *different* bindings are dropped relative to each other; whether
a future `Copy` derivation for aggregates exists at all, which §2.1 reserves;
and the classification of any type introduced by a later RFC that declares its
own ownership transformation, which that RFC owns.

## Diagnostics

New refusals, in the `E3xx` ownership family. `docs/MEMORY_MODEL.md` §13
records that "`E3xx` is not a live family. No `E3xx` code has ever been in
`tests/diagnostics/registry.tsv`", and that the historical `E330` names history
rather than a live diagnostic. RFC-0001 reserves `E340`–`E344` and RFC-0002
reserves `E350`–`E356`, so this proposal takes `E360`–`E364`. The band is
unused: `grep -c 'E36' tests/diagnostics/registry.tsv` returns `0`, and
`cut -f1 tests/diagnostics/registry.tsv | grep -cE '^E3'` returns `0`, so no
`E3xx` code of any kind is registered today.

| Code | Refusal | Message shape |
|---|---|---|
| `E360` | an `Owned` value reaches a position that requires `Managed` | names the position and its requirement, the owned type, and the minimal propagation path to the owned leaf; suggests `share` where §9 applies, and otherwise names restructuring |
| `E361` | an `Owned` type argument is substituted for a parameter bound `Managed[T]` or `Copy[T]` | names the constructor, the parameter, the argument, the bound, and the propagation path **inside** the argument, so a caller learns which nested field made the argument owned |
| `E362` | `List[T]` is instantiated with an `Owned` `T` | names the element type and its owned component, states that v1 has no deterministic element cleanup, and cites §10's finalizer prohibition as the reason rather than an implementation gap |
| `E363` | a value of unconstrained type parameter kind reaches a position that requires `Managed` | names the parameter, the position, and that K-PARAM classified it `Owned` because it carries no constraint; the repair is a `Managed[T]` or `Copy[T]` bound, which is a different repair from `E360`'s |
| `E364` | a generic constructor claims an ownership transformation it does not evidence | names the constructor, the claimed transformation, and the evidence that is absent; `share` (§9) is the only transformation with evidence in v1 |

`E365`–`E369` stay unallocated in this band.

Four conditions are deliberately **not** given new codes, because they are
existing conditions applied to more types:

| Misuse | Refusal it maps to |
|---|---|
| hiding an owned value inside a managed aggregate | `E360` — the aggregate becomes owned, and the position that wanted a managed one refuses it |
| implicit sharing | `E360` — no implicit `Owned` to `Managed` transition exists (K-SHARE); the repair is a written `share` |
| duplicate destruction | the use-after-`take` condition `spec/records-v1.md` registers as `E2S123`, now reached through any owned composite rather than records alone |
| partial-move misuse | the partial-move condition `spec/records-v1.md` registers as `E2S122`, now reached through tuple indices and ADT payload fields as well as record fields |
| an escaping closure capturing a `read`/`edit` view | `docs/MEMORY_MODEL.md` §7's existing rule; this RFC classifies closures, it does not restate that refusal |

Every code above must print its propagation path. A diagnostic that reports
only a kind does not satisfy this section, and a production frontend inherits
the *conditions* and the path requirement, not necessarily the code numbers —
the discipline `spec/records-v1.md` §Diagnostics already states for `E2S1xx`.

## Ownership and effects

Interaction with `read`, `edit`, `take`, and affine resources is the whole
subject of this proposal, so the interesting statements are the boundaries.

- **Modes are unchanged.** `read` and `edit` are non-owning views (§3.1, §3.2)
  and produce no kind change: a `read` of an owned record is a borrow of an
  owned record, and row 15 classifies a closure holding one as `Managed`
  because it holds no obligation. `take` (§3.3) is the transfer this
  classification decides the scope of.
- **Affinity is inherited, not redefined.** What it means for a type to be
  affine is §2.3 and §4. This RFC decides only which types are.
- **Effects are untouched.** No effect label is added, removed, or inferred
  differently. Classification is a typing property with no row component, so it
  composes with #556's lattice whatever that lattice becomes, and it does not
  pre-empt RFC-0001's `alloc` label.
- **No auto trait for concurrency.** `docs/MEMORY_MODEL.md` §12 states that
  neither a `Send`-equivalent nor a `Share`-equivalent is planned, and gives the
  reason: with no raw pointers in safe code, no interior mutability, and no
  non-atomic refcounted pointer, "the derivation has no exceptions and the trait
  carries no information." #570's acceptance bullet naming that integration is
  therefore superseded, not inherited, and this RFC proposes no such trait. The
  kind traits above are a different axis: they carry cleanup obligation, which
  is information the compiler cannot derive from any other property.
- **Scoped parallelism.** RFC-0003 applies the existing exclusivity rule to
  simultaneously live task captures. Kind decides which captures carry a cleanup
  obligation across a `spawn`; it does not change RFC-0003's conflict table, its
  place-overlap rules, or its join barrier.
- **FFI layout.** Kind is a property of `TypeLayout` in the sense
  `spec/aggregate-layout-v1.md` uses for `pointers` and `drop` — computed from
  the type, encoded in no user-visible byte. This RFC changes no size,
  alignment, offset, tag width, or pointer bitmap, and adds no descriptor field;
  whether the `drop` field grows a third value is left open below.

## Alternatives

1. **`Copy <= Managed` as a three-point lattice — the candidate #570 offers.**
   Rejected. It fails on three separate grounds, any one of which is
   sufficient.

   *It either does nothing or pre-empts a reserved decision.* If `Copy` is the
   bottom of a structural join, then a join over two `Copy` components must
   produce something. Producing `Managed` makes the `Copy` point unreachable by
   composition, so it carries no information the lattice can use. Producing
   `Copy` is a type-directed `Copy` derivation for aggregates — and
   `docs/MEMORY_MODEL.md` §2.1 states that "tuples and records remain non-Copy
   until a later type-directed derivation decision", which is a decision it
   explicitly reserves. A lattice cannot both compute a join and leave that
   reserved.

   *It needs variance the type system does not have.* Reading `<=` as a subtype
   relation immediately raises whether `List[Copy]` relates to `List[Managed]`.
   `spec/roadmap-31-34/generics-and-traits.md` describes an M2-alpha with no
   blanket implementations, no negative implementations, no specialization, and
   no ordered fallback; there is no variance rule to answer with. Reading `<=`
   as a non-subtyping order instead makes it a two-element order plus an
   annotation, which is the orthogonal design under a different name.

   *It reads "contains no owned value" as `Copy`.* That is precisely the
   inference §2.1 refuses, and it is the inference a structural join over a
   `Copy` bottom most naturally produces.

   **The trade-off accepted by rejecting it.** Two axes cost more than one. A
   caller who wants "cheap to duplicate, or at least not owned" writes two
   different bounds rather than one, and if `Copy` derivation for aggregates is
   ever decided, it arrives as a second computation over the same structure
   rather than falling out of the join already defined. That is real duplicated
   machinery, and it is the price of not deciding §2.1's reserved question
   inside a lattice diagram.

2. **`Copy` as a fourth kind alongside `Managed` and `Owned`, unordered.**
   Rejected. It has the same two-axis cost as the accepted design and adds an
   incoherence: every `Copy` type is also managed by the GC's rules, so a
   classifier would have to answer "is `Int` managed" with "no, it is Copy",
   which is false about how `Int` is stored and reclaimed.

3. **Declared kinds instead of structural inference — a type says
   `owned type Session = { ... }`.** Rejected. It permits a record over a socket
   to declare itself managed, which is the exact soundness hole this
   classification closes, and it makes the answer to "why is this owned"
   unavailable: there is no path to report, only a declaration to point at.
   Austral's structural, viral linearity is the prior art #570 cites, and the
   viral part is the part that carries the guarantee.

4. **An unconstrained type parameter classified as `Managed`.** Rejected. It is
   the unsound direction. A body checked as managed drops the cleanup
   obligation of any owned argument, and the error surfaces at instantiation
   sites the author of the generic never saw. K-PARAM's conservative direction
   costs an occasional unnecessary bound; the alternative costs a leaked
   resource with no diagnostic.

5. **`List[T]` with an owned `T`, made managed with finalizer cleanup.**
   Rejected. `docs/MEMORY_MODEL.md` §10 lists "leaving the correctness of a file
   flush to a finalizer" among forbidden designs, and #570 names this exact
   silent outcome as the thing that must never happen by accident.

6. **`List[T]` with an owned `T`, as an owned collection with deterministic
   element cleanup.** Deferred, not rejected. It is the right long-term answer
   and it needs decisions this RFC does not have: element drop order, partial
   consumption state after removing one element, panic-path semantics with a
   half-drained list, and the interaction with in-place reuse (#576). Refusing
   it now with `E362` keeps the door open; accepting it now would freeze
   answers nobody has measured.

7. **Making the classification implicit and unreported — a bare kind with no
   path.** Rejected. #570's acceptance criteria require diagnostics to show the
   field, variant, capture, or type argument that caused propagation, and a
   verdict cannot satisfy that. This is also the practical failure mode of viral
   properties in other languages: the property is correct and the error message
   is unactionable.

8. **Do nothing.** Rejected. `Result[File, IoError]` already appears in tracked
   source with no stated kind, `stdlib/clock/adapters.kofun` already pays a
   run-time generation counter for a compile-time property, and every future
   composite over a resource decides its own answer. The gap does not stay
   theoretical; it accumulates incompatible local conventions, which is what
   #570 opened to prevent.

## Drawbacks

- **Two axes to teach.** A learner meets `Managed`/`Owned` and then meets
  `Copy` as a separate closed set, rather than one ordered chain. The rejected
  alternative reads better on a slide and is wrong for the reasons above; the
  cost is real and lands on documentation.
- **Viral classification surprises people.** One owned field twelve levels down
  makes an outer type owned, and the outer type's author may not have known the
  field existed. The propagation path is the mitigation, and it is a mitigation
  rather than a fix.
- **`E362` refuses a shape people will want on day one.** `List[File]` is an
  obvious thing to write. The refusal is deliberate, it has no workaround
  inside the language other than restructuring or `share`, and it will be
  reported as a missing feature.
- **K-PARAM makes bounds necessary in places that look like they should not
  need them.** A generic helper that only ever sees `Int` still classifies its
  parameter as owned and may need `T: Managed[T]` written to compile, which
  reads as ceremony until the reason is explained.
- **The kind traits are unimplementable by users but occupy trait syntax.**
  Someone will try `impl Managed[T] for MyType`, and the refusal has to be
  taught rather than derived from DD-032's orphan rule, which is about
  ownership of declarations rather than about auto traits.
- **Nothing here is executable.** #570's own measurement shows `let own x = 1`
  is refused by Stage 2, so no fixture can exercise a single row of the table
  until the owned domain parses. The table is a contract against a future
  implementation, and the gap between them is where drift happens.

## Non-goals

This RFC deliberately does not decide, and must not be read as deciding:

- **Allocator authority and region provenance.** RFC-0001 separates four facts
  and states that "Region lifetime is not ownership: an owned resource
  allocated from an arena is still affine, still dropped deterministically —
  and still may not outlive the arena." This RFC classifies a type by what it
  contains; where its storage comes from and how long that storage lives are
  RFC-0001's facts, built executably by #899. Nothing here restates, extends,
  or contradicts the region-escape rules or `E340`–`E343`.
- **Borrowed results returned from functions.** #571 owns them, and its own
  scope statement hands the lattice back here: it lists "#570's kind lattice
  and #555's task captures" as out of its scope. This RFC classifies types by
  their contents; a return-position view is that issue's contract, including its
  prohibition on storing a borrowed result in a managed or owned aggregate.
- **Environment authority.** #569 and RFC-0002.
- **Any implementation.** No compiler stage, standard-library type, backend, or
  `release/claims.json` capability claim. `docs/MVP_IMPLEMENTED.md` records
  general ownership and law checking as `open` with "no active general pass",
  and that stays true after this proposal lands.
- **A `Send`- or `Share`-equivalent auto trait.** `docs/MEMORY_MODEL.md` §12
  records that neither is planned.
- **Optimization-only moves and in-place reuse.** §14 draws the line between
  semantic `take` and managed-value moves — "No optimization level, backend, or
  analysis improvement may infer a `take` away or weaken its diagnostics" — and
  #572 owns the first, #576 the second. Kind classification changes neither.
- **User-facing `Copy` derivation surface.** §2.1 reserves whether aggregates
  ever derive `Copy`. This RFC states the lattice relation and nothing more.
- **Call-site mode annotation.** Whether `take` must also be written at call
  sites stays §3.3's open UX question.
- **Numeric compiler diagnostic allocation in
  `tests/diagnostics/registry.tsv`.** The codes above are this document's
  stable identifiers; the implementation child registers them with fixtures,
  emitters, and goldens.

## Compatibility and migration

**Category: conditional.**

The proposal adds refusals to types that already exist, so it is not purely
additive. The shape that would break is precise: a program that places an owned
value inside a record, tuple, ADT payload, closure capture, `Optional`, `List`,
or generic instantiation, and then uses that composite in a position requiring
`Managed`. The tracked corpus is counted rather than estimated. At
`6f71b6df5cf54aa16542b89494d2194c4172a97e`:

```sh
git grep -lE '^[[:space:]]*let[[:space:]]+own[[:space:]]' -- '*.kofun' | wc -l
# 5

git grep -nE '\b(trait|impl)[[:space:]]+(Copy|Managed|Owned)\b|:[[:space:]]*(Copy|Managed|Owned)\b' -- '*.kofun' | wc -l
# 0

git ls-files -- '*.kofun' | wc -l
# 824
```

Five tracked sources of 824 bind an owned value at all:
`examples/ownership.kofun`, `stdlib/tests/file_roundtrip.kofun`,
`tests/conformance/syntax/issues_35_47/structural_surface.kofun`,
`tests/conformance/syntax/issues_35_47/unsupported_owned_binding.kofun`, and
`tests/kofun/ownership.kofun`. Each was read. None places its owned binding in a
record, tuple, ADT payload, list, closure capture, or generic instantiation;
four pass it directly to a `take` parameter or leave it to scope cleanup, and
`stdlib/tests/file_roundtrip.kofun` binds it out of a matched
`Result[File, IoError]`, which row 27 classifies `Owned` and which the
consuming-destructuring rule accepts unchanged. The count of tracked programs
carrying the refused shape is therefore **0**.

The second query counts collisions with the four constraint names in
declaration or bound position: **0**. `Copy` appears in tracked `.kofun`
sources only inside comments — `stdlib/list/list.kofun`,
`stdlib/array/array.kofun`, `stdlib/tuple/tuple.kofun`, and the `E007` message
text in `bootstrap/stage2/compiler.kofun` — and never as a declared trait or a
bound.

Migration for the shape that does break, when an implementation exists: replace
the managed-position use with a written `share` (§9) where a shared handle is
what was wanted; restructure a `List[T]` of resources into scope-owned handles
or a managed handle list produced by `share`; and add a `Managed[T]` or
`Copy[T]` bound where a generic was implicitly assumed non-owned. No migration
action is required today, because the count above is 0 and because the owned
domain does not parse.

One boundary is worth stating plainly. `stdlib/clock/adapters.kofun` would
become expressible differently under this classification — its generation-token
records could become owned types with the affinity enforced at compile time —
but that is an opportunity, not an obligation, and this RFC changes nothing in
that module. `task clock-adapters` passes before and after with no edit.

## Implementation plan

Acceptance does not implement this RFC, and nothing below may be read as
scheduled. The ordering exists so each step is separately reviewable and each
lands with its own gate.

1. **The owned domain must parse first.** #570's measurement is the blocker:
   `let own x = 1` is refused with ``error[E2S11]: expected `=` ``. Until `own`
   bindings and `take` parameters are accepted by a compiler slice, no
   classification pass has an input, and no row of the table can be fixtured.
   This step belongs to the Stage 2 child #570 describes, not to this RFC.
2. **A deterministic classification model, before any compiler pass.** In the
   shape of `spec/concurrency/scoped-parallelism-v1/`: a canonical input
   describing type declarations, a canonical classification result, and
   positive and negative fixtures for every row of the table. This is where the
   table stops being prose, and it needs no compiler surface.
3. **Kind computation in the frontend**, over declarations only: K-BASE,
   K-JOIN, K-ANY. Records already carry an "ownership/drop class" in typed IR
   per `spec/records-v1.md` §Representation, so this extends an existing field
   rather than adding a concept.
4. **Generic substitution**: K-SUBST and K-PARAM, with `E361` and `E363`, after
   the trait frontend can express a bound whose meaning is a kind.
5. **The refusals**: `E360`, `E362`, `E364`, each with a negative fixture and a
   pinned `.stderr` in the convention of `tests/conformance/records/`, and each
   asserting the propagation path rather than only the code.
6. **Registration**: the five codes enter `tests/diagnostics/registry.tsv` with
   emitters, fixtures, and goldens, gated by `task diagnostics`.
7. **`share` and the transformation check** (K-SHARE, `E364`), last, because
   verifying a declared transformation needs the four steps above.

The Taskfile, the compiler pair, `release/claims.json`, and
`docs/MVP_IMPLEMENTED.md` are unchanged by this proposal. The ledger row
carries no `implementation` object.

## Validation

What passing gates proves here is narrow, and stating that is part of the
contract. This proposal's gates prove that the decision is recorded honestly —
not that any classification runs.

| Layer | Command | Evidence |
|---|---|---|
| Ledger schema and semantics | `sh tests/rfc/check-registry.sh` | RFC-0004 is counted `proposed`, carries no implementation record, carries `opened_on` alone while proposed, and every mutation stays refused — including `proposed-claiming-a-decision-date` and `proposed-claiming-a-closed-review`, which is why this row carries no closing or decision date |
| Focused ledger gate | `task rfc-registry` | green with the new row and its review dates |
| Diagnostics | `task diagnostics` | unchanged; `E360`–`E364` are proposed identifiers and are deliberately **not** registered by this RFC, because registering a code no emitter produces would be a claim of behaviour |
| Claim boundary | `task release-claims` | unchanged; no capability claim gained or lost |
| Records contract | `task records` | unchanged; the record rule this RFC generalizes still gates |
| Clock adapters | `task clock-adapters` | unchanged; the affine-capability idiom still passes untouched |
| Regression | `task verify` | no regression |

The gate that will eventually prove the *behaviour*, and become the ledger's
`implementation` record, is step 2's model check plus step 5's refusal corpus.
Its negative boundary is the set of mutations that would each collapse one rule:
a `List[File]` that classifies managed (K-LIST), an unconstrained parameter that
classifies managed (K-PARAM), an ADT whose owned constructor is ignored because
another constructor is payload-free (K-ANY), a nested generic classified only at
its outer layer (K-SUBST), and an owned value entering a managed aggregate
without `share` (K-SHARE). Each must be refused, and each refusal must print its
propagation path.

## Unresolved questions

Two remain, each with what settles it. Neither blocks the decisions above.

1. **Whether the layout descriptor's `drop` field grows a third value.**
   `spec/aggregate-layout-v1.md` defines `drop` as "`trivial` when `pointers` is
   empty, otherwise `managed`", which has no way to say `owned`. Whether owned
   types need a third value, or whether kind stays outside the layout
   descriptor entirely, is settled by DD-033's contract and its golden vectors
   when the first owned type reaches a backend — not here, because adding a
   descriptor field changes every golden vector on every target and this RFC
   changes no bytes.
2. **Whether a user-declared ownership transformation is ever admitted beyond
   `share`.** K-SUBST reserves the possibility and `E364` refuses an
   unevidenced claim, but what "verified" means for a user-written
   transformation — what evidence, checked by what — is left open. It is
   settled by a later proposal that has a concrete second transformation to
   point at; inventing the verification rule with one instance would be
   designing against a sample of one.

Everything else #907 raises is answered above: the classification table covers
every shape in its Scope 1, the lattice question is decided with its rejected
alternative, the constraint vocabulary is stated with a case for each spelling,
the `List[File]` boundary is an explicit refusal, and every new diagnostic
carries a code, a message shape, and the component it names.

A substantive change to any normative rule above restarts the review window
rather than being folded into implementation. Until review closes on 2026-08-16
and the ledger state is updated after an explicit decision, RFC-0004 remains
`proposed`.
