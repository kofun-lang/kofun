# Bounded `Bytes` v1

The `Bytes` carrier the C11 Stage 2 backend lowers, and the operations it
admits. Everything here is implemented and gated today; nothing in this
document describes intent.

**Every normative statement names the gate that fails if it is false.** A
statement with no gate does not belong in this document — the two gates are
`task bytes-carrier` (#1315, the carrier) and `task bytes-mutation` (#1321, the
operations). Where a statement is proved by a specific assertion, the
assertion is named rather than described, so a reader can go and check.

## 1. What this is, and what it is not

`Bytes` is a **bounded, uniquely-owned byte buffer** with a fixed ceiling of
65,536 bytes. It exists so a program the C11 Stage 2 backend compiles can build
a byte sequence whose length is not known when it starts.

It is **not**:

- a general buffer — the ceiling is fixed at compile time and is not
  configurable;
- convertible to or from `Text` — there is no bridge, and the three status tags
  reserved for one are unused (§5). That is #1322;
- atomically replaceable in a bound target — that is #1323 and #1324;
- observable from source beyond `len` and `capacity` — every other operation
  returns `Void` at source level and its outcome is private to the emitted C
  (§7);
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

**The empty value is exactly `{0, 0, NULL}`.** A consumed binding — one whose
storage was moved away — leaves exactly the same bits. The two are
deliberately indistinguishable at run time, so no runtime tag may be inferred
from zero fields. Use-after-move is a compile-time question, and §8 records
precisely how much of it is currently answered.

A length of zero allocates nothing. `malloc(0)` may return a non-null pointer,
which would make an empty value distinguishable from a one-allocation one, so
it is never called.

## 3. Ownership

A `Bytes` binding is *owned*: the function that declares it reclaims it at
every exit, in reverse creation order. This is not reference counting and there
is no arena — an arena cannot free in reverse lexical order at each exit, which
is what the transfer rules need.

`bytes-carrier` derives this from the emitted C rather than asserting a list of
sites: it counts the `return` statements in the owning function and requires
every one of them to reclaim every live owner, so a new emission site is
covered the day it lands.

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

Two distinct `Bytes` values never share storage. Nine shapes that could create
an alias are refused as `E2S170`, each naming its own reason: an alias
initializer, a branch mismatch, loop-carried storage, a recursive summary, an
escaping return, a backend limitation, and the rest. `bytes-carrier` asserts
seven of them by reason, and records that two — escaping store and escaping
capture — are refused earlier, by `E2S32` and `E2S96`, so no fixture is written
against a reason no compiler reaches.

This is what makes §6's copy rule sound: because two distinct values never
overlap, proving two carriers are distinct proves their storage does not
overlap, and the proof is a compile-time identity check rather than a run-time
test.

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

Nine, and the leading arguments are always carriers:

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

Capacity 0 grows to 16; thereafter it doubles until the request fits, capped at
the ceiling. The ladder is walked by the gate rather than spot-checked, because
"doubles until it fits" is a statement about every step and a defect at one
step is invisible from the two around it.

Growth is **transactional**: the new allocation is taken and filled before the
old pointer is released, so a failure has nothing to undo.

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
- For `append_range`, the source range is validated before any destination
  capacity, growth or allocation failure.
- Capacity failure reports the requested final length; allocation failure
  reports the requested allocation capacity.

### 6.4 Copying between carriers, and within one

`append_range` copies with `memcpy` and therefore requires its two carriers to
be **distinct bindings**, proved by distinct typed-HIR BindingIds before any C
is emitted. One value in both positions, or an identity the typed HIR could not
resolve, is `E2S177`; the author is directed to `append_self`.

`append_self` is the dedicated single-carrier operation. It validates against
the length *before* growth, grows transactionally, and copies with `memmove`
from the post-growth buffer's original range.

### 6.5 Failure preserves everything

Every failure of every operation leaves length, capacity, pointer and bytes
exactly as it found them, including under an injected allocation failure. The
gate builds its driver a second time with the allocator made to fail and
re-checks the same properties.

## 7. What a source program can observe

`len` and `capacity` return `Int`. Every other operation is `Void` at source
level: the status and the read carrier are private to the emitted C and are
proved there, by a driver compiled against a prelude extracted from a program
the compiler just emitted.

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
  `take` statement is refused with `E2S123` (#1540). §2's claim that
  use-after-move is a compile-time question is therefore true only for the
  statement form today.
- **Six of the fifteen argument-crossing combinations emit C that does not
  compile** rather than being refused by name (#1516, #1517).
- **Seventy-one `Bytes` locals in one function are refused under `E2S170`'s
  alias reason** when the actual cause is a cleanup-list buffer, and only by
  one half of the pair (#1556).
