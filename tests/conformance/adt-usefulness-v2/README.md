# Recursive ADT usefulness v2

Independent analysis evidence for two questions a match raises: is any
alternative unreachable, and is the match exhaustive. It is not production
typing or lowering, and it reads a resolved model rather than Kofun source.

```sh
task adt-usefulness-v2
```

## What replaced what

The previous checkpoint could see a scrutinee column and at most one payload
column. Everything it had to say about deeper nesting was a refusal —
`nested usefulness row exceeds depth 1` — so the questions this corpus asks were
not answered wrongly before, they were declined.

That model is gone, along with its fixtures and its runner. Its cases are here:
a flat enum is the depth-0 matrix and a single payload column is the depth-1
matrix, so the earlier checkpoint is a special case of this one rather than
something set aside. No parallel oracle remains.

## The relation

Maranget's usefulness relation, over the resolved matrix. `U(P, q)` asks whether
some value matches the row `q` and no row of `P`:

| `q`'s first column | `P`'s first column | `U(P, q)` |
|---|---|---|
| — no columns left — | | `P` has no rows |
| a constructor `c` | | `U(S(c, P), S(c, q))` |
| a wildcard | names every constructor | some `c`: `U(S(c, P), S(c, q))` |
| a wildcard | does not | `U(D(P), tail(q))` |

`S(c, P)` keeps the rows whose head admits `c` and replaces that head with the
constructor's fields — the row's own fields when it names `c`, wildcards when it
is a wildcard or a binding. `D(P)` keeps the rows whose head admits every
constructor, with that head dropped.

Recursion is the whole point: specialization pushes a constructor's fields onto
the front of the row, so a nested column is the same kind of column as the outer
one, and a product of fields is the same shape of problem as a single scrutinee.

Redundancy is `U` against what precedes an alternative. Exhaustiveness is `U` of
a bare wildcard against everything that can fire.

## The witness

When a bare wildcard is useful, the constructors the search chose spell the
missing value. That path is canonical rather than incidental, in two places:

- the complete branch tries constructors in **ordinal order**, and the first one
  that answers wins;
- the default branch names the **ordinal-least constructor the column never
  mentions**.

A default choice is recorded *closed*: nothing was examined inside it, so every
one of its fields is any value and the entries after it belong to the next
column rather than to its fields. `Wrap(Right)` and `Wrap(_)` are the two
readings that distinction produces, and both are recorded answers here.

Getting the order wrong does not produce a missing witness. It produces a wrong
one — a constructor that is covered, reported as absent — which is why the
mutation for it is in the corpus.

## Guards

Two rules, and they are separate because a fixture that observes one does not
observe the other.

A guarded arm **covers nothing**: its guard may fail, so a case only it matches
is still missing. And a guarded arm **hides nothing** from the arms after it, so
an unguarded wildcard behind a guarded one is not unreachable. Both directions
are conservative: a guard can only remove a redundancy report, never add one,
and can only add a missing case, never remove one.

Within one arm it is different. An earlier alternative is tested before a later
one whatever the guard does, so it can hide it.

## Or alternatives

Alternatives are tested left to right, and the first unreachable one is reported
with its index. Every alternative of an arm must bind exactly the same roles:
they feed one body, and a body cannot read a name only some of its alternatives
bind. Roles are compared as resolved ids on sorted lists.

## Identity

A constructor is the 64-hex id it declares. `name` is display metadata: it
decides what an answer reads and never decides what the answer is. The
`decoy_owner` fixture is an ADT whose constructors carry the same display names
as the payload's, and nothing but the owner link separates them.

Renaming every display name in a model changes the words of its answer and
nothing else. Reordering `adt` and `constructor` records changes nothing at all.
Reordering arms changes results, because source order is what redundancy means.

## Bounds

| Quantity | Bound |
|---|---|
| ADTs | 16 |
| constructors, across the model | 64 |
| fields on one constructor | 4 |
| signature depth | 8 |
| arms | 64 |
| alternatives in one arm | 8 |
| alternatives in the model | 128 |
| binding roles | 32 |
| pattern nodes | 1024 |
| line / input | 4096 bytes / 1 MiB |
| columns | 32 |
| checked visits | 65536 |

Each of the first ten is exercised at the last model it accepts and the first it
refuses. The last two are derived rather than independent, and the corpus says
so instead of pretending to cross them:

- a row widens by `arity - 1` each time its head is specialized, and only the
  leftmost column is specialized before the ones beside it, so the widest a row
  can get is `1 + (depth - 1) * (fields - 1)` — **22** at the accepted maxima. A
  23rd column needs the depth or the field bound crossed first.
- the largest model the other bounds admit — 128 alternatives over a
  three-column product with every column complete, the shape that makes the
  search branch at every level — costs about **29 000** visits. The budget is set
  above that so it stops a pathology rather than an ordinary model, which is why
  the corpus proves the check by rebuilding with a smaller budget instead.

A model at a bound succeeds. A model one past it is refused with nothing
published, and a failed run leaves no result file and never touches its input.

## Refusals, proved by reintroducing them

Seven mutations rebuild the oracle with one rule removed and require this corpus
to notice: specialization keeping wildcard rows, the default matrix dropping
constructor rows, each half of the guard rule, the canonical witness order,
resolved-identity ownership, and the budget check.

A gate that only reads the good path cannot tell whether the bad one is still
refused. Every one of these has a plausible-looking wrong version, and the one
for witness order is the reason to look: its wrong version still reports a
missing case, and reports one that is not missing.
