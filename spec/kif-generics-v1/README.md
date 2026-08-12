# KIF generics v3 codec

The producer-independent side of [RFC-0017](../../rfcs/0017-generics-kif-proof-profile.md)
section 4: a canonical codec, validator, golden corpus, and adversarial gate
for the generic/trait interface envelope, with no compiler producer or
resolver attached.

Run:

```sh
sh spec/kif-generics-v1/check.sh
```

## Why this is not in the compiler

A codec checked only against its own producer proves that one program is
self-consistent. `model.mjs` shares no code with `bootstrap/stage2/kif_v1.c`
and is derived from the decision and from
[`spec/modules/module-identity.md`](../modules/module-identity.md), so a
disagreement between the two is a finding rather than a diff in a shared
helper. The scope excludes the production hookup deliberately: the format has
to be reviewable before anything depends on it.

## What the envelope is

`kofun.kif/generics-v3`, major version 3. It does not extend or reinterpret
v1/v2 — it reuses the framing *rules* the decision keeps, and no v1/v2 tag,
digest domain, or byte. The gate builds the real `kif_v1_tool` and offers it a
v3 envelope; the production reader refuses it as rebuild-required, which is the
half of "no old artifact is reinterpreted as v3" that this model cannot honestly
assert about itself.

Records are `kind:u16be`, `length:u32be`, payload. **Records sort by identity
with the kind as tie-break**, never by declaration or import order. Sorting by
kind first would have been the obvious implementation and is wrong for a reason
worth keeping: two producers that discovered the same declarations in different
orders must emit identical bytes, and only an ID-major order makes that
independent of how a producer walks its own tables. The gate reverses the input
records and requires the same bytes.

The eleven record kinds are `0x0101`–`0x010B` exactly as the decision lists
them. Their fields, and the framed SHA-256 preimage of every new v3 identity,
are stated in `model.mjs` rather than in prose here, because a domain written
in two places is a domain that can disagree with itself.

## What the gate proves

**Round trip and closure.** The canonical fixture encodes, decodes, and
re-encodes to the same bytes, and every ID edge closes against the document or
a declared external identity.

**No field is dead.** Forty-one mutations each change one field and require a
semantic digest to move. This is the property a round-trip test cannot reach: a
codec that silently dropped a field would still read back exactly what it
wrote. Each mutation first asserts that it changed the document — a mutation
that matched nothing proves nothing, however confidently it is named.

**Byte-hash sentinel.** The envelope bytes, their length, and both semantic
digests are frozen. Any edit to framing, field order, record sort, or a digest
domain moves them and has to be argued rather than absorbed. The sentinel is
not the only line of defence: with the constants regenerated to match a change,
the property assertions still catch an internal digest that stops covering the
public vector.

**Every refusal produces no artifact.** Unknown kinds and versions, duplicate
and dangling identities, invalid binders, forbidden layout cycles, visibility
leaks, slot/ABI mismatch, limit overflow, truncation, corruption, digest
mismatch, downgrade, replay into a different package graph, and cancellation.
The publication model keeps a store so the gate can assert the *prior* artifact
survived each refusal byte-for-byte, which is what "temporary-plus-atomic-rename
after the full graph validates" means from outside.

## Two rules that needed a case built for them

**The layout cycle.** `GenericTypeDeclaration` first carried its record/ADT
shape as a one-byte kind marker. That passed everything — and made the
cycle rule unreachable, because with no field types there is no by-value edge
between two declarations for a cycle to run through. The shape now carries its
fields and payload types, and the rule refuses two declarations that hold each
other by value.

**The indirection.** A rule that refused every mutual reference would pass the
cycle case just as well, and would reject an ordinary linked list. The gate
therefore also asserts the *accepted* shape: the same two declarations with one
field held behind an explicit indirection encode cleanly.

## Not covered here

The production producer and resolver, backend lowering, source reparse, and
capability promotion are out of scope by the issue. No capability row moves and
no compiler path reads this model.
