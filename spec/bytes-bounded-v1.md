# Bounded `Bytes` v1

This document records the bounded C11 Stage 2 checkpoint exercised by
`task bounded-bytes`. It describes the carrier and direct emitted-runtime
operations reached by the checked-in fixtures; it does not assert that every
source-level `Bytes` shape is implemented or memory-safe. The unresolved
ownership, call-crossing, result-context, exit-path, and evidence boundaries
are explicit in §8.

**Every statement published as part of the checkpoint names the gate that
fails if it is false.** The aggregate is `task bounded-bytes`; it runs
`task bytes-carrier` first (#1315, the tracked carrier fixtures) and then
`task bytes-mutation` (#1321, the direct operation fixtures) so their shared
build output is not written concurrently. Where a statement is proved by a
specific assertion, the assertion is named rather than described, so a reader
can check the exact boundary.

## 1. What this is, and what it is not

Within this checkpoint, `Bytes` is emitted as a bounded byte-buffer carrier
with a fixed ceiling of 65,536 bytes. The tracked fixtures exercise named local
owners and direct transfer/borrow shapes so a C11 Stage 2 program can build a
byte sequence whose length is not known when it starts. "Uniquely owned" is an
intent checked at those named sites, not a general alias or call-crossing proof;
§§3, 4, and 8 state the open boundaries.

It is **not**:

- a general buffer — the ceiling is fixed at compile time and is not
  configurable;
- convertible to or from `Text` — there is no bridge, and the three status tags
  reserved for one are unused (§5). That is #1322;
- atomically replaceable in a bound target — that is #1323 and #1324;
- generally source-observable beyond the admitted `len` and `capacity`
  fixtures — the other direct-operation outcomes are private to the emitted C,
  but invalid source-value contexts are not yet consistently refused (#1559,
  §7);
- available on any backend but C11 Stage 2.

## 2. The carrier

Three fields, in this order, and the order is frozen:

| field | type | meaning |
| --- | --- | --- |
| `length` | `uint64_t` | bytes currently held |
| `capacity` | `uint64_t` | bytes the allocation can hold |
| `data` | `unsigned char *` | the allocation, or `NULL` |

The C emitted for the tracked fixtures carries `_Static_assert`s for the offset
of `length` (0), the offset of `capacity` (8), the width of `data` (8), and the
alignment of the struct (8). The gates compile those emitted fixtures rather
than accepting a handwritten layout table.

**The empty value in the extracted prelude is exactly `{0, 0, NULL}`.** The
tracked direct-transfer fixture requires an emitted `kofun_bytes_take` and runs
sanitizer-clean, but it does not independently snapshot all three fields of the
moved-from binding. This checkpoint therefore does not publish an exact
moved-from-bit-pattern guarantee. Compile-time use-after-move is proved only
for the forms named by the fixture set; an ordinary positional `take` call is
still not recorded as a move (#1540).

The extracted helper allocates nothing for a length of zero. `malloc(0)` may
return a non-null pointer, which would make an empty value distinguishable from
a one-allocation one, so that helper does not call it.

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

For the admitted direct parameter fixtures, a parameter carries one of three
modes, and a `Bytes` parameter with no mode is refused:

| mode | C carrier | who reclaims |
| --- | --- | --- |
| `read` | `const KofunBytesValue *` | the caller |
| `edit` | `KofunBytesValue *` | the caller |
| `take` | `KofunBytesValue` (by value) | the callee |

In `borrowed_carrier.kofun`, a `read` or `edit` parameter is already the
carrier's address. `bytes-mutation` asserts the emitted text for an operation on
a borrow, a borrow lent onward, and an `edit` borrow widened to a `read`
parameter, while requiring the local-owner control to be lent as `&k_bN`.
That fixture does not prove the complete access/crossing matrix: temporary
arguments, read-to-edit escalation, positional `take` move tracking, duplicate
wrapper slots, and parenthesized identity remain #1516, #1517, #1540, #1561,
and #1562.

## 4. Aliasing

The checkpoint does not claim that every pair of distinct source values has
distinct storage. `bytes-carrier` asserts seven tracked alias-producing shapes
are refused as `E2S170` with distinct reasons, and records that two additional
shapes — escaping store and escaping capture — are refused earlier by `E2S32`
and `E2S96`. The direct `append_range` fixture separately requires two resolved
BindingIds and refuses one BindingId in both positions as `E2S177`.

Within that direct fixture, the BindingId check is the compile-time premise for
the two-carrier copy/refusal boundary in §6; it is not a general wrapper-level
alias proof. One owner can still satisfy conflicting wrapper slots (#1561), and
transparent parentheses can erase the identity the direct check needs (#1562).

## 5. Status

Operations in the extracted C prelude that can fail report a tag and a detail.
The nine tags are frozen in declaration order for this checkpoint:

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

Reading a byte in the extracted prelude uses a **separate** carrier with three
tags in declaration order — value, negative offset, out of bounds — where
success carries the byte 0..255 and both failures carry the offending offset.
The direct gate requires that declaration to be emitted exactly once.

## 6. Operations

The extracted C runtime used by the direct fixtures contains nine helpers whose
leading arguments are carriers:

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

The direct driver observes `clear` set length to zero while preserving capacity
and the allocation. It observes `reserve` raise capacity without changing
length or retained bytes.

This table describes the helpers the direct fixture resolves as builtins. It
does not prove source-value context validation (#1559) or that a user-declared
function with the same spelling wins during emission (#1560).

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

In the direct mutation driver the range checks are ordered, and a call that is
wrong twice reports the first reason:

1. negative offset — reports the offset;
2. negative count — reports the count;
3. offset past the length — reports the offset;
4. count greater than `length - offset` — reports the count.

A zero-length range at `offset == length` succeeds.

**The extracted helper does not compute `offset + count`.** Two in-range
operands can sum past the ceiling, and a refusal that depends on that sum is one
a wrap can skip; subtraction against the length cannot overflow and refuses
the same cases. The direct gate passes `INT64_MAX` in both slots.

### 6.3 Precedence between kinds of failure

- In the direct driver, `byte_set` offset negativity and bounds precede the
  byte check.
- `append` in that driver validates its byte before any capacity or allocation
  check, so a full carrier asked to append a non-byte reports the byte.
- For `append_range` in that driver, the source range is validated before a
  destination capacity failure. A separate valid-range call under a spent
  allocation budget reports allocation failure; the gate makes no broader
  mixed-invalidity ordering claim for that case.
- In the direct driver, capacity failure reports the requested final length;
  allocation failure reports the requested allocation capacity.

### 6.4 Copying between carriers, and within one

The direct builtin `append_range` fixture observes a copy between two named
carriers and requires two resolved typed-HIR BindingIds before C is emitted.
Its focused refusals reject one BindingId in both positions, or an identity
that cannot be resolved, as `E2S177`; the author is directed to `append_self`.
The extracted operation text contains both `memcpy` and `memmove`, but the gate
does not bind either spelling to one specific helper, so this checkpoint does
not freeze the copy primitive. The direct defense does not cover duplicate
storage passed through wrapper parameters (#1561), and parenthesized named
carriers are currently refused as unresolved (#1562).

The direct `append_self` fixture validates against the length *before* growth
and observes the correct self-copy bytes, including a case that reallocates;
the observable result, not a particular C copy primitive, is checkpointed.

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

The admitted direct `len` and `capacity` fixtures return `Int`. The status and
read carriers used by the other direct-operation fixtures are private to the
emitted C and are inspected by a driver compiled against a prelude extracted
from a program the compiler just emitted.

That arrangement is not yet enforced for every source context. Binding,
printing, returning, comparing, or otherwise using a private outcome can reach
invalid emitted C instead of a named refusal (#1559), and a declaration with a
`stage2_bytes_*` spelling can be hijacked by builtin emission (#1560). The
release checkpoint claims only the tracked direct fixtures, not general
source-result isolation.

This is a deliberate boundary and it is the largest one in this document.
Surfacing either carrier to source needs a compiler-owned enum declaration, and
Stage 2 resolves an enum by scanning the source for its `type` declaration — a
type the compiler owns has no declaration site to be found at. The consumer
that needs a byte in source is #1499.

## 8. Known gaps

Stated here rather than omitted, because a specification that lists only what
works is the kind of published promise this repository gates against:

- **A temporary `Bytes` ordinary argument emits `&<rvalue>`** and reaches a host
  C error instead of a source refusal (#1516).
- **A `read Bytes` borrow may satisfy an `edit Bytes` slot**, and only the host
  C compiler notices the discarded qualifier (#1517).
- **An ordinary positional `take` call does not record the move**, so later use
  is accepted where a standalone transfer is refused as `E2S123` (#1540).
- **Seventy-one `Bytes` locals are refused under `E2S170`'s alias reason** when
  the actual cause is a cleanup-list buffer, and only by one half of the pair
  (#1556).
- **Compiler-private read/status/`Void` outcomes can be used as source values**
  and reach invalid C rather than a named refusal (#1559).
- **A user declaration named `stage2_bytes_*` can be hijacked by builtin
  lowering**, despite validation resolving the declaration (#1560).
- **One owner can satisfy conflicting `edit`/`take` wrapper slots** and bypass
  the callee-local direct BindingId defense (#1561).
- **Transparent outer parentheses erase a named carrier's BindingId**, causing
  a valid carrier to be refused as a temporary and leaving identity-dependent
  checks incomplete (#1562).
- **Three non-`Bytes` typed-return failure guards omit live-owner cleanup, and
  five typed-return templates differ between the canonical halves** (#1569).
- **The post-transfer guard of a `Bytes` return can discard the result-local
  carrier without releasing it if reachable**; reachability itself is not yet
  proved (#1581).
