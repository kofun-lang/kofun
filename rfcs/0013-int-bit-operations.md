# RFC-0013: Bit operations on `Int` are named methods, and the operator symbols stay free

- Shepherd: hjosugi
- Opened: 2026-08-12
- Status: accepted

## Summary

`Int` gains eight bit operations, spelled as postfix methods: `and`, `or`,
`xor`, `not`, `shl`, `shr`, `rotr`, and `wrapping_add`. No operator symbol is
added, no keyword is reserved, and no existing program changes meaning. Someone
writing Kofun can express a 32-bit hash round for the first time.

## Motivation

Kofun cannot compute a digest, and the reason is not that nobody has written the
code.

The language's entire operator set is `+ - * / // % **` and unary `+ - !`
(`spec/grammar.ebnf:121-124`). There is no `&`, `|`, `^`, `<<`, or `>>`, and no
way to obtain one — a bit operation has to be built from `//`, `%`, and `**`,
one bit at a time. SHA-256 performs roughly sixty-four rounds of six such
operations over 32-bit words; expressed arithmetically that is thousands of
loop iterations per block, in a bounded Core, written twice because the Stage 2
compiler is a hand-transliterated pair.

So the repository's own SHA-256 is in C. `bin/kofun-digest` is a shell script
that builds `bootstrap/stage2/sha256_tool.c` against `bootstrap/stage2/sha256.c`,
and its header says why: to stop depending on GNU `sha256sum`. Not one of the
1105 tracked `.kofun` sources implements a digest, because none can.

That is load-bearing rather than cosmetic. Every identity the compiler assigns
is a SHA-256 preimage — `ModuleId`, `FileId`, `SymbolId`, and the scope-HIR v2
`ParId`/`TaskId`/`JoinId` frozen in
`spec/concurrency/scoped-captures-v1.md`. **The compiler cannot compute the
identities it is specified to assign.** #1220 asks it to emit `ParId` and
`TaskId`; it cannot, and neither can any successor, until this exists.

The self-hosting goal makes this sharper. A chain whose digests are computed by
a C tool the Kofun language could not express is a chain with a permanent C
dependency at its centre.

## Detailed design

No grammar change. `postfix = primary, { call | member | index }` already admits
the member-call form, and `handle.join()` is an existing use of it
(`spec/grammar.ebnf:125`, `:155`).

Eight operations on `Int`:

| Method | Meaning |
|---|---|
| `a.and(b)` | bitwise AND |
| `a.or(b)` | bitwise OR |
| `a.xor(b)` | bitwise XOR |
| `a.not()` | bitwise complement |
| `a.shl(n)` | left shift |
| `a.shr(n)` | right shift, arithmetic |
| `a.rotr(n, width)` | right rotate within `width` bits |
| `a.wrapping_add(b, width)` | addition modulo `2**width` |

`rotr` and `wrapping_add` take an explicit `width` because Kofun has one integer
type. A language with `Word32` gets the width from the type; here it has to be
said, and saying it is better than a second type or an implied 64.

### Why no operator symbols

`&`, `^`, `<<`, and `>>` are free — zero occurrences in the grammar. `|` is
not: it delimits the `par` scope token (`par_expr = "par", "|", identifier,
"|", block`) and separates ADT variants.

An operator set that covers four of the five would leave `a & b`, `a ^ b`,
`a << n`, `a >> n`, and `a.or(b)`. A dense expression then mixes both spellings
on one line, which is the cost of symbols without the benefit that motivates
them.

Haskell met the same collision — `|` taken by guards and `data X = A | B` — and
answered with `.&.` and `.|.`, keeping `xor` a plain name because `^` was
already exponentiation. Rust could keep single `|` only because its enums use
commas; it still pays for `|` meaning three things by position (bitwise-or,
or-pattern, closure delimiter).

And symbols would not finish the job. Rust has every operator and still spells
the two operations SHA-256 needs most as methods:

```rust
let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
let t1 = h.wrapping_add(s1).wrapping_add(ch).wrapping_add(k).wrapping_add(w);
```

Kofun's `+` traps on overflow, so modular addition needs a name here too.
Adding symbols would produce a mixed spelling, not a uniform one.

Symbols remain available as a later amendment: `a & b` defined as sugar for
`a.and(b)`, and likewise `^`, `<<`, `>>`. One authority, mechanical desugaring.
`|` stays unavailable, so `or` would keep its method-only spelling. That
amendment should follow a working implementation rather than accompany it.

## Semantics

**Two's complement.** `Int` is signed 64-bit. `and`, `or`, `xor`, and `not`
operate on the two's-complement bit pattern, so `(-1).and(255)` is `255` and
`0.not()` is `-1`. Negative operands are ordinary, not refused: refusing them
would make the operations unusable on any value that has already been through
`not`.

**`shr` is arithmetic.** It replicates the sign bit, so `(-8).shr(1)` is `-4`.
Kofun has no unsigned type, so there is no second logical form; a caller who
wants logical shift masks first. This is stated because it is the one place a
reader could reasonably expect either answer.

**Shift counts are `0..63`.** A count outside that range is a runtime trap,
`R011`, not a mask and not a saturation. Masking is the behaviour that silently
computes `x.shl(64)` as `x`, which is a wrong answer that looks like an answer.
This follows Kofun's existing checked-arithmetic stance rather than C's
undefined behaviour or Rust's release-mode mask.

**`shl` traps on overflow.** `a.shl(n)` traps as `R010` when the result would
leave signed 64-bit range, exactly as `a * 2**n` does today. Checked arithmetic
is the language's rule, and a shift is not an exception to it — which is
precisely why `wrapping_add` exists as a separate, explicitly-named operation.

