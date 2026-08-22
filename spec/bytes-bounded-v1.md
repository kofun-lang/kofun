# Bounded `Bytes` v1

The `Bytes` carrier the C11 Stage 2 backend lowers, and the operations it
admits. This is a bounded executable checkpoint, not a claim that every
ownership, lifetime, or typed-return path is complete. Implemented behavior is
named with its gate below; incomplete boundaries are explicit in §8.

**Every normative statement names the gate that fails if it is false.** A
statement with no gate does not belong in this document — `task bounded-bytes`
invokes `task bytes-carrier` (#1315, the carrier) and `task bytes-mutation`
(#1321, the operations) sequentially. Where a statement is proved by a
specific assertion, the assertion is named rather than described, so a reader
can go and check.

## 1. What this is, and what it is not

`Bytes` is a **bounded byte-buffer carrier with a unique-owner model** and a
fixed ceiling of 65,536 bytes. It exists so a program the C11 Stage 2 backend
compiles can build a byte sequence whose length is not known when it starts.
`task bounded-bytes` proves the exercised carrier and mutation paths; §8
records the ownership and lifetime paths it does not claim.

It is **not**:

- a general buffer — the ceiling is fixed at compile time and is not
  configurable;
- convertible to or from `Text` — there is no bridge, and the three status tags
  reserved for one are unused (§5). That is #1322;
- atomically replaceable in a bound target — that is #1323 and #1324;
- reliably observable from source beyond `len` and `capacity` — every other
  operation has a compiler-private emitted-C outcome, and Stage 2 refuses the
  source value contexts that try to consume it (#1559, §7);
- available on any backend but C11 Stage 2.

## 2. The carrier

Three fields, in this order, and the order is frozen:

| field | type | meaning |
| --- | --- | --- |
| `length` | `uint64_t` | bytes currently held |
| `capacity` | `uint64_t` | bytes the allocation can hold |
| `data` | `unsigned char *` | the allocation, or `NULL` |

The emitted C carries `_Static_assert`s for the offset of `length` (0), the
offset of `capacity` (8), the width of `data` (8), and the alignment of the
struct (8). Those assertions are in every program that uses `Bytes`, so the
layout is proved by compiling rather than by a gate reading a table.

**The empty value in the extracted prelude is exactly `{0, 0, NULL}`.** The
tracked direct-transfer fixture requires an emitted `kofun_bytes_take` and runs
sanitizer-clean, but it does not independently snapshot all three fields of the
moved-from binding. This checkpoint therefore does not publish an exact
moved-from-bit-pattern guarantee. Compile-time use-after-move is proved only
for the forms named by the fixture set; an ordinary positional `take` call is
still not recorded as a move (#1540).

A length of zero allocates nothing. `malloc(0)` may return a non-null pointer,
which would make an empty value distinguishable from a one-allocation one, so
it is never called.

## 3. Ownership

The tracked owner fixtures exercise lexical cleanup in their emitted functions.
`bytes-carrier` derives the return sites from emitted C and requires every
selected return to contain at least one release. In the straight-line two-owner
fixture it also requires any released carrier ids on each return to descend;
the branch and nested fixtures execute their cleanup paths but do not derive a
complete live-owner set or check its full order. These observations establish
cleanup presence and selected ordering, not that every live carrier is released
at every exit. Three non-`Bytes` typed return guards and a post-transfer `Bytes`
result guard remain open in #1569 and #1581.

A parameter carries one of three modes, and a `Bytes` parameter with no mode is
refused:

| mode | C carrier | who reclaims |
| --- | --- | --- |
| `read` | `const KofunBytesValue *` | the caller |
| `edit` | `KofunBytesValue *` | the caller |
| `take` | `KofunBytesValue` (by value) | the callee |

A `read` or `edit` parameter **is already the carrier's address**. Operations
on it, and calls that lend it onward, pass it unchanged; taking its address
again is a defect, and `bytes-mutation` asserts the emitted text for all three
shapes — an operation on a borrow, a borrow lent onward, and an `edit` borrow
widened to a `read` parameter — while requiring a local owner to still be lent
as `&k_bN`.

## 4. Aliasing

The checkpoint does not claim that every pair of distinct source values has
distinct storage. `bytes-carrier` asserts seven tracked alias-producing shapes
are refused as `E2S170` with distinct reasons, and records that two additional
shapes — escaping store and escaping capture — are refused earlier by `E2S32`
and `E2S96`. The direct `append_range` fixture separately requires two resolved
BindingIds and refuses one BindingId in both positions as `E2S177`.

Within that direct fixture, the BindingId check is the compile-time premise for
the two-carrier copy/refusal boundary in §6; it is not a general wrapper-level
alias proof. One owner in conflicting wrapper slots is refused as `E2S180`
through one- and two-level wrappers (#1561), and complete nested parentheses
preserve the identity the direct check needs (#1562). Neither is claimed
outside those fixture shapes.

## 5. Status

Operations that can fail report a tag and a detail. The nine tags are frozen in
declaration order and the values are the contract:

| tag | name | detail carries |
| --- | --- | --- |
| 0 | succeeded | 0 |
| 1 | negative length | the request |
| 2 | range out of bounds | the offending offset or count |
| 3 | invalid byte | the offending value |
| 4 | capacity exceeded | the requested final length |
| 5 | allocation failed | the requested allocation capacity |
| 6 | invalid UTF-8 | *unused; reserved for #1322* |
| 7 | text contains NUL | *unused; reserved for #1322* |
| 8 | text limit exceeded | *unused; reserved for #1322* |

There is no consumed tag, and `bytes-mutation` refuses one. Tags 6 to 8 belong
to the Text bridge and no operation in this document may emit one; the gate
extracts the operations' own text and checks it.

Reading a byte uses a **separate** carrier with three tags in declaration order
— value, negative offset, out of bounds — where success carries the byte 0..255
and both failures carry the offending offset. It is emitted exactly once, and
the gate asserts that.

## 6. Operations

The checkpoint covers nine direct call shapes that resolve to these compiler
builtins. A current-file declaration or a lexical callable with the same
`stage2_bytes_*` spelling outranks that recognition, and an undeclared control
retains it (#1560). Their leading arguments are carriers:

| operation | arguments | result |
| --- | --- | --- |
| `stage2_bytes_len` | carrier | `Int` |
| `stage2_bytes_capacity` | carrier | `Int` |
| `stage2_bytes_byte_at` | carrier, offset | read carrier (§5) |
| `stage2_bytes_byte_set` | carrier, offset, byte | status |
| `stage2_bytes_clear` | carrier | none |
| `stage2_bytes_reserve` | carrier, capacity | status |
| `stage2_bytes_append` | carrier, byte | status |
| `stage2_bytes_append_range` | destination, source, offset, count | status |
| `stage2_bytes_append_self` | carrier, offset, count | status |

`clear` sets length to zero and preserves capacity and the allocation.
`reserve` may raise capacity and never changes length or bytes.

### 6.1 Growth

The ordinary-allocation mutation driver observes capacity 0 grow to 16 and
then walks each doubling edge until the ceiling. The ladder is walked rather
than spot-checked, because a defect at one step is invisible from the two
around it.

For the injected-failure cases the current driver reaches — append, reserve,
self-append, and two-carrier `append_range` — it observes the named carriers'
retained fields and bytes. The pointer witness and the real `append_range` OOM
call are independently mutation-proved. These are still fixture observations,
not a universal transactionality claim; §6.5 states the exact boundary.

### 6.2 Range checks

Ordered, and the order is observable because a call that is wrong twice reports
the first reason:

1. negative offset — reports the offset;
2. negative count — reports the count;
3. offset past the length — reports the offset;
4. count greater than `length - offset` — reports the count.

A zero-length range at `offset == length` succeeds.

**`offset + count` is never computed.** Two in-range operands can sum past the
ceiling, and a refusal that depends on that sum is one a wrap can skip;
subtraction against the length cannot overflow and refuses the same cases. The
gate passes `INT64_MAX` in both slots.

### 6.3 Precedence between kinds of failure

- For `byte_set`, offset negativity and bounds precede the byte check.
- `append` validates its byte before any capacity or allocation check, so a
  full carrier asked to append a non-byte reports the byte.
- For `append_range`, the mutation matrix's source-range refusals occur before
  its destination capacity and growth paths. It does not combine an invalid
  source range with injected allocation failure, so that broader precedence is
  not claimed.
- Capacity failure reports the requested final length; allocation failure
  reports the requested allocation capacity.

### 6.4 Copying between carriers, and within one

For the direct unparenthesized named-binding forms exercised by the gate,
`append_range` copies from a distinct source carrier and therefore requires its
two carriers to be **distinct bindings**, proved by distinct typed-HIR
BindingIds before any C is emitted. One direct named binding in both positions
is `E2S177`; the author is directed to `append_self`. The C library copy
primitive is an implementation detail, not a frozen part of this checkpoint.
Complete nested parentheses preserve the carrier's BindingId through the
mutation builtins and a declared relay; a parenthesized temporary stays
unnamed (#1562).

`append_self` is the dedicated single-carrier operation. The mutation matrix
proves the original-range bytes survive both non-growth and growth cases; the
C library copy primitive used to achieve that is not part of the checkpoint.

### 6.5 Failure observations are fixture-bounded

The focused driver checks length, capacity, pointer identity, and bytes for its
named refusal cases and builds a second time with allocation failure injected.
Its live-proved `append_range` OOM call snapshots both source and destination;
controlled mutations independently change each peer's saved bytes and must be
named by the corresponding assertion. A separate pointer-only mutation swaps
byte-identical storage after a refusal and must also be named. This proves the
named direct cases, not every source-level ownership, alias, call, or exit
shape. The checkpoint therefore publishes no universal transactionality or
memory-safety promise.

## 7. What a source program can observe

For calls resolved to these builtins in the gated source forms, `len` and
`capacity` return `Int`. The supported form for every other operation is a
complete discarded expression statement: the status and read carriers are
private to the emitted C. `task bytes-mutation` proves those direct supported
forms with a driver compiled against a prelude extracted from a program the
compiler just emitted. All eight compiler-private outcomes are accepted only
as complete discarded expression statements; every other operation and value
context in that matrix refuses as `E2S179` and commits no C (#1559).

This is a deliberate boundary and it is the largest one in this document.
Surfacing either carrier to source needs a compiler-owned enum declaration, and
Stage 2 resolves an enum by scanning the source for its `type` declaration — a
type the compiler owns has no declaration site to be found at. The consumer
that needs a byte in source is #1499.

## 8. Known gaps

Stated here rather than omitted, because a specification that lists only what
works is the kind of published promise this repository gates against:

- **A `take` parameter crossing performs the move and does not record it**, so
  use-after-move through a call is accepted where the same move written as a
  `take` statement is refused with `E2S123` (#1540). The take-transfer fixture
  in §2 therefore does not establish call-crossing use-after-move enforcement.
- **A temporary `Bytes` call result passed to a direct declared `read`, `edit`,
  or `take` parameter is not yet refused by Stage 2** and can reach invalid
  generated C (#1516).
- **Seventy-one `Bytes` locals in one function are refused under `E2S170`'s
  alias reason** when the actual cause is a cleanup-list buffer, and only by
  one half of the pair (#1556).
- **The record and `Bytes` typed-return forms have no owning-Bytes fixture.**
  The dropped trap-guard cleanup for `List[Int]`, `Int?` and enum returns is
  fixed and proved beside the `Text` control, and the two halves no longer
  disagree on where the cleanup goes (#1569); the remaining two forms are
  still outside the executable matrix.
- **The post-take failure guard of a `Bytes`-returning function may discard the
  result carrier.** Reachability and an executable ownership proof remain
  unresolved (#1581).
