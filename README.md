# Kofun

![Kofun language icon: a keyhole-shaped burial mound](docs/kofun-mark.svg)

Kofun is an experimental programming language with a Kofun-written bootstrap
and direct ELF64 backends for x86-64 and AArch64. Source files use `.kofun`.

[Website](https://kofun-lang.github.io/kofun/) ·
[Documentation](https://kofun-lang.github.io/kofun/docs/) ·
[Playground](https://kofun-lang.github.io/kofun/#playground) ·
[Implemented status](https://kofun-lang.github.io/kofun/docs/implemented-status/) ·
[GitHub Project](https://github.com/users/hjosugi/projects/3) ·
[Releases](https://github.com/kofun-lang/kofun/releases)

> **Project status:** research compiler, not a production language. “Active”
> means an executable gate exists in this repository. Design documents and open
> issues are not implementation claims.

Kofun's product direction is **the language where you state an algebraic law
and the compiler hands you a counterexample.** General ownership and law
checking remain open work.

## Try it

```sh
./bin/kofun --version
./bin/kofun check bootstrap/fixtures/answer.kofun
./bin/kofun run bootstrap/fixtures/answer.kofun
mkdir -p build
./bin/kofun build bootstrap/fixtures/answer.kofun -o build/answer
./build/answer
```

See [Getting started](https://kofun-lang.github.io/kofun/docs/getting-started/)
for setup, supported targets, examples, and the complete CLI guide.

## Current boundary

| Area | Checked boundary |
|---|---|
| Bootstrap | Kofun-written seed and reproducible generations |
| C backend | bounded C11 emission |
| Frameworks | HTTP, CLI, and TUI gates |
| Frontend | focused Stage 2 parsing, typing, and diagnostics |
| Interop | explicit C ABI and audited Rust shim checkpoints |
| Native | direct x86-64 and AArch64 checkpoints |
| Quality | conformance, diagnostic, Unicode, and fuzz gates |
| Self-hosting | frozen-profile three-generation fixed point reached; full-language self-hosting open |
| Tooling | LSP and typed sidecars |
| WebAssembly | checked-Int64 wasm32 core and browser tour |

These are bounded checkpoints, not a general parser, complete memory-safe
runtime, or production toolchain. The semantic fixed point covers the frozen
bootstrap profile, not the full language.

The [implemented-status matrix](https://kofun-lang.github.io/kofun/docs/implemented-status/)
is the source of exact capability claims. Each row names a stable claim from
[`release/claims.json`](release/claims.json), its executable gate, and its
unsupported boundary. `task release-claims` fails when those disagree.

## Repository

Looking for the compiler itself? It is
[`bootstrap/stage2/compiler.kofun`](bootstrap/stage2/compiler.kofun), the
canonical front end written in Kofun, paired with
[`bootstrap/stage2/compiler.c`](bootstrap/stage2/compiler.c), the audited C11
seed that actually executes when you run the CLI.
[Compiler architecture](docs/COMPILER_ARCHITECTURE.md#where-the-compiler-actually-is)
explains which file runs when, and why a feature-named file under
`bootstrap/stage2/` does not mean that feature compiles.

| Path | Owns |
|---|---|
| [`bootstrap/`](bootstrap/) | compiler stages, self-hosting, native, wasm32, and C ABI checkpoints |
| [`spec/`](spec/) | normative contracts and executable specifications |
| [`tests/`](tests/) | conformance, diagnostics, fuzzing, and integration gates |
| [`framework/`](framework/) | bounded HTTP, CLI, and TUI libraries |
| [`stdlib/`](stdlib/) | Kofun syscall and standard-library contracts |
| [`docs/`](docs/) | source documents rendered by the official site |

The site, docs renderer, playground, and delivery snapshots live in
[`kofun-lang/kofun-site`](https://github.com/kofun-lang/kofun-site), which reads this
repository as a submodule. Use the
[repository guide](https://kofun-lang.github.io/kofun/docs/repository-guide/) for
the full source/gate map.

## Verify

The core gates require [go-task](https://taskfile.dev), a POSIX shell, a C11
compiler, Node.js, `sha256sum`, and Linux x86-64 tooling.

```sh
task --list          # available gates
task verify          # everything CI runs
task diagnostics     # registry and exact diagnostic fixtures
task release-claims  # published wording and executable evidence
```

Every task resolves to a checked-in script. Unsupported targets must refuse or
report themselves explicitly; they must not silently fall back.

## Contributing

Read the [contribution workflow](https://kofun-lang.github.io/kofun/docs/contributing/).
Good starting points carry both
[`curated`](https://github.com/kofun-lang/kofun/issues?q=is%3Aopen+label%3Acurated)
and [`ready`](https://github.com/kofun-lang/kofun/issues?q=is%3Aopen+label%3Aready).

## License

Licensed under [Apache-2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT), at your
option.
