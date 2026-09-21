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
- reliably observable from source beyond `len`, `capacity`, and the byte
  `byte_at` reads (#1499) — every other operation has a compiler-private
  emitted-C outcome, and Stage 2 refuses the source value contexts that try
  to consume it (#1559, §7);
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
for the forms named by the fixture set. A bare owning Bytes argument to a
resolved current-file positional `take` parameter is recorded in straight-line
source order; later use and second transfer are E2S123, keyed by BindingId.
This does not extend to temporary/compound arguments, indirect calls or a
general CFG ownership proof (`task move-call-crossings`, #1540).

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
at every exit. The non-`Bytes` typed guards covered by #1569 reclaim their
owners. For the whole-carrier `Bytes` return, `emit_bytes_return` checks failure
and releases live owners before the non-failing field transfer (#1581). Its
two-allocation fixture and emitted-C fault probe check success transfer, both
failure releases, and a mutation restoring the old post-take guard. This is an
injected compiler-template proof, not a natural source-level failure reproducer.

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

Operations that can fail report a tag and a detail. The ten tags are frozen in
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
| 9 | file unreadable | 0 when the path did not open, 1 when it opened and did not read (#1499) |

There is no consumed tag, and `bytes-mutation` refuses one. Tags 6 to 8 belong
to the Text bridge and no operation in this document may emit one; the gate
extracts the operations' own text and checks it.

Reading a byte has no carrier. `byte_at` returns the byte 0..255 as an `Int`,
and an offset outside `0..length-1` is the runtime diagnostic `R025` with a
zero result — the shape a `List[Int]` index outside its list already has
(`R023`). #1499 retired the three-tag read carrier that used to hold those
outcomes, and `bytes-mutation` asserts it is no longer emitted.

## 6. Operations

The checkpoint covers ten direct call shapes that resolve to these compiler
builtins. A current-file declaration or a lexical callable with the same
`stage2_bytes_*` spelling outranks that recognition, and an undeclared control
retains it (#1560). Their leading arguments are carriers:

| operation | arguments | result |
| --- | --- | --- |
| `stage2_bytes_len` | carrier | `Int` |
| `stage2_bytes_capacity` | carrier | `Int` |
| `stage2_bytes_byte_at` | carrier, offset | `Int` (§5, §7) |
| `stage2_bytes_byte_set` | carrier, offset, byte | status |
| `stage2_bytes_clear` | carrier | none |
| `stage2_bytes_reserve` | carrier, capacity | status |
| `stage2_bytes_append` | carrier, byte | status |
| `stage2_bytes_append_range` | destination, source, offset, count | status |
| `stage2_bytes_append_self` | carrier, offset, count | status |
| `stage2_bytes_read_file` | carrier, path | status (§6.6) |

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

### 6.6 Reading a file

`read_file` (#1499) replaces the carrier's bytes and length with a file's,
named by a `Text` path. Capacity grows exactly as `append` would grow it to
the file's length, and an empty file leaves the allocation in place with
length 0. The file is read into a private window one byte wider than the
ceiling *before* anything about the carrier changes, so every failure leaves
length, capacity, pointer, and bytes as they were:

| failure | status | runtime diagnostic |
| --- | --- | --- |
| the path does not open, or opened and does not read | 9, detail 0 or 1 | `R026` |
| the file is longer than 65,536 bytes | 4, detail 65,537 | `R027` |
| the window, or the carrier's growth, cannot be allocated | 5 | `R028` |

The over-the-ceiling detail is 65,537 and not the file's length: the read
stops one byte past the ceiling and never learns the rest, because a size
query (`ftell`) answers nothing useful for a pipe and `fstat` is not C11.

Every one of these failures is **also** a runtime diagnostic, which no other
operation in this document is. The others hand a private status to a driver;
a compiled program has no driver, and a read that failed silently would leave
it digesting the carrier it started with as if it were the file. The file read
is therefore the one operation whose refusal a program meets as a named exit,
and `task bytes-read-file` proves each of the three by supplying the file,
the missing path, and a spent allocator. It does not establish reading a file
in chunks, a file longer than the ceiling in any form, or a path that has
crossed an attenuated filesystem authority (§8).

## 7. What a source program can observe

For calls resolved to these builtins in the gated source forms, `len`,
`capacity`, and `byte_at` return `Int`. The supported form for every other
operation is a complete discarded expression statement: the status is private
to the emitted C. `task bytes-mutation` proves those direct supported forms
with a driver compiled against a prelude extracted from a program the compiler
just emitted. All eight compiler-private outcomes — `assign_zeroed`,
`byte_set`, `clear`, `reserve`, `append`, `append_range`, `append_self`, and
`read_file` — are accepted only as complete discarded expression statements;
every other operation and value context in that matrix refuses as `E2S179` and
commits no C (#1559), and the same matrix accepts `byte_at` in each of those
contexts and prints the byte (#1499).

This is a deliberate boundary and it is the largest one in this document.
Surfacing the status to source needs a compiler-owned enum declaration, and
Stage 2 resolves an enum by scanning the source for its `type` declaration — a
type the compiler owns has no declaration site to be found at. The consumer
that needed a byte in source was #1499, and that is why `byte_at` crossed the
boundary as an `Int` with a runtime diagnostic rather than as a carrier: the
value it needed already has a shape (a `List[Int]` element) and so does the
failure (`R023`). `task bytes-read-file` proves a compiled program reads a
file into a carrier and digests it with the pair's own `sha256_*` functions,
matching `bin/kofun-digest` on the same file.

## 8. Known gaps

Stated here rather than omitted, because a specification that lists only what
works is the kind of published promise this repository gates against:

- **A file read takes a bare `Text` path and no authority.** RFC-0014 rejects
  ambient cwd and a broad path-string capability, and RFC-0018 requires source
  and package reads to cross an attenuated filesystem authority; `read_file`
  does neither, and Stage 2 has no `DirectoryAuthority` or authority-derived
  file handle for it to take. #1499's thread records that prerequisite as
  unowned. Until it lands, the read is a bounded host-boundary operation of
  the C11 backend, not a capability of the language.
- **A file read is whole-file and at most 65,536 bytes.** There is no chunked
  read over an open handle, so a file longer than the ceiling cannot be
  digested by a compiled program at all; it is refused by name (§6.6).

- **Positional move checking remains a bounded source-order rule**, not a
  general CFG, alias, lifetime or cleanup analysis. #1540 closes the direct,
  bare owning Bytes call gap; excluded compound/indirect/conditional shapes
  are not proved by that gate.
- **Temporary Bytes arguments remain unsupported**, but #1516 now refuses
  direct declared `read`, `edit`, and `take` crossings as E2S177 before C or
  executable publication, naming the argument position. Materializing a
  temporary into a compiler-owned binding is not implemented.
- **The record typed-return form has no owning-Bytes fixture.**
  The dropped trap-guard cleanup for `List[Int]`, `Int?` and enum returns is
  fixed and proved beside the `Text` control, and the two halves no longer
  disagree on where the cleanup goes (#1569). The whole-carrier `Bytes` return
  has the bounded success/fault-injection proof described in §3 (#1581).
