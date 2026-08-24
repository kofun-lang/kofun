# Stage 2 pair host-primitives profile v1

Normative schema: `kofun.stage2-pair-host-primitives-v1/v1`.
Decision owner: Issue #1513. Selected: **Option A**, two compiler-private host
primitives. This profile changes no canonical Stage 2 pair byte and advances no
compiler capability or release claim.

## Decision

The C and Kofun halves must eventually make the same host-dependent decisions.
The answer is not to narrow Unicode, emit implementation-defined raw UTF-8 C
identifiers, normalize path text, or record the divergence as permanent.
Instead, the bounded interpreter/driver surface gains exactly:

- `stage2_unicode_scalar_at(validated_text, byte_offset)`, which decodes one
  scalar at a code-point boundary; and
- `stage2_same_file(left, right)`, which establishes output/input identity
  before any destructive output open.

They are compiler-private operations. Ordinary Kofun source cannot resolve,
import, shadow into, serialize, or lower them. User declarations with the same
spelling remain ordinary declarations. The driver is their only authority.

## Unicode scalar operation

Input is already validated UTF-8 `Text` plus a byte offset. The offset must be
at the first byte of a scalar. Success returns one scalar in 0..0x10ffff,
excluding surrogates. End, continuation-byte, malformed, overlong, surrogate,
and out-of-range inputs are distinct typed interpreter failures and publish no
compiler artifact.

`identifier_start_at` uses the returned scalar for XID classification.
`c_identifier_name` uses the same scalar to emit the existing uppercase,
six-hex-digit `_uXXXXXX` spelling. ASCII identifiers keep their bytes. The
primitive does not add a general numeric character API, change `chars()`, or
grant arbitrary byte access; #1499 remains the owner of program-visible byte
reading.

## File identity operation

Exact path-text equality is `Same`. Otherwise the driver resolves both final
objects under its existing host boundary and compares `st_dev` plus `st_ino`
after following the final symlink. An absent output is `Different`. Permission,
I/O, overflow, or any other indeterminate lookup is a typed refusal before the
output is opened. A symlink, hard link, `.`/`..` spelling, or alternate relative
spelling of the input therefore cannot pass as a different output.

Path normalization is not a substitute for object identity. A primitive that
returns `Different` on an indeterminate lookup is also non-conforming: it turns
failure to prove safety into permission to truncate.

## Pair gate and serialization

The future `task stage2-pair-host-primitives` owns two executable comparisons:

- both halves emit byte-identical C for non-ASCII declarations, references,
  parameters, and calls, and removing either half's scalar operation fails; and
- both halves refuse same-text, hard-link, symlink, and normalized aliases
  before changing the input, while a genuinely absent output succeeds.

The gate enumerates the semantic funnels rather than sampling strings. It runs
both halves from one versioned host-operation fixture and verifies lookup-error
precedence. The implementation serializes behind the live canonical-pair owner
on #1483 and updates both compiler halves, pair checksums, bootstrap manifest,
and release evidence together. This decision artifact itself takes no pair
lock because it edits none of those files.

`task stage2-pair-host-primitives-decision` independently mutates visibility,
both operation identities, input/result semantics, driver authority, refusal,
pair gate, serialization owner, and the no-claim boundary.
