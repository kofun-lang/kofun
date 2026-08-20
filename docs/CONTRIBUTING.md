# Contributing

This guide describes how to turn an issue or idea into a reviewable,
evidence-backed Kofun change. It assumes you have completed
[Getting started](GETTING_STARTED.md) and can find the owning subsystem with
the [Repository guide](REPOSITORY_GUIDE.md).

## Contribution principles

Kofun is a research compiler with ambitious design documents and deliberately
narrow executable checkpoints. The most important contributor habit is to keep
those two facts visible at the same time.

- Tie implementation claims to a fixture and an executable gate.
- Preserve explicit “unsupported” outcomes; never silently route around them.
- Keep specifications, compiler behavior, tooling projections, and planning
  records distinct.
- Make results deterministic: source order, diagnostics, artifacts, and tests
  must not depend on host iteration order, wall-clock timing, or an unrecorded
  random seed.
- Keep the repository Python-free and use `.kofun` for Kofun source.
- Treat checked C seeds, generated parsers, digests, goldens, and vendored code
  as reviewed artifacts, not convenient scratch files.
- Make the smallest coherent change that proves the requested behavior.

## Before you write code

### 1. Confirm the current boundary

Read:

1. the row in [Implemented status](MVP_IMPLEMENTED.md);
2. the closest subsystem README;
3. the `Taskfile.yml` task and shell runner that own the claim; and
4. the positive, negative, and unsupported fixtures beside that runner.

Do not infer implementation from syntax in a design document. A focused
frontend helper may accept a construct without ordinary `./bin/kofun build`
support, and a standard-library projection may prove semantics without the full
library API being lowerable.

### 2. Choose independently refinable work

