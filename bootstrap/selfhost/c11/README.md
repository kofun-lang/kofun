# Self-host C11 slice evidence

This directory holds the executable evidence for #620 and #621: the
Text/function slice and the mutation/loop/List[Text] slice of the frozen
self-host profile lower from `kofun.selfhost-hir/v1` documents
(`bootstrap/selfhost/hir-v1.md`) to deterministic standalone C11. The
lowering consumes only document records — nodes, symbols, bindings,
scopes, and the closed type table — and never reparses source text or
infers semantics from spelling.

- `accept_*.kofun` / `.hir` / `.c` / `.status` — positive fixtures: each
  source emits its typed document, the document lowers to the checked-in
  C byte for byte (twice, for determinism), and the compiled program
  reproduces the pinned exit status with empty stdout. `accept_unicode`
  runs the three Unicode builtins over Japanese and Hangul text and
  distinguishes the real Unicode 17 `XID_Continue` tables from any
  byte-range approximation; `accept_limits` pins the clamping and
  boundary semantics of `text_slice`, `replace`, `find`, `trim`,
  `is_digit`, and `is_space`.
- `accept_mutation`, `accept_loops`, `accept_lists` — the #621 slice:
  mutable locals and assignment, `while` (lowered as a re-evaluating
  `for (;;)`/`break` shape), `for` over `Int .. Int` with bounds
  evaluated once and an exclusive end (empty, exact-limit, and one-past
  ranges are pinned), and `chars`/`len`/indexing over `List[Text]` with
  the per-byte element semantics of the trusted seed, exercised over
  multibyte text.
- `trap_division.kofun` / `.stderr` — the explicit failure path: checked
  arithmetic reports `error[R010]` on stderr once and the program exits 1
  through every intervening call frame. `trap_list_index` pins the
  bounds-checked `List[Text]` indexing panic the same way.
- `reject_missing_return.kofun` / `.hir` — a complete typed document
  whose non-`Void` function can finish without returning is invalid
  (exit 1, `E2S19`); the gate also drives documents using the #622 host
  builtins through the lowering and requires the distinct `E2S10`
  unsupported classification (exit 3), never emitting partial C either
  way.
- `check-c11.sh` — the gate; run it with `task selfhost-profile` or
  directly. `sh bootstrap/selfhost/check-profile.sh --phase c11-text`
  (`task selfhost-c11`) and `--phase c11-control`
  (`task selfhost-c11-control`) are the completion checks for the
  profile rows whose `c11` cells the two slices own; the gate also
  closes the execution differential over three independent paths (typed
  node-record evaluation, the Int-core `--compile-outcome` lowering, and
  this document-driven lowering all reproduce
  `differential_core.status`).

## Runtime shim

Generated programs embed one C runtime: the checked Int
arithmetic helpers of the existing Core slice plus `kofun_rt_*` text
helpers whose observable semantics match the trusted Stage 1 seed
prelude byte for byte — byte-counted `len`, byte-offset `text_slice`
with clamping, ASCII `trim`/`is_digit`/`is_space`, literal
non-overlapping `replace`, `strstr`-based `find`/`contains`. The
Unicode builtins consult the repository's Unicode 17 tables: generated C
is compiled with `-I unicode` and includes `kofun_unicode.c`, exactly
like the Stage 2 seed's own lexer; `is_xid_continue` decodes the first
scalar (false on empty or invalid input) and `validate_unicode_source`
returns empty text or the seed's formatted `EUNICODE` message.
Allocations follow one documented process-lifetime rule: nothing is
freed, and exhaustion panics explicitly through `kofun_rt_panic`.

Every expression node lowers post-order to one temporary named after its
document node id, so argument evaluation is exactly once and left to
right, and `&&`/`||` keep short-circuit evaluation through guarded
blocks.

## Canonical source and seed

The lowering lives in both halves of the Stage 2 lockstep pair — the
`selfhost_c11_*` functions in `bootstrap/stage2/compiler.kofun` and the
`sl_*` section of `bootstrap/stage2/compiler.c`, invoked as
`kofun-stage2 --lower-selfhost-c11 INPUT.hir OUTPUT.c` — with both
digests pinned together in `bootstrap/stage2/SHA256SUMS`. The seed
remains the executable stand-in until the self-compile chain (#621/#622)
can run the canonical source itself; the canonical port mirrors the seed
record for record, and the seed additionally bounds documents (16384
records, 16 fields, 64 types) that the canonical Text scans leave
unbounded.
