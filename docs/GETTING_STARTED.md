# Getting started

This guide takes a new contributor from a clean machine to a checked local
change. Kofun is an experimental research compiler, so the repository itself
is the development environment: there is no separately installed SDK required
for the normal contributor path.

## What you will have at the end

After about fifteen minutes, you should be able to:

- run the repository launcher;
- check, run, and build a small `.kofun` program;
- run the fast test gates for the area you want to change;
- start the documentation site locally; and
- identify the next guide for compiler, language, or site work.

If you already have the repository and toolchain, skip to
[Verify the checkout](#verify-the-checkout).

## 1. Use a supported development environment

The reference development and CI environment is Linux. Ubuntu or a Linux
environment under WSL is the shortest path because direct ELF execution,
binary inspection, and several shell gates use Linux tools.

The common compiler path needs:

| Tool | Why it is needed | Quick check |
|---|---|---|
| POSIX shell | launcher and repository gates | `sh --version` or `sh -c 'echo ok'` |
| C11 compiler | builds the checked compiler seeds | `cc --version` |
| Task (go-task) | named verification gates | `task --version` |
| Node.js 24 | browser tour, typed-sidecar tools, and wasm32 execution | `node --version` |
| npm | locked Tree-sitter dependencies | `npm --version` |
| Git | source control and some reproducibility checks | `git --version` |

Bootstrap and vendored-source integrity use `./bin/kofun-sha256`, which the
repository builds from its checked-in C11 SHA-256 implementation.

The complete `task verify` gate also uses:

- Rust and Cargo for the audited Rust-shim example;
- `ar`, `ld`, `readelf`, `file`, and `ldd` for native and ABI checks;
- `script` from util-linux for terminal tests; and
- `qemu-aarch64` to execute AArch64 output on a non-AArch64 host.

`qemu-aarch64` is optional for focused local work, but CI installs it and
executes the AArch64 corpus. macOS can run some frontend and website tasks, but
it is not a substitute for the Linux verification boundary. If a gate depends
on ELF, Linux syscalls, `ldd`, or QEMU, use Linux before treating the result as
verified.

## 2. Get the repository

```sh
git clone https://github.com/kofun-lang/kofun.git
cd kofun
git status --short
```

Run every command in this guide from the repository root, the directory that
contains `Taskfile.yml`, `bin/`, `bootstrap/`, and `docs/`. A clean checkout
prints nothing for `git status --short`.

Run bare `task` to open the grouped contributor guide. It keeps task names and
descriptions from go-task's own inventory, then groups them by role so the
complete gate surface is easier to scan. `task help` prints the same guide;
`task --list` remains the official flat inventory.

```sh
task
task --list
```

The project does not require a global `kofun` install. Use `./bin/kofun` so the
command and the compiler sources always come from the same commit.

## 3. Run the smallest smoke test

```sh
./bin/kofun --version
task check
```

The launcher builds a checked compiler artifact under `build/` when needed.
`build/` is disposable, ignored output; it is not source and must not be
committed.

If you prefer Clang:

```sh
CC=clang task check
```

`task check` proves that the launcher can build the compiler seed and accept
the canonical arithmetic fixture. It is intentionally smaller than the full
repository suite.

## 4. Check, run, and build a program

Use the canonical fixture first:

```sh
./bin/kofun check bootstrap/fixtures/answer.kofun
./bin/kofun run bootstrap/fixtures/answer.kofun
mkdir -p build
./bin/kofun build bootstrap/fixtures/answer.kofun -o build/answer
./build/answer
```

The checked arithmetic Core accepts integer expressions and `print`:

```kofun
# expect: 42
fn main() {
    print((6 + 1) * 6)
}
```

Source files use `.kofun`. Unsupported syntax or target behavior must fail
explicitly; the launcher must not silently switch to a different frontend or
backend.

To inspect the current command surface:

```sh
./bin/kofun --help
```

### Understand the launcher boundary

`bin/kofun` is an orchestrator, not one monolithic compiler. Depending on the
command and flags, it builds and invokes a checked Stage 1, Stage 2, native,
wasm32, C ABI, or CLI-framework compiler. These are deliberately bounded
profiles. Acceptance by one path does not imply support by all paths.

The [implemented-status matrix](MVP_IMPLEMENTED.md) is the authority for what
is executable now. The [repository guide](REPOSITORY_GUIDE.md) explains where
each path lives.

## 5. Choose one checked path

### Stage 2 and the host C backend

The default `build` path tries the Stage 2 C11 Core and uses the explicit
Stage 1 compatibility path only for source classified as valid but outside the
Stage 2 lowering slice:

```sh
./bin/kofun build bootstrap/stage2/core_fixture.kofun \
  -o build/stage2-example
./build/stage2-example
```

Read [`bootstrap/stage2/README.md`](../bootstrap/stage2/README.md) before
changing frontend behavior. It documents the accepted slice, diagnostics, and
focused helper checkpoints.

### Direct native x86-64

```sh
./bin/kofun build bootstrap/fixtures/answer.kofun \
  --target x86_64-linux -o build/answer-x86_64
./build/answer-x86_64
```

This emits a static ELF64 image directly. It does not mean every construct
accepted by the C path is available in direct native code generation.

### Direct native AArch64

```sh
./bin/kofun build bootstrap/fixtures/answer.kofun \
  --target aarch64-linux -o build/answer-aarch64
qemu-aarch64 ./build/answer-aarch64
```

On a native AArch64 Linux machine, run the output directly. On another
architecture, install QEMU user-mode support first.

### WebAssembly

```sh
./bin/kofun build examples/wasm_arithmetic.kofun \
  --target wasm32 -o build/arithmetic.wasm
node bootstrap/wasm/run.mjs build/arithmetic.wasm
```

The wasm32 profile is a checked Int64 arithmetic Core, not a browser-complete
general compiler.

### Declarative native CLI

```sh
./bin/kofun build examples/cli_tool.kofun \
  --framework cli -o build/kofun-tool
./build/kofun-tool greet Ada --prefix Welcome
```

The CLI framework has its own source contract and gate in `framework/cli/`.

### Typed tooling output

```sh
mkdir -p build
./bin/kofun check bootstrap/fixtures/answer.kofun \
  --emit-typed-sidecar build/answer.kofun-semantic.json \
  --generation 1
```

The typed sidecar is non-authoritative tooling data. It is not compiler input,
a cache, or proof that broader Stage 2 semantics are implemented.

## 6. Verify the checkout

Use a testing ladder instead of starting every edit with the full suite:

```sh
task check          # launcher and canonical fixture
task test           # public build/run/check/test behavior
task diagnostics    # stable diagnostic registry and exact fixtures
task stage2         # Stage 2 frontend and bounded C11 lowering
task native         # direct x86-64 and AArch64 checkpoints
task fuzz           # deterministic grammar and semantic fuzz smoke tests
task verify         # every active repository gate, then LSP/roadmap checks
```

`task verify` runs independent gates in parallel and can consume substantial
CPU. For readable failure output or local bisection:

```sh
VERIFY_JOBS=1 task verify
```

Run the narrow gate while developing, then the broader relevant gate before
you submit a change. CI runs `task verify`.

See [Contributing](CONTRIBUTING.md#test-the-smallest-relevant-surface) for the
test command mapped to each repository area.

## 7. Run the documentation site

The official website lives in
[`kofun-lang/kofun-site`](https://github.com/kofun-lang/kofun-site), not here. It is a
Next.js application that checks this repository out as a submodule and renders
selected Markdown from it at build time. This repository needs no npm
toolchain: `task verify` never touches one.

To run it:

```sh
git clone https://github.com/kofun-lang/kofun-site
cd kofun-site
git submodule update --init
npm ci
npm run dev
```

Open the local URL printed by Next.js, then visit `/docs`. When the site is
served with the GitHub Pages base path, the published route is `/kofun/docs/`;
local development normally uses `/docs`.

The browser tour is the exception: `docs/tour/` is checked source in *this*
repository, because `docs/tour/compiler.mjs` is a browser port of
`bootstrap/wasm/compiler.c` that `task tour` pins byte for byte. The site only
copies it.

## 8. Make a safe first change

A documentation-only first contribution is a good way to learn the gates:

1. create a short-lived branch;
2. edit the authoritative Markdown under `docs/`;
3. run the `spec/*/check.sh` that reads it, if any, then `task verify`;
4. if it should become a first-class documentation page, add it to
   `app/docs/docs-manifest.ts` in `kofun-lang/kofun-site` and run `npm run
   test:docs` there;
5. inspect `git diff --check` and `git status --short`; and
6. commit only the intended files.

For compiler work, do not begin by editing a generated or audited artifact in
isolation. Read the nearest README and its `check.sh`, identify the canonical
source, fixture, expected output, and digest contract, then change them as one
reviewable unit.

Continue with:

- [Repository guide](REPOSITORY_GUIDE.md) — where code, specifications, tests,
  generated output, and website sources live;
- [Contributing](CONTRIBUTING.md) — change recipes, test selection, review
  expectations, and the definition of done;
- [Compiler architecture](COMPILER_ARCHITECTURE.md) — bootstrap layers and
  trust boundaries; or
- [Syntax](SYNTAX.md) and [Type system](TYPE_SYSTEM.md) — language direction
  with current implementation qualifiers.

## Common setup problems

### `cc: not found`

Install a C development toolchain and confirm `cc --version`. The compiler
seeds are C11 and use warnings as errors in their gates.

### A native or ABI gate reports a missing tool

Read the first missing command in the error. Install the corresponding Linux
binary tools, util-linux, Rust/Cargo, or QEMU package, then rerun the same
focused gate. Do not reinterpret a skipped architecture as a passing result.

### A test passes alone but fails during parallel `task verify`

Rerun with `VERIFY_JOBS=1 task verify`. If the focused gate still passes,
capture both results; tests must not depend on shared mutable temporary paths
or timing that becomes invalid under the repository's parallel verification.

### The website shows an old browser tour

The site copies `docs/tour/` at build time, so a stale copy means the site was
built against an older submodule pointer. Change the tour here, run `make
tour`, then advance the submodule in `kofun-lang/kofun-site`.

### A diagnostic changed unexpectedly

Run:

```sh
sh tests/diagnostics/check.sh
sh tests/diagnostics/run.sh
```

If the change is intentional, read
[`tests/diagnostics/README.md`](../tests/diagnostics/README.md) before using
the bless workflow. Review regenerated goldens; never accept a bulk rewrite
without understanding each public diagnostic change.

### `git status` contains files you did not edit

Stop before staging. This repository has generated outputs, audited bootstrap
artifacts, and concurrent work that may be unrelated to your task. Inspect
`git diff -- <path>`, stage explicit paths, and do not use a broad reset or
checkout to erase somebody else's work.
