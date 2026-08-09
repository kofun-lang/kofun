# RFC-0001: Allocator choice is a scoped, effect-tracked capability

- Shepherd: hjosugi
- Opened: 2026-08-01
- Status: accepted
- Decided: 2026-08-09

Proposal for [#573](https://github.com/kofun-lang/kofun/issues/573). Review opened with the ledger's announced window; it closes when the
shepherd closes it, and the ledger records that day.

## Summary

Allocation in Kofun becomes four separately named facts. An inferred `alloc`
**effect** answers "may this allocate". A borrowed `Alloc` **capability**
answers "where, and under whose policy". The existing three memory domains of
[`docs/MEMORY_MODEL.md`](../docs/MEMORY_MODEL.md) keep answering "who owns and
frees the result". A **region** carried by temporary allocators answers "how
long the backing store lives". Ordinary application code keeps the managed
default and writes no allocator parameters. Allocation-sensitive APIs declare
an explicit borrowed allocator capability, and a visible lexical
`with allocator = ...` scope can supply that argument ergonomically without
becoming an ambient context: the scope is source-visible, appears in inferred
effects and contracts, and is projectable by tooling. The no-GC profile of
`docs/MEMORY_MODEL.md` §1 becomes checkable: every potentially allocating path
must resolve to an allowed allocator or the program is refused. Odin's
universally implicit per-scope `context` is examined and rejected.

## Motivation

Three goals this repository has already written down cannot currently be
connected to each other.

First, [`docs/MEMORY_MODEL.md`](../docs/MEMORY_MODEL.md) §1 promises both "ordinary
application code can be written as if in a GC language" and "a no-GC profile
can be reached for embedded, real-time, and high-performance use". Nothing in
the model says how the second is checked. §2.2 lists arena allocation among
the optimizations the compiler may apply, but there is no source-level way to
require, forbid, supply, or observe an allocator.

Second, [`docs/STANDARD_LIBRARY_CHARTER.md`](../docs/STANDARD_LIBRARY_CHARTER.md)
makes "No ambient authority" and "Pay for what you use" engineering rules, and
[`stdlib/clock/adapters.kofun`](../stdlib/clock/adapters.kofun) has landed the
idiom those rules imply: "A capability is passed, never ambient. There is no
`now()`." Allocation is currently the largest remaining ambient facility.
Dependency code allocates whatever it likes from the managed heap, and no
caller can meter, quota, trace, or redirect it.

Third, [`docs/stdlib/benchmark.md`](../docs/stdlib/benchmark.md) already specifies
that allocation counters attach to benchmark reports "when a provider (#398,
#476) exists for the running backend". There is no allocator identity for such
a provider to report, so the counter fields the schema reserves cannot be
filled honestly.

Odin demonstrates the practical value of interceptable allocation: procedures
receive an implicit per-scope `context`, built-ins allocate from its
allocator, and a temporary allocator plus arenas, pools, and stacks come in
the box. Recent Odin core library design moves allocation-returning OS APIs
toward explicit allocator parameters so ownership of returned memory is
clear. Kofun should adopt the interception, and must not adopt the universal
implicitness, for three reasons that are already recorded decisions here:

- **Capability authority (#569).** An effect says what a function may do; a
  capability says whether this caller has authority to do it. An implicit
  context that every callee silently receives is ambient authority for
  allocation policy — exactly what #569 removes for environment, filesystem,
  and network access, and what the charter's "No ambient authority" rule
  forbids for the standard library.
- **Effect visibility (#556).** The language vision document (moved to `kofun-lang/kofun-site` by #874)
  commits to inferred effects "visible at the API boundaries that need them"
  and to a two-point `pure`/`io` lattice "designed as a degenerate row so it
  can widen later". A dynamically scoped context is invisible to that
  discipline: it changes callee behavior with nothing in any signature,
  contract, or inferred row.
- **Cost-explaining boundaries.** The charter requires parsers and protocols
  to carry adversarial limits and typed `Result` errors, and
  [`stdlib/json/README.md`](../stdlib/json/README.md) documents fixed nesting
  limits precisely so "adversarial resource use" is explicit. An API whose
  allocation source is decided by a hidden caller-side variable cannot state
  its costs at the boundary.

## Detailed design

### The four concerns, separated

The design keeps four facts apart because conflating any two of them produces
a defect this repository already refuses elsewhere.

1. **Allocation effect — "may allocate".** `alloc` is an inferred effect
   label, the first widening of the degenerate-row lattice planned in
   the language vision document. In the conceptual notation of
   [`docs/TYPE_SYSTEM.md`](../docs/TYPE_SYSTEM.md) §Effects, a decoding function
   reads `Text -> JsonValue ! {alloc, error[JsonError]}`. The absence of
   `alloc` is the guarantee: a function without it allocates on no path.
   Presence is an upper bound, not a promise to allocate.
2. **Allocator authority — "where, and under whose policy".** An `Alloc`
   capability value names one allocator instance. Holding it is the authority
   to allocate from that instance; not holding any is the inability to choose.
   Effect and authority are related but distinct, exactly as #569 separates
   `! io` from an I/O capability parameter: a function can carry `alloc`
   (it allocates from the managed default) while holding no `Alloc` value at
   all, and a function handed an `Alloc` it never uses stays allocation-free.
3. **Memory ownership — "who owns and frees the result".** The three domains
   of `docs/MEMORY_MODEL.md` §2 are unchanged: Copy values, managed values,
   and affine owned resources. This RFC adds only a distinction the standard
   library must document per API: **caller-owned result allocation** (the
   result's storage comes from the capability the caller passed, and the
   caller's domain rules govern it) versus **private bookkeeping** (scratch
   the callee allocates and releases internally, never owned by the caller).
   The Odin core:os redesign is the prior art: returned memory takes an
   explicit allocator precisely so its ownership is clear.
4. **Region lifetime — "how long the backing store lives".** A temporary or
   arena allocator carries a **region**: a lifetime bound tied to a lexical
   scope. Values whose storage comes from a region allocator are
   region-tagged and cannot outlive the region's reset. Region lifetime is
   not ownership: an owned resource allocated from an arena is still affine,
   still dropped deterministically — and still may not outlive the arena.

A worked contrast: `json_decode` under a quota allocator and under an arena
has the same effect (`alloc`), different authority; its decoded result under
an arena and under the managed heap has the same ownership rules (a managed
value), different region lifetime; the decoder's internal scratch and its
returned value can come from the same arena with the same region, different
ownership. No two of the four facts can substitute for each other.

### The layered model

Layer by layer, as #573 frames it, adapted to the syntax this repository
actually uses (declaration-site `read`/`edit`/`take` parameter modes per
`docs/MEMORY_MODEL.md` §3; snake_case executable seeds like
[`stdlib/json/json.kofun`](../stdlib/json/json.kofun); dotted target-design
notation as in `docs/TYPE_SYSTEM.md` §Effects).

**1. The managed default stays parameter-free.** Ordinary application code
allocates managed values exactly as `docs/MEMORY_MODEL.md` §2.2 describes,
writing no allocator parameters. This is not ambient *authority*: using the
profile's default heap chooses no policy and grants no interception right.
The managed heap is itself one allocator instance, owned by the runtime, and
its policy handle derives from the runtime-created root capability of #569 at
the `main` boundary — which is what makes process-level quota and tracing
interposition possible without touching dependency source (§Validation,
criterion V4).

**2. Allocation-sensitive APIs take an explicit borrowed capability.**

```kofun
fn json_decode_in(
    edit alloc: Alloc,
    read input: Text,
) -> Result[JsonValue, AllocFailure[JsonError]]
```

The borrow mode is `edit`, not the `read` of #573's sketch: allocating
advances allocator state (an arena bumps, a quota debits), and
`docs/MEMORY_MODEL.md` §3.2 both records mutation as an effect and grants
`edit` exclusivity. That exclusivity is a feature, not a cost: it is what
makes an arena data-race free with zero internal synchronization, and under
the scoped parallelism of `docs/MEMORY_MODEL.md` §12 it forces sibling tasks
onto per-task sub-arenas instead of silently contending on one bump pointer.
Read-only inspection (remaining quota, high-water statistics) borrows `read`.

**3. A visible lexical scope supplies the argument ergonomically.** The
candidate surface of #573, adapted:

```kofun
with allocator = Arena.scoped(authority) {
    let value = Json.decode(allocator, input)?
    let terse = Json.decode(input)?    # scope supplies `allocator`
    use(value)
}   # arena resets here; `value` and `terse` cannot reach this line
```

(`Arena.scoped` declares `edit authority: AllocAuthority`, and `Json.decode`
declares `edit alloc: Alloc`; modes stay on declarations, as
`docs/MEMORY_MODEL.md` §3.3 currently decides, unlike the call-site `read`
of #573's sketch — see §Non-goals.)

Grammar, in the style of [`spec/grammar.ebnf`](../spec/grammar.ebnf), with
`with` contextual in this position exactly as `law`, `impl`, and `check` are
contextual in theirs:

```ebnf
with_scope = "with", identifier, "=", expression, block ;
```

The supply rule is **lexical and compile-time**: inside the block, a call
whose signature declares an elidable `Alloc` parameter may omit that
argument, and the compiler inserts the innermost enclosing scope's binding.
Nothing dynamic happens. A callee outside the block's source text receives
nothing; a callee inside it that declares no `Alloc` parameter receives
nothing; nested scopes shadow innermost-first. The scope binds its allocator
as an affine owned resource (`docs/MEMORY_MODEL.md` §2.3) and resets or drops
it deterministically at scope exit — including the early exit of a `?`
propagation, which [`spec/result-propagation-v1.md`](../spec/result-propagation-v1.md)
already requires to run scheduled cleanup. This is the `with`-equivalent
resource scope that `docs/MEMORY_MODEL.md` §10 names as the intended
replacement for finalizer-based cleanup.

The scope is inspectable because it cannot be hidden. Constructing any
non-default allocator requires an `AllocAuthority` capability (derived,
attenuated, from #569's root or from a more powerful allocator authority), so
every scope's allocator traces back through explicit parameters to `main`.
The enclosing function's inferred row carries `alloc`; the discovery and
sidecar tooling of DD-029 and DD-028 project scope extents and supplied call
sites the same way they project other compiler-derived facts.

**4. The no-GC profile closes the default.** Under the no-GC profile, the
managed-heap instance is absent from the allowed-allocator set, so every path
carrying `alloc` must resolve to an explicit allowed allocator; a path that
would reach the managed default is refused with `E342` at compile time. This
turns `docs/MEMORY_MODEL.md` §1's no-GC goal from an aspiration into a gate.

**5. Temporary and arena allocators carry a non-escaping region.** A value
whose storage comes from a region allocator is region-tagged. Region-tagged
values obey the discipline this repository already applies to `read`/`edit`
views — "in v1, a view cannot escape the function" (`docs/MEMORY_MODEL.md`
§3.1) and the closure-capture rules of §7 — with the `with` scope as the
boundary: no return, no assignment to an outer binding, no capture by an
escaping closure, no storage into a container that outlives the scope.
Escape is refusal `E340`; the sanctioned exit is the explicit `promote` copy
(§Decisions, Q3).

**6. Caller-owned results versus private bookkeeping.** A standard-library
API that returns caller-owned storage takes the allocator that owns the
result explicitly (`json_decode_in` above). An API's private scratch is its
own business, must be released before return or owned by its own documented
region, and must not be charged to the caller's capability undocumented.
Every capability-taking stdlib signature documents which of the two each
allocation is; that documentation is checkable surface (§Validation, V7).

**7. Allocation failure is explicit, and split exactly as the repository
already splits it.** The observed policy: anticipated, adversarial, or
policy-limited conditions are typed `Result` errors — `stdlib/json/json.kofun`
returns `NestingLimitExceeded` rather than dying, `stdlib/clock/adapters.kofun`
returns `ClockArithmeticOverflow` rather than wrapping, and the charter
forbids undocumented sentinels — while violated machine invariants on the
ordinary path are runtime errors with one canonical diagnostic line and exit
status 1, as [`spec/semantics.md`](../spec/semantics.md) specifies for `R010`.
Allocation follows the same line:

- Through an explicit capability, exhaustion is an anticipated policy
  outcome. `AllocError` is the closed allocation error ADT (`Exhausted`,
  `QuotaExceeded`, `RegionClosed`, `WrongAllocator`), and an API that can
  fail both ways returns `Result[T, AllocFailure[E]]` with
  `AllocFailure[E] = | Domain(E) | Alloc(AllocError)`, so neither error
  domain absorbs the other; `.map_err(...)` is the bridge into caller error
  domains per `spec/result-propagation-v1.md`.
- On the managed default path, heap exhaustion is a runtime error `R030`
  with the `R010` contract shape: one canonical stderr line, exit 1, no
  wrapping, no debug/release divergence. This is consistent with
  the language vision document, which folds panics into `pure`: managed
  allocation does not gain a hidden `Result` channel.
- A quota interposed on the managed heap at the process boundary converts
  exhaustion into that same `R030` contract, with the diagnostic naming the
  quota — so dependency code needs no source change to be metered (V4), and
  meters do not silently rewrite dependency control flow.

### Decisions on the questions #573 leaves open

Each answer is decided here, with the trade-off that motivated it and the
alternative rejected.

**Q1. Is `Allocator` an owned resource, a borrowed capability over an owned
arena, or a trait implemented by both managed and no-GC allocators?**
Decided: all three roles exist, assigned to different layers — allocator
*instances* are affine owned resources (`docs/MEMORY_MODEL.md` §2.3);
API-boundary *parameters* are borrowed `edit`/`read` capabilities over those
instances; and the capability *contract* is one interface that managed,
arena, quota, tracing, and no-GC fixed-capacity allocators all implement —
a `trait` in the DD-032 sense once traits carry evidence, seeded until then
as a closed instance-kind set behind one `Alloc` handle type, the same
bounded-seed pattern `stdlib/clock/adapters.kofun` uses for clock kinds.
Trade-off: this costs one indirection in the mental model (instance versus
borrow) to buy both affine cleanup and parameter-free call sites. Rejected:
"owned resource only", because threading `take`/return through every
allocating call is linear-style ceremony that breaks the managed-default
layer; and "trait with an ambient default instance", because an instance
nobody passes is Odin's context under a different name.

**Q2. Which result types carry allocator/region provenance?** Decided: only
region-backed values carry provenance, and it is compiler-tracked scope
provenance, not a user-written type parameter — `docs/MEMORY_MODEL.md` §1
promises "no lifetime parameters are written in everyday code" and §3.1
already has the compiler infer view lifetimes from lexical scope. Managed
results carry no provenance. Owned allocations carry a runtime provenance
word (their producing allocator's identity) so deallocation can be checked
(Q5). Trade-off: compiler-tracked provenance keeps signatures clean but
makes region-generic *storage* abstractions inexpressible in v1 (a container
parameterized over the region of its elements needs surface provenance);
that loss is accepted and revisiting it is an amendment. Rejected: universal
provenance parameters on result types — it reintroduces exactly the lifetime
annotation burden the language positions itself against.

**Q3. Can a managed value be promoted out of a temporary arena, and is that
always an explicit copy?** Decided: yes, and always explicit —
`promote(edit destination, value)` deep-copies a region-tagged value into
the destination allocator's domain and returns an untagged (or
re-tagged-to-destination) value. Never implicit. This mirrors §9 of
`docs/MEMORY_MODEL.md`, where owned-to-managed conversion is an explicit
`share`, not an inference. The compiler remains free to *elide* the copy
under the as-if rule of §2.2, but the semantics and the visible cost are a
copy. Trade-off: an explicit call at every escape point, bought for the
property that the one operation that defeats an arena's O(1) reset is
greppable. Rejected: implicit escape-analysis promotion — it hides cost at
precisely the boundary this RFC exists to make visible, and it makes a
program's peak memory depend on optimizer versions.

**Q4. Are allocator scopes allowed across suspension/async boundaries?**
Decided: no. An allocator scope is lexical and must be fully contained
within one activation; a suspended computation may not capture a scope
allocator or a region-tagged value. A scope may contain a `par` block,
because scoped parallelism joins before the block exits
(`docs/MEMORY_MODEL.md` §12) and `edit` exclusivity already governs the
capability. Kofun has no async surface today, so this binds future designs
rather than current code; it is recorded now because #556 fixes
continuations as one-shot for soundness, and a continuation resumed after
its arena's reset is the use-after-free that region tagging exists to
prevent. Trade-off: async code, when it exists, will need
per-suspension-frame or task-owned allocators instead of borrowing a
caller's arena across `await`. Rejected: capture-with-runtime-validity-check
— it converts a compile-time discipline into a runtime failure mode and
charges every resume a check.

**Q5. How are allocator equality, deallocation provenance, and FFI ownership
checked?** Decided: allocator identity is domain plus serial, compared by
identity — the `ClockIdentity` pattern of `stdlib/clock/adapters.kofun`,
where "two monotonic clocks in one process are two time lines"; two arenas
with identical configuration are two regions, and policy-equality is
meaningless. Deallocation provenance: every owned allocation records its
producing identity; a release against a different identity is refused
statically where provenance is region-tracked (`E341`) and is the typed
error `WrongAllocator` from checked dynamic paths — never silent corruption.
FFI: per `docs/MEMORY_MODEL.md` §11, trusted modules expose preconditions
through types and contracts, and unsafe capabilities are recorded in package
metadata; this RFC adds that every trusted declaration whose signature
passes memory across the boundary must state who allocates, who frees, and
which allocator domain owns each buffer, and that foreign memory enters
Kofun only through an explicit adopting constructor naming its foreign
deallocation domain. The type system does not police the far side — #569
already states plainly that FFI is a trust boundary — so the check is a
documentation-completeness gate (V7), honest about being one. Rejected:
structural/policy equality of allocators, and unchecked adoption of foreign
pointers into managed or region domains.

**Q6. Which internal runtime allocations are intentionally not
interceptable?** Decided: a closed, documented list — the collector's own
metadata (nursery, remembered sets, stack maps per `docs/MEMORY_MODEL.md`
§8), safepoint and root structures, the diagnostic buffer that formats a
runtime error's one canonical line (it must work when allocation is what
failed), and program loading before `main` receives root authority.
Everything performed as a consequence of calling a standard-library API is
interceptable. Tooling reports the non-interceptable surface the same way
#569 requires the trusted surface reported: honestly, as a boundary, not
hidden. Under the no-GC profile the list shrinks to a documented startup
set. Trade-off: a tracing user cannot observe collector overhead through the
allocator interface and must use the GC's own controls (§8 operational
controls); accepted because a collector that allocates its metadata through
a user quota can fail mid-collection, which is unrecoverable by
construction. Rejected: "everything interceptable" — circular and unsound
for the collector; and "implementation-defined set" — an undocumented
boundary is where the next ambient authority grows.

## Semantics

Stated to move into `spec/semantics.md` without rewriting.

1. **Effect.** `alloc` is an effect label. An expression that requests
   storage from any allocator — managed default included — carries `alloc`;
   a function's row includes the union of its body's labels; the rows
   compose by the same inference that will carry `pure`/`io` (#556). A
   function whose row lacks `alloc` performs no allocation on any execution
   path: the absence is normative. The presence is an upper bound; an
   implementation may eliminate allocations under the as-if freedoms of
   `docs/MEMORY_MODEL.md` §2.2, so counters and profiles are observations of
   an implementation, not semantics. `alloc` is orthogonal to `pure`/`io`:
   allocating a managed value does not make a function `io`, and a `pure`
   function may carry `alloc` — consistent with
   [`spec/effects/validation-accumulation.md`](../spec/effects/validation-accumulation.md),
   whose pure combinators build lists today.
2. **Capability.** `Alloc` values are unforgeable and originate only from an
   allocator instance or, for the managed default, from the runtime's
   root-derived heap handle. Allocating operations borrow `edit`; inspection
   borrows `read`; instances are affine owned values under §2.3 rules.
3. **Scope.** `with name = expr block` evaluates `expr` to an owned scope
   allocator, binds `name` as its capability for the block's lexical extent,
   supplies elided `Alloc` arguments of calls lexically inside the block
   from the innermost scope, and resets/drops the allocator deterministically
   on every exit path, early returns included.
4. **Region.** A value whose storage was requested through a region-carrying
   allocator is region-tagged with that scope. A region-tagged value or a
   view into one may not cross its scope boundary by return, outer-binding
   assignment, escaping-closure capture, or storage into a longer-lived
   container. `promote` produces a value of the destination domain by deep
   copy. After the scope exits, no region-tagged value of that scope is
   reachable in safe code.
5. **Failure.** Capability-path exhaustion is `Err(AllocError...)`.
   Managed-path exhaustion is runtime error `R030` under the `R010`
   diagnostic contract of `spec/semantics.md`.
6. **No-GC profile.** In a build profile whose allowed-allocator set
   excludes the managed heap, any path carrying `alloc` that resolves to the
   managed default is a compile-time refusal.

Deliberately left undefined: arena chunk geometry, alignment, and growth
policy; whether and when an implementation elides, batches, or
stack-promotes allocations; the internal synchronization of the managed
heap; and the numeric value of any counter.

## Diagnostics

New refusals, following the stable-code discipline of
the language vision document §Error messages. The codes extend the ownership
family (`E330` use-after-take is the historical neighbor,
`docs/MEMORY_MODEL.md` §13); `R030` extends the runtime family of
`spec/semantics.md`.

| Code | Refusal | Message shape |
|---|---|---|
| `E340` | a region-tagged value escapes its allocator scope | names the value, the scope's `with` line, the escape route (return / outer assignment / closure capture / stored into longer-lived container), and suggests `promote` |
| `E341` | a value is released against a different allocator than the one that produced it, where provenance is statically known | names both allocator identities and the producing site |
| `E342` | a path carrying `alloc` resolves to the managed default inside a declared no-alloc contract or a no-GC profile build | names the allocating call, the resolution path, and the contract or profile that forbids it |
| `E343` | an allocator capability itself escapes its scope (returned, stored, or captured by an escaping closure) | names the scope and the escape route |
| `R030` | allocation failure on the managed path at runtime | one canonical stderr line naming the failing request and, if interposed, the quota; exit status 1; identical across debug and release |

`E344` is reserved beside these for the future suspension-boundary refusal
(Q4) so async work does not have to renumber. Dynamic capability misuse that
static tracking cannot see (`RegionClosed`, `WrongAllocator`) is a typed
`AllocError`, not a diagnostic: it follows the charter's typed-`Result` rule,
and the injection gate (V3) proves both surfaces.

## Ownership and effects

Interaction is the substance of this proposal, not a side effect.

- **Modes.** Allocating operations borrow the capability `edit`; inspection
  borrows `read`; transferring an allocator instance is `take`; instances
  are affine and dropped by scope cleanup exactly as `docs/MEMORY_MODEL.md`
  §2.3 specifies. No generation counter is added to `Alloc` borrows: clock
  handles made every read affine because two reads through one capability
  state must be impossible (`stdlib/clock/adapters.kofun`), whereas
  allocation needs no such ordering — `edit` exclusivity already serializes
  allocations through one instance, and static region tracking plus the
  `RegionClosed` backstop covers staleness.
- **Effects.** `alloc` joins the inferred row as its first widening beyond
  `pure`/`io`; it does not change the two-point lattice #556 ships first,
  and it must land as a row label so it composes when the row widens
  further. A `pure` function may allocate; supplying a tracing allocator
  makes observation explicit at the boundary that supplied it and does not
  retroactively make the traced function `io`.
- **Affine resources.** A region-tagged owned resource is doubly bounded:
  affine (consumed at most once) and region-bound (never past reset). Both
  checks report separately — `E330`-family for the affine misuse, `E340`
  for the region escape — because a reader repairing one must not be told
  it is the other.
- **Second-class values.** Region tagging deliberately reuses the
  non-escaping discipline of views (§3.1) and non-escaping closures (§7),
  and the language vision document records that capabilities-as-second-class
  is the effect design this language already implements. This RFC adds no
  new escape machinery; it extends the existing rule to one more category.

## Alternatives

- **Odin's implicit `context` (do what Odin does).** Rejected for the three
  recorded reasons in §Motivation: ambient authority against #569 and the
  charter, invisibility against #556 and inferred-effect boundaries, and
  cost-opaque APIs against the adversarial-limits rule. The interception
  value Odin demonstrates is kept; the delivery mechanism is not.
- **Zig-style explicit allocator parameter on every allocating function, no
  default.** Rejected: it deletes the managed default that
  `docs/MEMORY_MODEL.md` §1 and the one-day-to-productive principle of
  the language vision document promise. Kofun's application layer must not pay
  systems-layer ceremony everywhere.
- **Process-global allocator swap hooks (malloc interposition style).**
  Rejected as the primary mechanism: global, unscoped, invisible in any
  contract, and racy under scoped parallelism. A root-derived process
  boundary hook survives in layer 1, but as a capability derivation at
  `main`, not a mutable global.
- **Allocation as a handled algebraic effect (handlers supply allocators).**
  Rejected for v1: #556 ships a two-point lattice first and constrains any
  future handlers to one-shot continuations; making allocator supply
  dynamic-by-handler would also reintroduce the invisibility this RFC
  rejects in Odin's context, one level up.
- **Do nothing.** Rejected: the no-GC profile stays uncheckable, the
  benchmark schema's allocation counters stay unfillable, and every future
  allocation-sensitive API invents its own ad-hoc parameter convention —
  the drift the clock module's explicit-capability idiom was built to stop.

## Drawbacks

- **Two-signature surface.** Allocation-sensitive stdlib APIs grow a
  capability-taking variant beside the managed-default one
  (`json_decode` / `json_decode_in`). The charter's documentation rules make
  each variant a documented, testable surface; it is still more surface.
- **Earlier lattice widening.** `alloc` arrives before the row system #556
  deliberately deferred, and inference diagnostics are where that work
  warned the danger lives. Mitigation: `alloc` is one label with no
  polymorphism, no subtyping, and no user-written rows; if even that proves
  noisy in diagnostics, the label can ship contract-only (checked at
  declared boundaries) first.
- **A third non-escaping category to teach.** Views, non-escaping closures,
  and now region-tagged values. The rule is the same each time, but a
  learner meets it three times.
- **The managed default is interceptable only at the process boundary.**
  Per-callsite interception of code that declares no capability is
  impossible without contract change — a real limit against Odin, accepted
  deliberately; the alternative is the implicit context.
- **Ecosystem pressure.** Allocation-sensitive libraries may reach for
  capability-first signatures everywhere, pushing ceremony onto casual
  callers; the scope sugar exists to keep the explicit signature cheap to
  call, and the staged adoption (below) is scoped to measure exactly that
  ergonomic cost before anything else is retrofitted.

## Non-goals

This RFC deliberately does not decide:

- **Call-site mode annotation.** Whether `take`/`edit` must also be written
  at call sites stays the open UX question of `docs/MEMORY_MODEL.md` §3.3;
  sketches here write declaration-site modes only.
- **The trait system.** Whether `Alloc` becomes a DD-032 trait is settled by
  that decision's own evidence; this RFC's seed is a closed instance-kind
  set and does not depend on traits landing.
- **Async/suspension design.** Q4 records one constraint on any future
  design; it does not choose one.
- **GC internals or tuning.** §8 of `docs/MEMORY_MODEL.md`, including its
  operational controls, is untouched.
- **The `pure` keyword.** `docs/TYPE_SYSTEM.md` leaves explicit-purity
  spelling open; `alloc` is defined against the inferred row either way.
- **Whole-stdlib retrofit.** Only the four adoption paths below are in
  scope until their evidence exists — #573 says so explicitly.
- **FFI/trusted syntax.** `docs/MEMORY_MODEL.md` §11 notes `trusted` is a
  candidate keyword pending its own RFC; this RFC only obligates the
  ownership documentation such declarations must carry.
- **The general capability hierarchy of #569.** Root authority, derivation,
  and attenuation are assumed as that issue records them; only the
  allocator-specific derivation point is named here.

## Compatibility and migration

**Category: additive.**

Everything proposed is new surface: the `alloc` label, the `Alloc` and
`AllocAuthority` types, capability-taking API variants, region tagging, the
diagnostics `E340`–`E343` and `R030`, and the contextual `with` scope. The
managed default remains the default and existing signatures keep their
meaning. `with` is contextual in a statement position no tracked source
uses:

```sh
git grep -niE '\ballocator\b' -- '*.kofun' | wc -l
git grep -nE '^[[:space:]]*with\b' -- '*.kofun' | wc -l
```

Both return **0** across the 761 tracked `.kofun` sources (761 from
`git ls-files '*.kofun' | wc -l`). No migration path is required; adopting
the capability variants is opt-in per API.

One boundary is worth stating: when the no-GC profile gate ships, a program
*opting into that profile* is refused unless its allocating paths resolve —
that is the profile's purpose, not a compatibility break for existing
programs, since no tracked program declares the profile today.

## Implementation plan

Ordered so each stage is separately enableable, none is implied by
acceptance, and every stage lands with its gate. The pattern is the clock
module's: canonical contract files plus an executable Stage 2 projection
pinned against them
([`stdlib/clock/README.md`](../stdlib/clock/README.md) §Adapter surface
boundary, [`tests/stdlib/clock-adapters/check.sh`](../tests/stdlib/clock-adapters/check.sh)).

1. **Canonical seed.** `stdlib/alloc/` canonical contract (`Alloc`,
   `AllocAuthority`, `AllocError`, arena/quota/tracing/fixed instance kinds,
   `promote`, the scripted failing allocator) plus a Stage 2 Int-Core
   projection and pin check, reference executor and C11 backend first.
2. **Effect label.** `alloc` inference in the bounded Stage 2 checkpoint;
   contract-position declaration for public APIs; sidecar/discovery
   projection.
3. **Scope.** `with` parsing, supply rule, deterministic reset, `E343`.
4. **Region checking.** Region tagging and `E340`/`E341` as a bounded
   conservative slice, in the style of the existing E007 ownership slice
   (`DESIGN.md` §Decision).
5. **Adoption wave one, with measurements**: `TextBuilder` (new; charter
   tier 2 "text and bytes" — not yet in tracked source), `Bytes` building,
   `json_decode_in` beside `stdlib/json`'s `json_parse`, and collection
   growth (`push`, as seeded by `stdlib/list/list.kofun`). Benchmarks per
   `docs/stdlib/benchmark.md` before and after. Nothing else is retrofitted
   until these four report.
6. **No-GC profile gate** (`E342`), last, because it needs 1–5.

## Validation

Acceptance criterion 1 of #573 — an RFC separating effect, authority,
ownership, and region lifetime — is this document. The remaining criteria
map to future gates as follows; on implementation these become the ledger's
`implementation` record and its capability claims in `release/claims.json`
per the [public RFC process](https://kofun-lang.github.io/kofun/docs/rfc-process/) §6.

| # | #573 criterion | Future gate | Fixture and boundary proof |
|---|---|---|---|
| V1 | same JSON/collection fixture under managed, arena, failing/quota, and no-GC | `sh tests/stdlib/alloc/check.sh` (wired as `task alloc-capability`) | one fixture source, four profile runs, observations identical except counters; the no-GC run compiles only because every path resolves |
| V2 | compile-fail: arena escape; wrong-allocator free; implicit allocation in a no-alloc path | same gate, refusal corpus | `reject_region_escape.kofun`, `reject_wrong_allocator_free.kofun`, `reject_ambient_alloc_nogc.kofun` with pinned `.stderr`, the convention of `tests/conformance/numeric/reject_slash_operator.kofun` and `tests/conformance/traits/orphan_both_foreign.stderr`; each must name `E340`/`E341`/`E342` |
| V3 | allocation failures use a specified Result/panic contract, tested by injection | same gate, injection corpus | the scripted failing allocator (the `scripted_read_failure` pattern of `stdlib/clock/adapters.kofun`) drives both surfaces: `Err(Exhausted...)` on the capability path, the canonical `R030` line and exit 1 on the managed path |
| V4 | dependency code runs under a quota/tracing allocator without source modification beyond the declared contract | same gate, interposition fixture | a fixture dependency compiled unmodified, run once plain and once under a root-derived quota/tracing heap handle; identical results, nonzero trace |
| V5 | profiling identifies allocator, call site, bytes, and lifetime class | `kofun.alloc-profile/v1` schema + golden-record check | lifetime class enumerates the domains: copy/stack, managed, owned, region; allocator identity is the Q5 domain+serial |
| V6 | benchmarks record throughput, peak memory, allocation count, cleanup cost | extension of `kofun.bench-report/v1` under `docs/stdlib/benchmark.md` rules | every counter present or explicitly `unavailable`, never zero-by-omission, per that contract's stated rule; cleanup cost measured across scope exit |
| V7 | FFI documentation states who allocates, who frees, which domain owns every returned buffer | trusted-surface documentation gate | checker refuses a trusted memory-crossing declaration missing any of the three statements; surface reported per `docs/MEMORY_MODEL.md` §11 metadata rule |

Negative boundary for the design itself: V2's three refusals are the
mutations that would each collapse one of the four separated concerns
(region into ownership, authority into effect, effect into nothing), so the
gate proves the separation, not only the feature.

## Unresolved questions

Three, each with what settles it:

1. **Trait formulation.** Whether `Alloc` instance kinds become a DD-032
   trait or stay a closed set is settled by the traits decision's own
   law-checked evidence; the seed is designed to migrate either way.
2. **Nested quota accounting.** Whether an inner quota debits its outer
   quota for bytes it merely reserves, or only for bytes it hands out, is
   settled by the stage-1 seed's fixture experiment before V1 freezes.
3. **Elision opt-out spelling.** Whether an API can declare its `Alloc`
   parameter non-elidable (forcing every call site to name the allocator,
   for audit-critical paths) is settled during stage 3 by the ergonomics
   measurements of adoption wave one.

Everything else raised by #573 is answered above.
