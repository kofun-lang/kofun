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
  operation has a compiler-private emitted-C outcome, and Stage 2 does not yet
  refuse all source value contexts that try to consume it (#1559, §7);
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

**The empty value is exactly `{0, 0, NULL}`.** In the take-transfer fixture
exercised by `task bytes-carrier`, the emitted move leaves the source with those
bits and the sanitizer proof observes exactly one release. This is evidence for
that fixture, not a claim that every call crossing records or rejects later use
of the moved binding (#1540).

A length of zero allocates nothing. `malloc(0)` may return a non-null pointer,
which would make an empty value distinguishable from a one-allocation one, so
it is never called.

## 3. Ownership

A locally created `Bytes` owner in the exercised fixture functions is reclaimed
in reverse creation order. This is not reference counting and there is no
arena.

For the owning fixture functions exercised by `task bytes-carrier`, the gate
derives the emitted returns within those functions and requires each one to
reclaim every live local owner in reverse creation order. This is not a
proof over unexercised typed-return lowering arms (§8).

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

For the named-binding fixtures exercised by `task bytes-carrier`, distinct
`Bytes` owners do not share storage. Nine shapes that could create an alias are
refused as `E2S170`, each naming its own reason: an alias initializer, a branch
mismatch, loop-carried storage, a recursive summary, an escaping return, a
backend limitation, and the rest. The gate asserts seven of them by reason and
records that escaping store and escaping capture are refused earlier by
`E2S32` and `E2S96`.

For direct `append_range` calls in `task bytes-mutation`, the compiler also
requires distinct resolved BindingIds before C emission. That is the bounded
identity proof behind §6's copy rule; it is not a general alias analysis or a
claim about source shapes outside the gated resolver paths.

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
builtins. It does not prove that a source or lexical callable with the same
spelling always outranks builtin recognition (#1560). Their leading arguments
are carriers:

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
Parenthesized carrier identity is a known gap (#1562).

`append_self` is the dedicated single-carrier operation. The mutation matrix
proves the original-range bytes survive both non-growth and growth cases; the
C library copy primitive used to achieve that is not part of the checkpoint.

### 6.5 Failure preserves everything

Every operation refusal exercised by `task bytes-mutation` leaves the
participating carriers' length, capacity, pointer and bytes exactly as it found
them. The gate executes the injected-allocation-failure `append_range` call and
re-checks both its source and destination.

## 7. What a source program can observe

For calls resolved to these builtins in the gated source forms, `len` and
`capacity` return `Int`. The supported form for every other operation is a
complete discarded expression statement: the status and read carriers are
private to the emitted C. `task bytes-mutation` proves those direct supported
forms with a driver compiled against a prelude extracted from a program the
compiler just emitted. It does not carry a comprehensive private-result
rejection matrix; current Stage 2 permits multiple source value contexts to
reach invalid generated C (#1559).

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
- **A `read Bytes` borrow may satisfy a declared `edit Bytes` parameter or an
  edit destination of `assign_zeroed`, `byte_set`, `clear`, `reserve`,
  `append`, `append_range`, or `append_self`.** The invalid const-discarding
  crossing is detected only by the host C compiler (#1517).
- **Compiler-private Bytes operation outcomes are not refused in source value
  contexts.** Binding, print, return/final expression, argument, arithmetic,
  equality/comparison, and additional multiline or parenthesized contexts can
  reach invalid generated C instead of being limited to complete discarded
  expression statements (#1559).
- **Builtin recognition can outrank a source or lexical callable with the same
  `stage2_bytes_*` spelling**, so the direct-call table in §6 is not a general
  callable-resolution precedence claim (#1560).
- **One Bytes owner may satisfy conflicting wrapper slots when the carrier's
  identity is lost across call binding**, so wrapper-call owner uniqueness is
  outside the fixture proof (#1561).
- **Parentheses can erase a named Bytes carrier BindingId**, allowing an alias
  or mutability check to miss a source shape that its unparenthesized form
  rejects (#1562).
- **Seventy-one `Bytes` locals in one function are refused under `E2S170`'s
  alias reason** when the actual cause is a cleanup-list buffer, and only by
  one half of the pair (#1556).
- **All six typed-return forms lack an owning-Bytes fixture.** The C trap guard
  drops cleanup for `List[Int]`, `Int?`, and enum returns; C/Kofun indentation
  placement also diverges for those three plus record and `Text`. The `Bytes`
  return has no identified pair divergence, but remains outside the executable
  fixture matrix (#1569).
- **The post-take failure guard of a `Bytes`-returning function may discard the
  result carrier.** Reachability and an executable ownership proof remain
  unresolved (#1581).