Good starting issues carry both the
[`curated`](https://github.com/kofun-lang/kofun/issues?q=is%3Aopen+label%3Acurated)
and
[`ready`](https://github.com/kofun-lang/kofun/issues?q=is%3Aopen+label%3Aready)
labels. Read the entire issue, linked contract, and recent discussion before
coding. Planning or umbrella issues describe outcomes but may not be an
independently mergeable unit.

[`ISSUE_READINESS.md`](ISSUE_READINESS.md) states what `ready` means, what the
other states mean, and how an issue moves between them. Read it before starting
a `ready` issue — in particular, re-run the commands in its **Current behavior
and evidence** section. `main` moves several times an hour here, and an issue's
stated premise can be stale by the time you pick it up.

[`CONCURRENT_AGENTS.md`](CONCURRENT_AGENTS.md) is the companion contract for
when more than one contributor — human or agent — is working the repository at
the same time. Ownership by resource rather than by issue, one checkout per
session, and one `task verify` at a time are not preferences: five concurrent
sessions produced seven collisions in two days, and six of the seven were caught
only because somebody happened to notice.

If no issue exists, a small documentation correction can be submitted
directly. For changes to language semantics, stable diagnostics, public
artifact schemas, security boundaries, or release behavior, open or agree on
the contract first so the implementation does not accidentally define policy.

### 3. Inspect your working tree

```sh
git status -sb
git diff --stat
```

Create a focused branch from current `main`. If the tree contains changes that
belong to somebody else or another task, leave them untouched and stage
explicit paths only. Never erase unknown work with a broad reset, checkout, or
clean operation.

### 4. Establish the baseline

Run the smallest owner gate before changing anything:

```sh
task stage2
```

Replace `stage2` with the target from the command map below. A passing baseline
separates an existing environment problem from a regression introduced by
your patch.

## Make a compiler change

A complete compiler change normally has four parts:

1. **Contract:** the accepted behavior, error, or explicit unsupported case.
2. **Implementation:** the canonical compiler source and any reviewed artifact
   required by that stage.
3. **Evidence:** focused success, failure, boundary, determinism, and resource
   fixtures.
4. **Explanation:** the subsystem README and implemented-status statement,
   updated only as far as the executable evidence proves.

### Stage 1

`bootstrap/stage1/compiler.kofun` is canonical and `compiler.c` is the trusted
seed. Read `bootstrap/stage1/README.md`, `check.sh`, and `SHA256SUMS` before
editing. The gate must prove both the source/artifact relationship and public
fixture behavior. Never adjust only `SHA256SUMS` to accept unexplained bytes.

Run:

```sh
task bootstrap
task test
```

### Stage 2

Stage 2 has a central compiler plus focused semantic helpers. First determine
whether the requested behavior belongs to:

- ordinary Stage 2 parsing/type checking/C11 lowering;
- a typed-only ADT or generic checkpoint;
- modules/imports/visibility/re-exports;
- KIF or incremental semantic identity;
- semantic events and non-authoritative typed-sidecar projection; or
- a direct backend handled outside Stage 2.

Do not wire a focused helper into the public launcher unless the task explicitly
includes that integration and its unsupported/error routing.

Add the smallest positive fixture, then add or preserve:

- malformed or ill-typed input;
- the closest boundary case;
- a valid-but-unsupported case when lowering remains incomplete;
- exact diagnostic status/channel/artifact behavior; and
- deterministic equality between normal and sanitized artifacts where the
  owner already requires it.

Run the focused target, for example:

```sh
task stage2
task adt
task generics
task imports-qualified
task re-exports
task incremental
```

Then run `task diagnostics` if public rejection behavior changed, and
`task fuzz` if parsing, evaluation order, arithmetic, matches, or backend
observations changed.

### Direct native or wasm32

A backend change must establish more than successful compilation. Check the
normalized exit status, stdout/stderr, binary target, unsupported accounting,
and edge cases shared with the accepted semantic oracle.

Run:

```sh
task native
task wasm
task fuzz
```

Use the narrower target during development, then the relevant combination
before review.

## Change a stable diagnostic

Stable diagnostics are a public compatibility surface. The registry at
`tests/diagnostics/registry.tsv` records the active emitter, phase, public
channel, exit status, span policy, output-artifact policy, and fixture owner.

Before editing, read `tests/diagnostics/README.md`. After editing:

```sh
sh tests/diagnostics/check.sh
sh tests/diagnostics/run.sh
sh tests/diagnostics/self-test.sh
```

Use the bless command only for an intentional message or golden change:

```sh
sh tests/diagnostics/bless.sh
git diff -- tests/diagnostics bootstrap
sh tests/diagnostics/bless.sh
```

The second run must be clean. Review every changed golden and ensure a rejected
source leaves exactly the allowed artifacts. Do not convert an internal crash,
timeout, or malformed adapter response into a normal compiler diagnostic.

## Change a specification or design

For a normative contract under `spec/`:

1. state inputs, outputs, identity, ordering, limits, and failure behavior;
2. include negative examples and versioning/migration impact;
3. add or update the executable `check.sh` where the contract has executable
   examples;
4. update conformance only when an implementation actually accepts the
   behavior; and
5. keep design-only portions explicitly marked as such.

For explanatory material under `docs/`, preserve the status qualifiers and
link to the exact spec or gate. A design document may be complete without
claiming its full implementation is complete.

## Change the standard library or a framework

Start with the root `stdlib/README.md` or the relevant framework README. Many
modules contain an intended Kofun API plus a smaller executable projection
through backends available today.

A coherent change keeps these aligned:

- canonical `.kofun` API/contract source;
- platform or trusted-intrinsic boundary;
- projection or runtime adapter, if still required;
- deterministic fixtures and expected output;
- module README boundary statement; and
- root status claims.

Run the smallest module gate, then the aggregate:

```sh
sh stdlib/<module>/tests/verify.sh
task stdlib
```

For frameworks:

```sh
task http
task cli-framework
task tui-framework
```

If foreign C or Rust code is involved, also review the security, ABI,
ownership, vendoring, and offline-build documentation. Do not imply Kofun
memory-safety guarantees cover trusted native dependencies.

## Change editor or tooling behavior

### Language server

The LSP is a dependency-free stdio server with explicit document, position,
size, and latency boundaries. Change `tooling/lsp/` and its `tests/lsp/`
evidence together. Keep the VS Code-bundled entrypoint synchronized when the
packaged server changes.

```sh
task lsp
```

### Tree-sitter

The grammar is [`kofun-lang/tree-sitter-kofun`](https://github.com/kofun-lang/tree-sitter-kofun)
and is gated there. A syntax change that reaches the compiler usually needs a
matching change in that repository; nothing here builds or tests it, and no
npm project remains in this repository.

### Typed sidecar

The typed sidecar is non-authoritative tooling output with schema, canonical
encoding, atomic replacement, status/disclosure, and producer-race rules.
Changing it can require synchronized edits under `spec/typed-sidecar/`,
`spec/tooling/`, `tooling/typed-sidecar/`, `bootstrap/stage2/`, and
`tests/typed-sidecar/`.

```sh
task typed-sidecar-spec
task typed-sidecar-codec
task typed-sidecar-projector
```

Never turn the sidecar into compiler input, cache authority, or a substitute
for committed compiler/KIF facts.

## Change documentation or the site

### Authoritative source

Edit Markdown in `docs/` or the selected subsystem README. The website reads
that source at build time; do not copy it into a React component.

Adding a first-class docs page is a two-repository change. Add the Markdown
source here, then add one entry to `app/docs/docs-manifest.ts` in
[`kofun-lang/kofun-site`](https://github.com/kofun-lang/kofun-site), choosing the
correct navigation section and linking it from an existing starting point when
it changes the reading path. That repository's `site/README.md` documents the
manifest, the link test, and the layout checks.

The same boundary applies to moving or renaming an already rendered document:
the site names sources by path, so a rename here breaks the site until its
manifest follows.

Relative links in a curated Markdown source are rewritten to another rendered
docs route when that source is in the manifest. Other files link to their
GitHub source. Keep links relative so both repository readers and the site can
use them.

### Browser tour

Edit `docs/tour/`. It is compiler source, not site material:
`docs/tour/compiler.mjs` is a browser port of `bootstrap/wasm/compiler.c`, and
`task tour` proves the two still agree byte for byte. Run it after any change
there. The site copies the directory at build time and owns no part of it.

## Test the smallest relevant surface

| Change area | Fast feedback | Required broader gate before review |
|---|---|---|
| launcher/public CLI | `task test` | `task verify` |
| Stage 1 seed | `task bootstrap` | `task test`, then `task verify` |
| Stage 2 core | `task stage2` | `task diagnostics`, relevant fuzz, then `task verify` |
| ADT/generics/patterns/modules | matching task target | `task stage2`, `task diagnostics`, then `task verify` |
| native backend | `task native` | relevant conformance/fuzz, then `task verify` |
| wasm32 backend | `task wasm` | relevant conformance/fuzz, then `task verify` |
| diagnostics | `task diagnostics` | owner gate, then `task verify` |
| fuzz protocol/generator | focused `tests/fuzz/*.sh` | `task fuzz`, then `task verify` |
| Unicode | `task unicode` | affected compiler/tooling gates, then `task verify` |
| standard library | module `tests/verify.sh` | `task stdlib`, then `task verify` |
| HTTP/CLI/TUI | matching framework target | `task verify` |
| LSP | `task lsp` | `task verify` |
| the browser tour | `task tour` | `task verify` |
| docs Markdown | the `spec/*/check.sh` reading it, if any | `task verify`, plus `npm run test:docs` in `kofun-lang/kofun-site` when the site renders it |

The final full suite is not a substitute for the focused test. The narrow gate
produces readable evidence for the changed contract; the full gate detects
cross-component regressions.

## Repository conventions

### Shell

- Use POSIX `sh` for checked repository scripts unless a subsystem explicitly
  requires another shell.
- Start failure-sensitive scripts with `set -eu`.
- Quote paths and values.
- Use deterministic locale/order where bytewise output is a contract.
- Create temporary work under the gate's controlled build directory and clean
  it with traps.
- Validate unsupported hosts and missing tools explicitly.

`task verify` applies `sh -n` to the checked shell inventory. Add new public
scripts to that inventory when they become part of the repository gate.

### C

- Use the standard and warnings selected by the owning check, commonly
  `-std=c11 -Wall -Wextra -Werror`.
- Keep input/resource limits explicit and test the boundary.
- Avoid undefined behavior, host-width assumptions, and unspecified evaluation
  order.
- A sanitized helper must agree with the normal helper on committed artifacts.
- Emit output transactionally: rejected input must not leave a plausible
  success artifact.

### Kofun source

- Use `.kofun`, never the historical `.kf` extension.
- Do not add a Python implementation or build dependency.
- Follow the currently accepted syntax for the target stage, not only the full
  grammar draft.
- Keep trusted intrinsics and foreign-code boundaries explicit.

### Generated and committed files

- `build/` and `.kofun/` are disposable ignored output.
- Tree-sitter generated parser files are committed and must be regenerated from
  `grammar.js`.
- Bootstrap C seeds and checksum manifests are committed, hash-pinned artifacts;
  follow their stage-specific reproduction/check procedure.
- Diagnostic goldens and expected stdout/stderr are public test evidence; use
  the owning bless procedure and inspect the diff.
- Vendored source requires provenance, license, integrity, and offline-build
  review.

## Review your patch

Before committing:

```sh
git diff --check
git status --short
git diff --stat
git diff
```

Check that:

- only intended source, fixture, artifact, and documentation files changed;
- no ignored build output was force-added;
- success, failure, unsupported, and boundary cases are distinguishable;
- public messages, statuses, streams, spans, and artifacts match the contract;
- docs say exactly what the executable gate proves;
- a clean rerun is deterministic; and
- the focused and broader relevant gates pass.

Stage explicit paths:

```sh
git add path/to/source path/to/test path/to/doc
git diff --cached
```

Write a terse commit subject that names the subsystem and outcome. Keep
unrelated formatting, generated snapshots, and opportunistic cleanup out of
the commit.

## Pull request expectations

A reviewable pull request explains:

- what behavior or documentation changed;
- why the previous behavior or guidance was insufficient;
- the current implementation boundary after the change;
- the success, failure, unsupported, and resource cases added or preserved;
- exact commands used for verification; and
- compatibility, migration, security, generated-artifact, or release-note
  impact, including “none” when appropriate.

Do not describe a helper checkpoint as general compiler support. Link the
exact issue and contract, not only an umbrella roadmap.

## Definition of done

A contribution is complete when:

- the correct canonical source owns the behavior;
- the smallest regression test fails without the change and passes with it;
- negative and explicit unsupported behavior remain honest;
- generated or committed artifacts were updated through their documented flow;
- the implemented-status and subsystem docs match the evidence;
- focused and relevant aggregate gates pass;
- `git diff --check` is clean;
- the patch contains no unrelated working-tree changes; and
- reviewers can reproduce the result from the commands in the pull request.

If you are unsure which source or gate is authoritative, stop and trace the
path from `Taskfile.yml` to the runner and nearest README. That short investigation
is part of the implementation, not overhead.