**`width` is `1..64`.** `rotr` and `wrapping_add` trap as `R011` outside it. For
both, the value operands are first reduced modulo `2**width`, so a caller
working in 32 bits does not have to mask before every call.

**No effects.** All eight are pure, total apart from the stated traps, and
consult nothing.

## Diagnostics

Two runtime codes and no new compile-time family:

- `R010`, the existing integer-overflow trap, covers `shl`.
- `R011`, new, covers a shift count outside `0..63` and a width outside `1..64`.
  It is separate from `R010` because "you shifted too far" and "your shift count
  is not a shift count" are different mistakes, and a reader who sees the second
  reported as the first will look at the wrong operand.

A non-`Int` receiver or argument is refused by ordinary type checking with the
existing `E2S` arity/type diagnostics; no new code is required for it.

## Ownership and effects

None. `Int` is a copied scalar, the operations take and return values, and
nothing borrows, moves, or observes the environment. No capability argument
appears in any signature.

## Alternatives

**Operator symbols for the four that are free.** Rejected above: it leaves `or`
asymmetric and still needs methods for rotation and modular addition.

**A string mini-expression** such as `raw_bit("a | b")`. Rejected. Names inside
a string literal do not pass the resolver, so `a` never becomes a `use` in
scope-HIR — binding analysis, ownership, captures, LSP references, and
incremental dependencies all stop seeing it. It also makes spelling the
identity, which this project refuses elsewhere on purpose: RFC-0012 admits
`raw-foreign` only as adjacent bytes, and scope-HIR v2 derives every ID from
resolved identities rather than from what a name looks like.

**A `meta` mechanism.** `meta_function_decl` exists in the grammar
(`spec/grammar.ebnf:69`) and is implemented nowhere — zero occurrences of
`"meta"` in `bootstrap/stage2/compiler.kofun` and no tracked source uses it. It
is not an available path today.

**Leave SHA-256 in C.** This is the status quo and it is coherent; the cost is
that the bootstrap's identity computation is permanently outside the language,
and that every specification naming a SHA-256 preimage is a specification the
compiler cannot implement.

## Drawbacks

Eight builtins on a scalar type is surface that must be lowered on every
declared backend — C11, native x86-64, AArch64, and wasm32 — and kept in step
across a hand-transliterated compiler pair. The width parameter on `rotr` and
`wrapping_add` is friction a language with sized integer types would not have,
and it will read as clutter to anyone arriving from one.

`shr` being arithmetic-only means a caller wanting a logical shift writes a mask
by hand. That is a real ergonomic cost, accepted here rather than solved,
because solving it means either a second method or an unsigned type, and both
are larger decisions than this one.

## Compatibility and migration

Additive. No tracked program changes meaning and none stops compiling.

No syntax changes: the member-call form already exists. No word is reserved —
`and`, `or`, `xor`, `not`, `shl`, `shr`, `rotr`, and `wrapping_add` remain
ordinary identifiers everywhere, including as user function and field names,
exactly as `join` does today. The names become meaningful only as members of an
`Int` receiver.

`R011` is a new runtime code; no existing program can reach it, because no
existing program can call an operation that raises it.

- **corpus_query**: `git ls-files '*.kofun' | wc -l; git grep -cE '^[[:space:]]*fn (and|or|xor|not|shl|shr|rotr|wrapping_add)\(' -- '*.kofun' | wc -l; git grep -cE '\.(and|or|xor|not|shl|shr|rotr|wrapping_add)\(' -- '*.kofun' | wc -l`
- **result**: `1105`, `0` and `0` at `ffa3d8a7`, the audited commit. No tracked
  source declares a function with any of the eight names, and none calls a
  member with them, so no spelling collides and nothing acquires new behaviour.

## Implementation plan

1. The eight operations on the canonical Stage 2 pair, with `R010`/`R011`.
2. A Kofun SHA-256 built on them, gated against the NIST vectors and against
   `bootstrap/stage2/sha256.c` on the same inputs — the C implementation stays
   as the differential oracle rather than being replaced.
3. Backend lowering, one child per declared backend.
4. Only then, the identities that need it: scope-HIR v2 `ParId`/`TaskId`/`JoinId`
   (#1220), and whatever else moves off the C digest tool.

Step 2 is deliberately a standalone gate before step 4. A hash that is wrong is
a hash that produces stable, self-consistent, entirely incorrect identities, and
the cheapest place to catch that is against published vectors rather than inside
the compiler.

## Validation

| Check | Command | Expected |
|---|---|---|
| Operation semantics | new `task int-bits` | two's complement, arithmetic `shr`, trap codes at their bounds and one past |
| Digest differential | new `task kofun-digest-model` | NIST vectors, and byte-identical agreement with `sha256.c` over a corpus |
| Pair | `task stage2 && task selfhost-fixed-point` | canonical pair synchronized, fixed point holds |
| Names stay free | `task module-symbols` | `fn and()` and `fn or()` still collect as ordinary declarations |
| Repository | `task verify` | no regression |

## Unresolved questions

**Whether `shl` should trap or wrap.** This proposes trapping, consistent with
`*`. A hash implementation then writes `a.shl(n).wrapping_add(0, 32)` where it
means a 32-bit shift, which is awkward enough that a `wrapping_shl` may be
wanted. Deferred rather than guessed: the answer should come from writing the
SHA-256 in step 2 and seeing which form the code actually wants.

**Whether `width` belongs on the operation or in a type.** An `Int32` or a
`Word32` would remove the parameter from `rotr` and `wrapping_add` entirely.
That is a much larger decision about Kofun's numeric tower, and this proposal
deliberately does not open it.
