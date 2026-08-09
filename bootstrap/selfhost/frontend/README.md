# Self-host frontend evidence

This directory holds the executable evidence that the Stage 2 frontend can
parse, resolve, and type the frozen self-host source `S`
(`bootstrap/stage1/compiler.kofun`) into one complete
`kofun.selfhost-hir/v1` document, per the contract frozen in
`bootstrap/selfhost/hir-v1.md`.

- `S.hir` — the complete typed document for the exact frozen `S` digest:
  deduplicated type table, scope tree, symbols (functions, the 16 profile
  builtins plus the `len` List[Text] overload, parameters, locals),
  bindings, and per-function pre-order node records with types, ownership
  modes, and exact byte spans.
- `accept_*.kofun` / `accept_*.hir` — positive fixtures: one accepted,
  byte-stable typed document per profile row family (literals,
  expressions, control flow, statements, all 16 builtins including the
  Unicode ones, host access, and declaration syntax). Each row's frontend
  cell in `profile.tsv` names the fixture document that evidences it.
- `differential_core.kofun` / `.hir` / `.status` — the execution
  differential: the typed document's node records are evaluated directly
  and must reproduce the exit status of the same source compiled through
  the deterministic C11 path, pinned in `differential_core.status`. The
  backend consumes exactly these records, so the typing claims meet an
  independent execution instead of being asserted.
- `reject_*.kofun` / `reject_*.hir` — compile-fail fixtures: each produces
  exit 1 and its exact rejected document (stable diagnostic code, span, and
  message; never a partial typed document; the out-of-profile `match`,
  `break`, and `|>` fixtures additionally carry explicit `unsupported`
  records proving full-language syntax is rejected without fallback).
- `check-frontend.sh` — the gate: rebuilds the Stage 2 seed, re-derives the
  profile digest, re-emits and byte-compares every document, checks
  determinism across repeated runs, cross-checks every accepted document's
  bindings against the independent scope-HIR inference, and runs the
  execution differential. Run it with `task selfhost-profile` or directly.

## Canonical source and seed

The emitter lives in both halves of the Stage 2 lockstep pair: the
canonical Kofun source (`bootstrap/stage2/compiler.kofun`, the
`selfhost_*` functions and the `--emit-selfhost-hir` entry) and the
C seed (`bootstrap/stage2/compiler.c`), with both digests pinned
together in `bootstrap/stage2/SHA256SUMS`. The canonical port mirrors the
seed record for record: the same parse order, the same diagnostic codes,
spans, and message bytes, and the same pre-order renumbering, so the seed
remains the executable stand-in until the self-compile chain (#620–#622)
can run the canonical source itself. This closed the #654 boundary that
previously kept the `profile.tsv` frontend cells at `planned:#619`;
`task selfhost-frontend` is green and is the #619 completion check.
