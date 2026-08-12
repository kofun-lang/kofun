# SHA-256 in Kofun

RFC-0013 step 2 (#1352): the repository's hash function, written in the language
whose identities it computes.

```sh
task kofun-digest-model
```

Every digest that anchors this project — `bootstrap/stage2/SHA256SUMS`,
`bootstrap/manifest.json`, the release evidence, and every compiler identity
(ModuleId, FileId, SymbolId, and scope-HIR v2's ParId/TaskId/JoinId) — is a
SHA-256 preimage. Until RFC-0013 gave `Int` its eight bit operations, the
language could not spell a rotation, so that hash had to be C. This is the
Kofun one. It does **not** replace `bin/kofun-digest`, assign compiler
identities, or claim a capability; those are downstream and separately
authorized.

## What makes it trustworthy

- **The four published FIPS 180-4 vectors are asserted verbatim** — empty,
  `abc`, the 448-bit message, and the 896-bit message. The anchor is the
  standard, not agreement between two implementations that live in one
  repository.
- **Every corpus message is digested by `bootstrap/stage2/sha256.c`** through
  `bin/kofun-digest` and must match byte for byte. The C implementation stays
  the oracle.
- **`corpus.json` is the single source of the message bytes.** `corpus.mjs`
  writes them out for the C oracle *and* checks that the literals inside
  `sha256.kofun` are those same bytes, so the two sides cannot drift while both
  stay green. It computes no digest itself — a JavaScript SHA-256 here would be
  a third implementation agreeing with itself.
- **Three mutations must fail**: one round constant off by one, one rotation
  amount off by one, and a length field in bytes instead of bits. A wrong
  digest is stable, self-consistent, and completely useless, so a gate that
  cannot tell right from wrong proves nothing.

## Two shapes that are the lowering's, not SHA-256's

**Input is `List[Int]` of bytes, never `Text`.** `chars` and `find` are frontend
builtins the C11 Core refuses (`E2S10`), so there is no way to obtain a byte
from a `Text` in a program this backend compiles. Taking bytes is the honest
interface rather than a convenience.

**A message is two lists.** A `List[Int]` holds exactly 64 elements, and the
896-bit vector is 112 bytes, so a message is a first list and a second, with
`second` empty whenever it fits in one. The 65-byte boundary is in the corpus
precisely because it is the first length that cannot fit one list — it
exercises that path rather than only the padding arithmetic.

The 64-element limit is otherwise a coincidence that fits: a SHA-256 block is 64
bytes, the round constants are 64 words, and the message schedule is 64 words.
