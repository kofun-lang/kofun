# RFC-0005: A trait or type member scope is closed under direct declaration

- Shepherd: hjosugi
- Opened: 2026-08-02
- Status: accepted
- Decided: 2026-08-09

## Summary

The members of a trait or nominal type are exactly the members its own
declaration lists. v1 has no inherited member and no default member, so it has
nothing to override, and it adds no override marker. Two direct declarations
that normalize to one name in one namespace under one owner are refused, and
the refusal names the owner, the namespace, the name, and both declarations.
A trait that names an inherited member source, and a trait member that carries
a default body, are each refused as a stated rule rather than as an
implementation slice boundary.

For someone writing Kofun this changes nothing that works today and two things
that do not: a duplicate member stops being reported as a duplicate
*parameter*, and a supertrait clause stops being reported as a missing brace.

## Motivation

[#942](https://github.com/kofun-lang/kofun/issues/942) cannot implement a truthful
member-scope duplicate diagnostic until this decision exists, and
[#995](https://github.com/kofun-lang/kofun/issues/995) is the decision it waits
for. The cost is not hypothetical: every shape in that domain is refused today
by a diagnostic that blames a scope the author did not write in.

Run against `bootstrap/stage2/traits_frontend.c` at
`727f9dac442ba8db56e8344dbd1e29112ea1e64d`:

```text
$ cat member_name_collision.kofun
trait Equal[T] {
    fn equal(left: T, right: T) -> Bool
    fn equal(left: T, right: T) -> Bool
}
$ kofun-traits-frontend member_name_collision.kofun out.ir out.tokens
error[E2S127]: parameter 'left' is declared twice at bytes 70..77
```

That is one member name declared twice under one owner, and the compiler
reports a duplicate parameter. The parameter table is keyed by the trait
rather than by the member, so the parameter collision is found first. The
message names neither the colliding member `equal` nor its owning trait
`Equal`, which makes it a refusal the author cannot act on: renaming `left`
produces a different refusal, not an accepted program.

#942 recorded the premise that this shape is refused by `E2S132` for carrying
two methods. It is not. `E2S132` is what a *differently* named second member
gets, and a same-named second member whose parameters happen to be spelled
differently gets the identical message — the two differ only in their byte
span:

```text
# trait Equal[T] { fn equal(left: T, right: T) -> Bool
#                  fn differ(a: T, b: T) -> Bool }
$ kofun-traits-frontend two_named_members.kofun out.ir out.tokens
error[E2S132]: a trait with 2 methods is unsupported in this slice; exactly one is accepted at bytes 0..92

# trait Equal[T] { fn equal(left: T, right: T) -> Bool
#                  fn equal(a: T, b: T) -> Bool }
$ kofun-traits-frontend renamed_parameters.kofun out.ir out.tokens
error[E2S132]: a trait with 2 methods is unsupported in this slice; exactly one is accepted at bytes 0..91
```

So the frontend today cannot distinguish a duplicate member from a second
member at all, and where it does distinguish them it distinguishes them
wrongly.

The inherited-member source shapes are no better. Neither spelling a reader
would try is recognised as a trait construct:

```text
$ kofun-traits-frontend inherited_member_source.kofun out.ir out.tokens
error[E2S127]: expected '{' at bytes 66..73      # trait Derived[T] extends Base[T]
$ kofun-traits-frontend supertrait_bound.kofun out.ir out.tokens
error[E2S127]: expected ']' at bytes 64..65      # trait Derived[T: Base[T]]
```

Both are punctuation refusals. The frontend has no inheritance edge, so it has
no way to say so.

A default body is refused, and the refusal is accurate but temporary in the
wrong way:

```text
$ kofun-traits-frontend default_method.kofun out.ir out.tokens
error[E2S132]: a default method is unsupported in this trait frontend slice; this slice is bounded to one-method traits with one type parameter, concrete implementations, and one explicit non-recursive bound at bytes 57..58
```

It names the *slice*. A reader is entitled to conclude that the next slice
will accept it. This proposal would make the refusal the rule, so the message
should say the rule.

Three of those five programs are now tracked, so the transcripts above cannot
rot silently: `member_name_collision` and `inherited_member_source` are added
by this proposal, and `default_method` was already there.
`tests/conformance/traits/run.sh` requires each to exit 1 with its byte-exact
golden, and additionally requires the first two messages *not* to name the
colliding member, the owning trait, or the inherited source — so a change that
started reporting these in the member scope would fail the gate rather than
quietly invalidate the motivation. `two_named_members` and
`renamed_parameters` are one-off probes and are not tracked; their sources are
the two comments above.

## Detailed design

### Owner identity

An owner is the thing a member scope is keyed by.

| Declaration | Owner identity |
|---|---|
| trait | its `TraitId` |
| nominal type, record, enum/ADT | the `TypeId` of its outer nominal constructor |
| implementation block | **not an owner** |

An implementation is indexed by `ImplementationId` under
[DD-032](../spec/roadmap-31-34/generics-and-traits.md) and is not a
separately lookupable name. It supplies the members its trait already
declares; it does not introduce a member name, and it cannot add one. That is
already enforced — an implementation of a method the trait does not declare is
refused, pinned by `tests/conformance/traits/method_name_mismatch.stderr`.

Ownership here is the declaration-scope sense: which declaration a member hangs
off. It is unrelated to package ownership under the DD-032 orphan rule, and
unrelated to the `Managed`/`Owned` kind of RFC-0004. Two members collide or do
not for reasons that are settled before either of those is computed.

### The member key

A member is keyed by:

```text
(owner identity, NamespaceId, normalized member name)
```

The namespace comes from
[`spec/modules/namespaces.md`](../spec/modules/namespaces.md) unchanged. This
proposal assigns no namespace and adds no fifth one:

| Member form | Namespace | Tag |
|---|---|---|
| field | value | 0 |
| method | value | 0 |
| associated function | value | 0 |
| associated constant | value | 0 |
| associated type | type | 1 |
| named law or proof declaration | meta | 3 |

Normalization is the normalization the namespace contract already applies to a
module scope. This proposal introduces no second normalization and no
capitalization rule.

### The rule

> **A member scope is closed under direct declaration.** The members of an
> owner are exactly the members that owner's declaration lists directly. Two
> members of one owner with equal keys are refused. There is no inherited
> member, no default member, and no override.

The rule is a single sentence on purpose. Everything below is that sentence
applied to the cases #995 requires an answer for.

### Direct, inherited and default precedence

There is none, and the absence is the decision rather than an omission.

Precedence is the mechanism a rule needs when two candidates can both supply
one name. v1 has exactly one candidate for any key by construction, so writing
down an order — direct beats default beats inherited, say — would be
describing machinery this milestone does not have. It would also be the wrong
shape of machinery: DD-032 states that specialization and ordered fallback are
unsupported in M2-alpha, and an ordered member-precedence list is an ordered
fallback over member candidates.

When inheritance or defaults arrive, the RFC that introduces them introduces
the precedence with them, in the same document, with the marker that makes a
replacement visible at the declaration that performs it.

### Same-owner duplicates

Two direct members of one owner with equal keys are refused with `E370`,
whatever declaration forms they take. A method and an associated function
collide; a field and an associated constant collide; a method and a field under
one *type* owner collide. Each of those pairs is value/value under one owner,
and the namespace contract already refuses value/value in one scope.

Associated values follow methods exactly: same namespace, same key, same code.
There is no separate associated-value rule to remember.

Associated *types* key in the type namespace, so an associated type collides
with another type-namespace member of that owner and never with a method. A
trait may declare an associated type `Item` and a method `item`, or even an
associated type `Item` and a method `Item`, because the use site selects the
namespace.

The same normalized spelling under two *different* owners stays legal. That is
what makes a trait method `equal` and an unrelated type's field `equal`
independent, and it is unchanged by this proposal.

### Diamond and multi-path inherited collisions

Unreachable, by construction. There is no inheritance edge for two paths to run
along, and `E371` refuses the clause that would create one, so the case cannot
arise from an accepted program.

What a future inheritance RFC must preserve is stated here so that it is a
constraint rather than a rediscovery:

> The member set of an owner must remain a function of the owner identity
> alone.

A rule under which two import paths, two supertrait orders, or two declaration
orders could yield different member sets for one owner identity would violate
it, and would break the dictionary identity below.

### Fields

Two questions, two answers.

**Can a field collide with a method or an associated value?** Yes, when they
share an owner. A field is a value-namespace member of a nominal type owner, so
a field and an associated function on that type collide under `E370`. A field
and a *trait* method never collide, because a trait's scope is keyed by
`TraitId` and a type's by `TypeId`, and an implementation does not merge the
two scopes. `Money.amount` and `Equal.amount` are different keys.

**Do fields participate in inheritance?** No — nothing does. Fields are not a
special case here; they are the ordinary case under a rule with no inheritance
in it. When inheritance arrives, whether fields participate is a question that
RFC must answer explicitly, because a layout-bearing member behaves differently
from a dispatched one and silence would be read as "yes".

### Why this keeps the #936 dictionary identity sound

This is the constraint that decides between the options, so it is stated in
full.

Dictionary elaboration (`kofun-traits-ir/v2`) derives a `DictionaryId` from an
`ImplementationId` by retagging `impl:` to `dictionary:` and dropping the
trailing `/decl=N`:

```text
impl:abi1/package:local/trait:local:Equal/args=builtin:Int/self=builtin:Int/decl=0
dictionary:abi1/package:local/trait:local:Equal/args=builtin:Int/self=builtin:Int
```

What survives is exactly the coherence key, which overlap refusal already makes
unique per admissible implementation. The layout the dictionary fills comes
from a separate record, `dictionary-descriptor:abi1/<TraitId>`, keyed by the
trait alone and carrying an ordered `slot-methods` list.

Two properties hold today, and the traits gate counts both — one descriptor per
declared trait, and one dictionary per admissible implementation:

1. a trait's slot table is a function of its `TraitId`; and
2. a `DictionaryId` determines the dictionary's contents, because those
   contents are the descriptor for the trait named in the key, filled by the
   unique admissible implementation for that key.

Closure under direct declaration is what makes (1) true. With no supertrait
path and no default, a trait's member sequence cannot depend on anything except
its own declaration, so the descriptor cannot vary with what a supertrait
happened to contribute or with which of two colliding members won.

Implicit signature-compatible replacement would break (2) directly. Under that
rule one coherence key could denote different slot fillers depending on which
member won the collision, and the `DictionaryId` carries no component that
records a winner. The one component that could have distinguished the two —
`/decl=N`, the declaration ordinal — is precisely the component the derivation
drops, and it is dropped so that reordering declarations cannot change a
dictionary identity. Repairing the derivation would mean growing the
`DictionaryId` a member-resolution component, which would reintroduce the
declaration-order sensitivity `tests/conformance/traits/order_independence.kofun`
exists to refuse.

So the closed rule is not merely the conservative option. It is the option
under which the identity derivation that landed in #936 stays a function.

## Semantics

A program means the same thing under this proposal as it does today; the
proposal fixes which programs exist.

- The member set of an owner is the sequence of members its declaration lists,
  in declaration order. Nothing is added to it and nothing is hidden in it.
- A member reference resolves against one key. A failed member lookup reports
  the requested namespace and the owner; it never retries another namespace or
  another owner because a same-spelled member exists there. That is the
  namespace contract's existing rule, restated only to say that member scopes
  are not an exception to it.
- Declaration order is observable in exactly one place — the trait's dictionary
  slot order — and in no other. It never selects between members, because there
  is never more than one member per key.
- An implementation supplies one member per declared trait slot: no more, no
  fewer, no member the trait did not declare.

Deliberately undefined:

- the surface syntax of an override marker, because v1 has no referent for one;
- how an inherited member is named at a use site;
- whether and how a default body is type-checked against the trait's own
  signature, which only matters once defaults exist.

## Diagnostics

New refusals in the reserved `E3xx` design family. `docs/MEMORY_MODEL.md` §13
records that `E3xx` is not a live family and that no `E3xx` code has ever been
in `tests/diagnostics/registry.tsv`. RFC-0001 reserves `E340`–`E344`, RFC-0002
reserves `E350`–`E356`, and RFC-0004 takes `E360`–`E364` and leaves
`E365`–`E369` unallocated, so this proposal takes `E370`–`E372`. The band is
unused: `grep -c 'E37' tests/diagnostics/registry.tsv` returns `0`, and
`cut -f1 tests/diagnostics/registry.tsv | grep -cE '^E3'` returns `0`, so no
`E3xx` code of any kind is registered today, and no earlier RFC reserves this
band.

| Code | Refusal | What the message must name |
|---|---|---|
| `E370` | two direct members of one owner share a normalized name in one namespace | the owner identity, the namespace, the normalized name, and both declaration identities and spans in canonical `SymbolId` order; the remedy is to rename one, stated as a rename because v1 has no override to offer instead |
| `E371` | a trait declaration names an inherited member source | the clause, the source it names, and that a trait's member set in v1 is exactly its direct declarations; the remedy is a bound on the function that needs both traits, not a supertrait |
| `E372` | a trait member carries a default body | the member and its owner, and that the member scope is closed, so a default has no scope in which it could be overridden; the remedy is to move the body into each implementation |

`E373`–`E379` stay unallocated in this band.

Three codes rather than one "unsupported form" code, because the three repairs
are different: rename a declaration, restructure a bound, move a body. A single
code would make the reader work out which.

`E370`–`E372` are design-band identities and are deliberately **not** added to
`tests/diagnostics/registry.tsv` by this proposal. That registry admits a code
only with an executable emitter and an observed golden, and #942 owns the
implementation. What this proposal does register instead is what the frontend
emits *in place of* these today: `member_name_collision` and
`inherited_member_source` are pinned in `tests/conformance/traits/`, and the
gate asserts that neither message has started naming the member, the owning
trait, or the inherited source — so those goldens cannot drift into looking
like member-scope diagnostics without failing first.

## Ownership and effects

No interaction, and the reason is that member collision is decided earlier than
either discipline runs. A collision is a function of names, namespaces and
owner identities; it reads no `read`/`edit`/`take` mode, no affine state, and
no effect row, and it produces none. Closing a member scope neither creates nor
consumes a resource.

One direction does matter and is worth stating rather than omitting. RFC-0004
reports an ownership classification as a minimal path through named components
— `Session.frames -> List[Frame]#1 -> Frame.Open.handle -> File is owned` —
and that notation identifies a component by its name within its owner. `E370`
is what keeps `Session.socket` denoting one field, so the closed member scope
is a precondition for RFC-0004's path being well defined rather than a
consumer of it.

## Alternatives

**1. Require an explicit `override` marker and reject every unmarked
inherited or default collision** (#995 option 1). Rejected for v1, and this is
the alternative with a real trade-off rather than a defect.

It is the right long-term shape: a replacement should be visible at the
declaration that performs it, not inferred from a lookup order. But a marker
needs something to mark. v1 has no inheritance edge and no default body, so an
`override` marker would be surface syntax that no legal program could ever use,
and reserving the word would break any program that spells `override` as an
identifier. It would also be syntax invented inside a diagnostic decision, in a
milestone whose accepted design (DD-032) states that specialization is
unsupported — deciding the marker now would commit its interaction with a
feature that has not been designed.

The trade-off this defers: when defaults land, a v1 program whose member name
coincides with a new default acquires a collision it did not have, and must add
the marker. That cost is bounded, it is stated, and the RFC that introduces
defaults can count it against the corpus of the day — which is the point of
making it that RFC's obligation rather than guessing at it now.

**2. Allow signature-compatible implicit replacement** (#995 option 2).
Rejected, on three independent grounds.

It breaks the #936 identity derivation as shown above: one coherence key could
denote different dictionary contents, and the component that could distinguish
them is the one deliberately dropped. It needs a compatibility relation Kofun
does not have — "signature-compatible" is a subtyping or variance judgment, and
M2-alpha has neither. And when two compatible candidates both apply, choosing
between them is ordered fallback, which DD-032 states is unsupported in
M2-alpha; the only orders available are declaration, import and link order, and
DD-032 states that none of them may ever select.

**3. Do nothing.** Rejected. #942 stays blocked, and the refusals in this
domain keep blaming the parameter scope and the brace. Doing nothing is not
neutral here: it leaves a compiler that reports a duplicate member as a
duplicate parameter, which is worse than either of the other options.

## Drawbacks

A trait cannot share an implementation of a member between its implementations
until a later RFC introduces defaults. Every implementation repeats the body.
That is a genuine ergonomic cost and it is paid starting now.

The closed scope also stores up the migration described under alternative 1: a
program written today may name a member that a future default also names, and
will need the marker when defaults arrive. The number of such programs is
unknown today because defaults do not exist, which is exactly why the count
belongs to the RFC that creates them.

Three codes is more diagnostic surface than one, and all three refuse shapes no
program can currently express, so their messages will be written before anyone
has read one in anger.

## Compatibility and migration

`additive`.

Every shape this proposal refuses is already refused. `E370` replaces a
parameter-scope refusal, `E371` replaces a delimiter parse error, and `E372`
replaces a slice-boundary message; in each case the program was rejected before
and is rejected after, and only the message changes. The member key, the
closure rule, and the three codes are new surface. No accepted program changes
meaning and none stops compiling.

The count, at `727f9dac442ba8db56e8344dbd1e29112ea1e64d`:

```sh
git ls-files -- '*.kofun' | wc -l
git grep -nwE 'extends|override' -- '*.kofun' | wc -l
git grep -nE '^(trait|foreign trait|impl)|^    fn ' -- '*.kofun' |
    awk -F: '{ sub(/^[^:]*:[^:]*:/, "") }
        $0 ~ /^(trait|foreign trait|impl)/ { if (n > 1) m++; n = 0; b++; next }
        { n++ }
        END { if (n > 1) m++; print b, m + 0 }'
```

`888`, `0`, `42 0`. Of 888 tracked `.kofun` sources, 0 name an inheritance edge
or an override marker; of the 42 trait and implementation member scopes they
declare, 0 declare more than one member. So the number of tracked programs that
this rule refuses and that are accepted today is 0, and the number that would
need an override marker is 0.

The same query returns `890`, `1`, `45 1` after this change, and both
differences are the two negative fixtures it adds:
`tests/conformance/traits/inherited_member_source.kofun` is the one source
spelling `extends`, and `tests/conformance/traits/member_name_collision.kofun`
is the one owner declaring two members. The frontend refuses both today and the
gate pins each to a byte-exact golden, so the count of *accepted* programs in
either shape stays 0.

Migration: none, because nothing breaks. A program written against a future
default that collides with a v1 member name adds the marker that RFC
introduces.

## Implementation plan

#942 owns the implementation, in this order, and none of it is a commitment
made by accepting this proposal:

1. represent at least two value-namespace members under one owner identity —
   a #31 frontend prerequisite, since `E2S132` refuses the second member today;
2. apply the key and emit `E370` for a same-owner collision, re-blessing
   `member_name_collision.stderr` off the parameter-scope message and dropping
   the two assertions in `tests/conformance/traits/run.sh` that currently
   require that message *not* to name the member or its trait;
3. emit `E371` for an inherited member source and `E372` for a default body,
   re-blessing `inherited_member_source.stderr` off the delimiter parse error
   and `default_method.stderr` off the slice-boundary message, and dropping the
   assertion that the first names no inherited source;
4. register the emitted codes in `tests/diagnostics/registry.tsv` with observed
   goldens, in the family of the emitter that produces them.

Steps 2, 3 and 4 can each be enabled separately. Nothing in this proposal
requires default bodies to be implemented, and nothing requires an inheritance
edge to exist.

The fixtures #942 needs are named here so the implementation issue does not
have to invent them:

| Fixture | Sense | Proves |
|---|---|---|
| `member_name_collision` | negative | two direct members of one owner with one normalized name refuse with `E370`, naming both declarations |
| `member_field_collision` | negative | a field and an associated value under one *type* owner refuse with the same code and rule |
| `inherited_member_source` | negative | a supertrait clause refuses with `E371` |
| `default_method` | negative | a default body refuses with `E372`, replacing today's slice message |
| `distinct_owner_spelling` | positive | one normalized member name under two distinct owners is accepted, and both keys survive into typed IR |
| `two_members` | positive | two differently named members under one owner are accepted, with a two-slot dictionary descriptor |

`two_members` is the prerequisite: until it is accepted, `member_name_collision`
cannot reach the member-scope check, which is why #942 is blocked on
representation and not only on this decision.

## Validation

On the target branch today:

- `sh tests/conformance/traits/run.sh` — carries `member_name_collision` and
  `inherited_member_source`, requires each to exit 1 with its byte-exact
  golden and to write no typed IR, and asserts positively that each refuses in
  the wrong scope: that the collision message names `left` and names neither
  `'equal'` nor `Equal`, and that the supertrait message names a delimiter and
  not `Base`. Those negative assertions are the boundary — the goldens cannot be
  re-blessed into member-scope diagnostics without them failing first.
- `sh tests/rfc/check-registry.sh` — this row is `proposed`, so it carries no
  implementation record and no `decided_on`.

What will prove the *decided* behaviour is #942's `E370` fixture. This proposal
claims no implementation, and its ledger row carries none.

Nothing in this document is in force. The ledger row is `proposed` with
`opened_on: 2026-08-02` and deliberately no closing date and no
`decided_on`, which `tests/rfc/validate-registry.mjs` requires of a proposal
under review. The decision is recorded separately, on or after the day review
closes, and #995 stays open until then — so neither #942's blocker nor #31's
child state changes by publishing this.

## Unresolved questions

Three, each with the thing that settles it.

- The surface syntax of an override marker, and whether it is a keyword or an
  attribute. Settled by the RFC that introduces defaults or inheritance, which
  is the first point at which the marker has a referent.
- Whether an associated-type collision shares `E370` or takes its own code.
  Settled by #334, when associated types have an accepted shape; the key in
  this proposal already separates them, so only the code is open.
- Whether a trait may declare a law member, and whether law members share the
  value namespace with methods. `docs/LAW_SYSTEM.md` and DD-035 own it.
  `tests/usability/06_monad_laws.kofun` writes `operation` and `equation`
  members inside a `law` block, which the namespace contract places in the meta
  namespace — a different scope from a trait's, and not decided here.
