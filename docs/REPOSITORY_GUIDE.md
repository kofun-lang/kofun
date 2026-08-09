# Repository guide

This guide is the map from a development task to the files and verification
gates that own it. Read it after [Getting started](GETTING_STARTED.md) and keep
it open during your first changes.

## The five ideas that make the repository understandable

1. **The repository is the toolchain.** `./bin/kofun` builds checked local
   compiler artifacts on demand; `build/` is disposable output.
2. **Kofun has multiple bounded compiler paths.** Stage 1, Stage 2, direct
   native, wasm32, C ABI, and framework paths do not expose one identical
   language surface.
3. **Executable evidence is the implementation boundary.** A design document
   or open issue is not an implementation claim. Active claims name a fixture
   and gate.
4. **Canonical sources and checked artifacts can coexist.** For example,
   Kofun-authored compiler source and an audited C seed are both committed.
   The nearest README and `check.sh` define their relationship.
5. **Specifications, implementation, and explanation are separate.**
   `spec/` defines normative contracts, implementation lives primarily under
   `bootstrap/`, and `docs/` explains design and project state.

## Request flow: from command to evidence

```text
./bin/kofun
    |
    +-- check/run/build (host C path)
    |      +-- Stage 2 bounded C11 Core
    |      `-- explicit Stage 1 compatibility path for unsupported lowering
    |
    +-- build --target x86_64-linux|aarch64-linux
    |      `-- direct native ELF64 compilers
    |
    +-- build --target wasm32
    |      `-- direct wasm32 arithmetic Core
    |
    +-- build --backend c --c-abi
    |      `-- explicit foreign-code and host-linker boundary
    |
    +-- build --framework cli
    |      `-- declarative native CLI compiler/runtime
    |
    `-- package / project build
           +-- locked external native artifacts
           `-- optional Frost project engine

Each path -> focused check.sh or test runner -> Taskfile target -> task verify
```

The launcher source is readable shell. When command routing is surprising,
start at [`bin/kofun`](../bin/kofun), find the public subcommand, and follow the
`ensure_*_compiler` or build function it invokes.

## Top-level directory map

| Path | What it owns | Start here | Typical gate |
|---|---|---|---|
| `bin/` | repository-local public launcher | `bin/kofun` | `task test` |
| `bootstrap/` | compiler seeds, frontends, direct backends, self-host evidence | `bootstrap/README.md` | `task bootstrap`, `task stage2`, `task native` |
| `spec/` | normative language and tooling contracts plus executable examples | `spec/README.md` | the matching `task *-spec` target |
| `tests/` | public behavior, conformance, diagnostics, fuzzing, tooling, integration | nearest runner or README | `task test`, `task diagnostics`, `task fuzz` |
| `stdlib/` | Kofun-authored standard-library contracts and focused projections | `stdlib/README.md` | `task stdlib` |
| `framework/` | bounded HTTP, CLI, and terminal UI surfaces | subsystem README | `task http`, `task cli-framework`, `task tui-framework` |
| `tooling/` | language server, typed-sidecar codec/projector, and disclosure-safe documentation index | subsystem README and [`docs/DOCUMENTATION_INDEX.md`](DOCUMENTATION_INDEX.md) | `task lsp`, `task typed-sidecar-codec`, `task documentation-index` |
| `unicode/` | Unicode tables, generator, provenance, and C boundary | `unicode/README.md` | `task unicode` |
| `vendor/` | reviewed third-party source copied into the tree | `vendor/*/README.kofun.md` | integrity owner named by subsystem |
| `package/` | locked external native-artifact package manager | `package/README.md` | `task packages` |
| `examples/` | user-facing and interoperability examples | example plus its nearest check | relevant build or `check.sh` |
| `docs/` | authored guides, designs, status, and browser-tour source | this guide | `task tour` for `docs/tour/`; `spec/*/check.sh` for the gated documents |
| `artifacts/` | checked evidence summaries and cost/law artifacts | inspect producer named in the artifact | producer-specific gate |
| `scripts/` | repository policy verification written in Kofun; **currently inert**, see below | script source | none — no task invokes it |
| `.github/workflows/` | CI | workflow YAML | GitHub Actions |

`scripts/verify_repository.kofun` deserves a warning rather than a row. It is
written in Kofun against `read_text`, which the current Core does not implement
(`error[E2S10]: unsupported Core builtin call 'read_text'`, reproducible with a
one-line `main`). No task invokes it, so nothing reported the breakage, and its
assertions went stale unnoticed twice: first a deleted `Makefile` and a README
string the README no longer carries, then three `editor/vscode/` paths that
outlived the move to `kofun-lang/kofun-vscode`.

`repository-check` now holds the file list to the tree: every path the script
names must exist here and be non-empty. That is the half of it a gate can check
without `read_text` — the string assertions and the JSON validation still
cannot run, and still rot silently. Treat the script as an aspiration rather
than a gate until the Core supports reading files, at which point it should
move into `verify` whole.

`repository-check` holds two more things of the same shape — something that was
true once, with nothing keeping it true. Every task that runs a check script
must be named in the list `verify` invokes: `tests/stdlib/tzdb/check.sh` was
defined as a task, never enrolled, and never ran for the whole of #888, while
`release/claims.json` pointed at it as the evidence for a published claim. And
the editor and grammar surfaces that moved to their own repositories in #861
must stay gone: #872, a pull request about examples, re-added three build
outputs under `editor/vscode/server/generated/`, one of them an x86-64 shared
object, because the path was not ignored and a `git add -A` swept them in.

What is deliberately not here, and where it lives instead:

| what | repository |
|---|---|
| official site, docs renderer, browser playground, delivery-planning snapshots, long-range issue catalogue | [`kofun-lang/kofun-site`](https://github.com/kofun-lang/kofun-site) |
| VS Code extension: metadata, TextMate highlighting, snippets, packaging | [`kofun-lang/kofun-vscode`](https://github.com/kofun-lang/kofun-vscode) |
| Tree-sitter grammar, editor queries, recovery corpus | [`kofun-lang/tree-sitter-kofun`](https://github.com/kofun-lang/tree-sitter-kofun) |
| benchmark programs, harnesses, and recorded results | [`kofun-lang/kofun-benchmarks`](https://github.com/kofun-lang/kofun-benchmarks) |

Each reads this repository, never the other way. No gate here reads anything
from them, and `task verify` needs no npm, Next.js, or Cloudflare toolchain —
which became true when the grammar left, because it was the last npm project
here and `task tree-sitter` ran `npm ci` inside `verify`.

The language server is the case that decides where a tool belongs. It stays in
`tooling/lsp/` because `tests/lsp/check.sh` requires the bundle it ships to
equal `tooling/typed-sidecar/{from-stage2,codec}.mjs` byte for byte; a
repository that does not own those files cannot prove it. The extension that
packages the server has no such coupling, so it left. `docs/tour/` is the exception that proves the
rule: it looks like site material but `docs/tour/compiler.mjs` is a browser port
of `bootstrap/wasm/compiler.c` that `task tour` pins to the native wasm32 output
byte for byte, so it is compiler source and stays here.

Root files are also part of the architecture:

| File | Purpose |
|---|---|
| `Taskfile.yml` | executable gates and the grouped bare-`task` contributor guide |
| `README.md` | concise public project entrypoint |
| `DESIGN.md` | early high-level language design context |
| `LICENSE-*` / `NOTICE` | dual-license and attribution terms |

## `bootstrap/`: the compiler is several checkpoints

### `bootstrap/stage1/`

Stage 1 is the Python-free bootstrap seed.

- `compiler.kofun` is the canonical Kofun source.
- `compiler.c` is the checked-in audited C11 seed.
- `SHA256SUMS` pins the source/artifact relationship.
- `check.sh` builds the seed and verifies its bounded nested-block
  Int/Bool/Text/List[Text] Core.

Do not edit only a digest to make a gate pass. A Stage 1 change must explain
which source is canonical, how the audited artifact was produced, and why its
fixtures still establish the claimed behavior.

### `bootstrap/stage2/`

Stage 2 contains the broadest collection of semantic frontend checkpoints:

- canonical `compiler.kofun` plus audited `compiler.c`;
- the transactional lexer/parser, scopes, typing slices, diagnostics, and
  bounded C11 lowering;
- focused ADT, generic, module, import, visibility, re-export, KIF, and
  incremental helpers;
- semantic-event producer and typed-tooling boundary;
- fixtures, exact stdout/stderr, and `SHA256SUMS`;
- `check.sh`, which compiles and compares the expected artifacts; and
- `build.sh`, sourced rather than run, which is the single definition of how a
  Stage 2 compiler binary is produced for a gate that needs one.

**No focused feature frontend is routed through ordinary `./bin/kofun`
commands.** Measured on `de4ffaa2`, none of `adt_frontend.c`,
`const_generics_frontend.c`, `generics_frontend.c`, `hm_levels_frontend.c`,
`optional_frontend.c`, `record_frontend.c`, `traits_frontend.c`,
`module_symbols.c`, or `re_exports.c` is included by `compiler.c`; each is built
and run only by its own gate. So a file named for a feature is evidence that a
bounded claim about it is checked, not that the feature compiles:
`generics_frontend.c` is 59 KB with a passing `task generics`, while
`./bin/kofun check` on `fn identity[T](value: T) -> T` reports
`error[E2S03]: malformed function at byte 0`.

The two files that *are* the user-facing compiler are `compiler.kofun`
(canonical) and `compiler.c` (the audited seed that executes). See
[`docs/COMPILER_ARCHITECTURE.md`](COMPILER_ARCHITECTURE.md#where-the-compiler-actually-is).

The detailed [`bootstrap/stage2/README.md`](../bootstrap/stage2/README.md)
states whether a capability is user-facing, typed-only, reference lowering, or
tooling projection. Preserve those qualifiers in code, tests, docs, and release
notes.

### `bootstrap/native/`

This owns direct static ELF64 output for x86-64 and AArch64 bounded profiles.
It includes Kofun encoder sources, checked C compiler artifacts, fixture
emitters, and binary/runtime checks. Start with
[`bootstrap/native/README.md`](../bootstrap/native/README.md) and
[Native backends](NATIVE_BACKEND.md).

### `bootstrap/wasm/`

This owns direct wasm32 output and the Node runner for the checked arithmetic
Core. The browser example under `examples/wasm-browser/` consumes that output
but is a separate integration surface.

### `bootstrap/c_abi/`

This is the explicit host-C, libc, archive, and dynamic-linker boundary. It is
intentionally separate from direct static native output. Read its security and
ownership limitations before adding an external library path.

### `bootstrap/selfhost/`

This contains the frozen source profile, frontend and C11 evidence, driver,
native corpus, and fixed-point checks for compiler-produced compiler artifacts.
“Compiler source is written in Kofun” and “semantic self-hosting fixed point”
are different claims. The latter remains governed by the explicit generation
and artifact-equivalence gates in the self-host documentation.

### `bootstrap/fixtures/`

Small canonical inputs used across launcher and compiler smoke tests live here.
Prefer the nearest specialized corpus for a feature regression; keep these
fixtures minimal because many unrelated gates depend on them.

## `spec/`, `docs/`, and executable status

These directories answer different questions:

| Source | Question it answers | Authority |
|---|---|---|
| `spec/` | “What is the accepted normative contract?” | normative draft plus named executable examples |
| `docs/MVP_IMPLEMENTED.md` | “What can the checked repository execute now?” | concise status matrix tied to gates |
| other `docs/*.md` | “Why is this designed this way, and how do I use or develop it?” | explanatory; may include planned behavior |
| issues and `docs/ROADMAP.md` | “What outcome is planned next?” | planning only |

When you implement a feature described in `docs/`, do not simply remove every
future-tense qualifier. First add the executable evidence, then update the
implemented-status row and the relevant design text to name the exact boundary.

The typed-sidecar documentation projection is documented separately in
[`docs/DOCUMENTATION_INDEX.md`](DOCUMENTATION_INDEX.md). Start there before
adding a renderer or search consumer: public and package-internal views have
different disclosure authority, and partial/stale output is never a complete
current index.

### What stays in `docs/`, and why

`docs/` looks like the obvious third thing to move out after the site and the
backlog. It mostly is not, and the rule is worth stating so the question is
settled with evidence rather than re-asked every time the repository feels
large.

**A document stays when this repository resolves it.** Four resolvers count, and
each one fails a gate when the document it names goes missing or drifts:

| Resolver | What it names | Gate |
|---|---|---|
| `release/claims.json` | `docs/MVP_IMPLEMENTED.md` as the sole `public_sources` entry, fifteen documents as `specification`, and three documents as `threat_model` | `task release-claims` |
| `rfcs/index.json` | `docs/DESIGN_DECISIONS.md` as a decision `source`, and twelve documents as `normative_spec` | `task rfc-registry` |
| `artifacts/release-evidence/index.json` | a SHA-256 of each of sixteen documents under `evidence_digests` | `task release-claims`, regenerated by `task release-evidence` |
| a gate script | `spec/*/check.sh`, `tests/**/run.sh`, `bootstrap/*/check.sh` and `docs/tour/check.sh` read documents directly | the owning `task` target |

Measured on this tree, of the thirty-three tracked `.md` files under `docs/`:

- **thirty-one are resolved by one of the four.** Moving any of them would not
  lose prose, it would break a gate.
- **one is resolved only by `app/docs/docs-manifest.ts`** in
  [`kofun-lang/kofun-site`](https://github.com/kofun-lang/kofun-site), which renders
  `CONTRIBUTING.md` out of the submodule. It stays because it describes this
  source tree and its contribution gates.
- **three public project documents moved to `kofun-site`:** language vision,
  RFC process, and release-evidence guidance. They name compiler evidence by
  absolute link, while the executable sources remain here.
- **one is resolved by nothing:** `docs/tour/README.md`, kept because it
  documents `docs/tour/`, every other file of which stays.

Reproduce the split:

```sh
git ls-files docs | grep '\.md$'
git grep -oh -E 'docs/[A-Za-z0-9_./-]+\.md' -- \
    '*.sh' Taskfile.yml '*.mjs' '*.ts' '*.c' '*.kofun' '*.json'
```

**That grep under-reports, and the gap is load-bearing.** It matches literal
paths, and `docs/tour/check.sh` builds its path from a loop variable:

```sh
for language in python typescript go rust
do
    test -s "$ROOT/docs/tour/guides/$language.md"
    grep -Fq 'Where Kofun is worse today' \
        "$ROOT/docs/tour/guides/$language.md"
done
```

So the four `docs/tour/guides/*.md` files read as free and are not: `task tour`
asserts each is non-empty and still contains that heading. Before moving a
document out on the strength of a grep, check that no gate constructs its path.

Four documents did leave, into `kofun-lang/kofun-site`. No resolver named them,
and none of them was rendered by the site at the time it took them. Where they
sit now has since diverged, so the destination is worth naming per document:

| Document | Where it is now | Why it left |
|---|---|---|
| `ISSUE_TRIAGE.md` | `content/ISSUE_TRIAGE.md`, still unrendered internal policy | issue-workflow policy, cited from issues by URL; no gate reads it |
| `ONE_DAY_TUTORIAL.md` | `content/docs/`, since promoted to a rendered page | narrative walkthrough |
| `SCIENTIFIC_COMPUTING.md` | `content/docs/`, since promoted to a rendered page | long-range design with no implementation to gate |
| `CODING_INTERVIEW.md` | removed outright; neither repository carries it | narrative comparison |

That is about 30 KB, 0.3% of tracked bytes — which is the finding, not a
disappointment. The size was never in `docs/`; it was in the site and the
backlog, and both are gone.

## `tests/`: choose the corpus that matches the contract

### Public CLI and integration

Top-level shell runners such as `tests/cli.sh`, `tests/build_system.sh`, and
`tests/package_manager.sh` exercise public commands and cross-component
behavior. Use them when changing `bin/kofun`, routing, artifact handling, or
exit statuses.

### Conformance

`tests/conformance/` groups accepted semantics by capability:

- backend adapters and normalized cases;
- functions, numeric operations, Lists, and Text;
- modules, imports, visibility, and re-exports;
- ADTs, patterns, generics, and incremental behavior; and
- syntax milestone corpora.

Conformance should observe language behavior, not internal implementation
details, unless the contract is specifically an artifact schema.

### Diagnostics

`tests/diagnostics/registry.tsv` is the canonical active diagnostic registry.
Family runners own status, stdout/stderr channel, spans, artifact policy, and
exact fixtures. Read `tests/diagnostics/README.md` before changing a public
diagnostic or using the bless workflow.

### Fuzzing

`tests/fuzz/` contains deterministic bounded generators and independent
semantic oracles. It is CI evidence, not an invitation to accept flaky random
output. A failure must retain enough seed, source, tool identity, and raw
observation data to replay exactly.

### Tooling and Unicode

`tests/lsp/`, `tests/typed-sidecar/`, and `tests/unicode/` own their respective
protocol, authority, replacement, position-encoding, security, and data
integrity boundaries.

### How a gate reports a failure

`tests/assertions/assert.sh` is sourced, never run, and holds the assertion
helpers a gate should use — `assert_eq`, `assert_num`, `assert_file_empty`,
`assert_absent`, and the rest. Each takes a label first and prints one line
naming the label, the expectation, and the observation.

They exist because every gate runs under `set -eu`, where a bare
`test "$a" = "$b"` that fails exits the script and prints **nothing**. #794
records that costing real time — the native gate's digest check failing with an
empty stderr — and #814 sized the problem at 459 assertions in that shape.

`tests/assertions/check.sh` (`task assertions`) counts them and holds every
script to the budget recorded in `tests/assertions/budget.tsv`. It fails in
both directions: over budget is a regression, and under budget means a fix was
made without lowering the budget to record it.

## Standard library and frameworks

Many `stdlib/` modules specify the intended Kofun API while their current gate
executes a smaller honest projection through available backends. Read each
module README before claiming its full ADT or runtime surface is connected to
ordinary Stage 2 code generation.

The same discipline applies to frameworks:

- `framework/http/` owns the bounded HTTP/API surface and C runtime adapter;
- `framework/cli/` owns declarative CLI source, native compiler, runtime
  template, tutorial, and security boundary; and
- `framework/tui/` owns the shared terminal UI C library and behavior tests.

Examples show how to use these surfaces; their subsystem gates establish what
is currently supported.

## Editor and tooling paths

One developer-tool surface lives here, and two do not:

1. `tooling/lsp/` is the dependency-free stdio language server, and it stays
   because it is byte-coupled to this repository: `tests/lsp/check.sh` requires
   the bundle it ships to equal `tooling/typed-sidecar/{from-stage2,codec}.mjs`
   exactly, and only this repository can prove that.
2. The VS Code extension — metadata, TextMate highlighting, snippets,
   packaging — is
   [`kofun-lang/kofun-vscode`](https://github.com/kofun-lang/kofun-vscode).
3. The structural grammar and editor queries are
   [`kofun-lang/tree-sitter-kofun`](https://github.com/kofun-lang/tree-sitter-kofun).

Changing syntax can require updates in all three, and they do not share one
parser or one semantic authority. `task lsp` covers the part that lives here;
the other two are gated in their own repositories.

## Official site and documentation pipeline

The official site has a deliberately simple authority chain, and it crosses a
repository boundary exactly once:

```text
docs/*.md or selected subsystem README      (this repository)
            |
            v  checked out at the CI-verified main commit
app/docs/docs-manifest.ts                   (hjosugi/kofun-site)
            |
            v
app/docs/[slug]/page.tsx + ReactMarkdown
            |
            v
Pages workflow + Next.js static export      (this repository)
            |
            v
GitHub Pages, still served at kofun-lang.github.io/kofun/
```

The renderer and its tests live in
[`kofun-lang/kofun-site`](https://github.com/kofun-lang/kofun-site) and are documented
in that repository's `site/README.md`. This repository's
`.github/workflows/pages.yml` pins a reviewed renderer commit, checks out the
exact Kofun commit whose main CI passed, refreshes the public tracker snapshots,
and deploys the verified static artifact directly with GitHub Pages Actions. No
generated publication branch is part of that authority chain. The deployed
artifact records both revisions in `.kofun-source-commit` and
`.kofun-site-commit` for production read-back.

What this repository owes the renderer is this: the documents named in the
site's manifest must keep existing at their current paths, and their relative
links must keep resolving. Moving or renaming a document under `docs/` is
therefore a cross-repository change.

Generated directories are ignored:

- `node_modules/` — nothing in this repository declares npm dependencies any
  more; the entry stays so a stray install cannot be committed; and
- `build/` / `.kofun/` — compiler and project output.

Never make a source fix only inside one of these directories.

## Find the owner for a change

| You want to change… | Start in… | Read next… | Run first… |
|---|---|---|---|
| public CLI routing or exit behavior | `bin/kofun` | `tests/cli.sh` | `task test` |
| Stage 1 Int/Bool/Text/List[Text] Core | `bootstrap/stage1/` | its README and `check.sh` | `task bootstrap` |
| Stage 2 syntax, typing, or C lowering | `bootstrap/stage2/` | its README and matching fixture | `task stage2` |
| a stable error code/message/span | emitter plus `tests/diagnostics/` | diagnostics README/registry | `task diagnostics` |
| x86-64 or AArch64 direct output | `bootstrap/native/` | native README and docs | `task native` |
| wasm32 arithmetic output | `bootstrap/wasm/` | wasm README | `task wasm` |
| C or Rust interoperability | `bootstrap/c_abi/`, `examples/rust-shim/` | security/third-party docs | `task c-abi` or `task rust-shim` |
| a standard-library contract | matching `stdlib/<name>/` | module README | its `tests/verify.sh` |
| HTTP, CLI, or TUI framework | matching `framework/<name>/` | subsystem README | matching task target |
| LSP behavior | `tooling/lsp/`, `tests/lsp/` | LSP README | `task lsp` |
| structural editor parsing | `kofun-lang/tree-sitter-kofun` | that repository's README | its own gate |
| VS Code packaging or metadata | `kofun-lang/kofun-vscode` | that repository's README | its own gate |
| language contract | `spec/` | spec index and conformance owner | matching spec/conformance gate |
| explanatory docs | `docs/` | this guide | the `spec/*/check.sh` that reads the document, if any |
| the browser tour | `docs/tour/` | `docs/tour/README.md` | `task tour` |
| docs UI, playground, or delivery snapshots | `kofun-lang/kofun-site` | that repository's `site/README.md` | `npm run verify:site` there |
| a benchmark program, harness, or recorded result | `kofun-lang/kofun-benchmarks` | that repository's `README.md` | its own harness |

## What to read on your first day

Choose the shortest path for your work:

- **Compiler contributor:** [Compiler architecture](COMPILER_ARCHITECTURE.md),
  `bootstrap/README.md`, the relevant stage README, then its `check.sh`.
- **Language designer:** [Implemented status](MVP_IMPLEMENTED.md), the relevant
  `spec/` contract, then [Syntax](SYNTAX.md) or
  [Type system](TYPE_SYSTEM.md).
- **Tooling contributor:** [Developer discovery](DEVELOPER_DISCOVERY.md), the
  LSP or typed-sidecar README, then its protocol tests.
- **Library/framework contributor:** `stdlib/README.md` or the framework
  README, followed by the focused fixtures and projection boundary.
- **Docs contributor:** [Contributing](CONTRIBUTING.md), then the document you
  are changing. If it is one the site renders, check
  `app/docs/docs-manifest.ts` in
  [`kofun-lang/kofun-site`](https://github.com/kofun-lang/kofun-site) before moving or
  renaming it.

The next practical step for every route is
[Contributing](CONTRIBUTING.md): it turns this map into a safe edit, test, and
review workflow.
