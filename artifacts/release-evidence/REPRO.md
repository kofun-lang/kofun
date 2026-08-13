# Reproducing the release evidence

Generated from `release/claims.json` by `task release-evidence`. Do not edit.

From a clean checkout:

```sh
task verify
task release-evidence
```

## External prerequisites

A gate whose prerequisite is missing must report a skip. It must never
report a pass it did not observe.

| Prerequisite | Claims that need it |
|---|---|
| `cargo` | `rust-crate-shim` |
| `cc` | `affine-resource-handle`, `bindgen-c-stage1`, `bounded-tzdb-producer`, `c-abi-profile`, `c11-function-calls`, `c11-list-int-values`, `compiled-visibility-interfaces`, `compiler-seed`, `decimal-arithmetic-v1`, `deterministic-fuzzing`, `diverse-double-compilation`, `documentation-index`, `enum-matching`, `http-framework`, `nominal-records`, `reproducible-bootstrap`, `self-recompile`, `stage2-core-lowering` |
| `clang` | `bindgen-c-stage1`, `diverse-double-compilation` |
| `gcc` | `diverse-double-compilation` |
| `node` | `bindgen-c-stage1`, `compiled-visibility-interfaces`, `documentation-index`, `stage2-typed-sidecar`, `stdio-language-server`, `wasm32-arithmetic-core`, `wasm32-hostabi1-object-arena` |
| `qemu-aarch64` | `native-aarch64-function-calls`, `native-list-int-core`, `native-text-returning-calls`, `native-utf8-text-core`, `selfhost-native-corpus` |
| `readelf` | `bindgen-c-stage1` |

## Per-claim reproduction

| Claim | Command |
|---|---|
| `affine-resource-handle` | `task affine-resource-handle` |
| `arithmetic-core` | `task test` |
| `bindgen-c-stage1` | `task bindgen-c` |
| `borrowed-list-ownership` | `task stage2` |
| `bounded-tzdb-producer` | `task tzdb` |
| `c-abi-profile` | `task c-abi` |
| `c11-function-calls` | `task stage2` |
| `c11-list-int-values` | `task list-int-values` |
| `checked-int64-contract` | `task check` |
| `cli-commands` | `task test` |
| `cli-framework` | `task cli-framework` |
| `compiled-visibility-interfaces` | `task visibility-filtering` |
| `compiler-seed` | `task bootstrap` |
| `decimal-arithmetic-v1` | `task decimal-arithmetic` |
| `deterministic-fuzzing` | `task fuzz` |
| `diverse-double-compilation` | `task selfhost-diverse-double-compilation` |
| `documentation-index` | `task documentation-index` |
| `elf64-image-writer` | `task native` |
| `enum-matching` | `task syntax` |
| `formatter-and-repl` | `task repository-check` |
| `general-native-lowering` | `task native` |
| `general-ownership-checking` | `task stage2` |
| `general-parser-type-checker` | `task stage2` |
| `http-framework` | `task http` |
| `module-aliases` | `task import-aliases` |
| `native-aarch64-function-calls` | `task native` |
| `native-constant-stack-returns` | `task native` |
| `native-int64-values` | `task native` |
| `native-integer-division` | `task native` |
| `native-list-int-core` | `task native` |
| `native-text-returning-calls` | `task native` |
| `native-utf8-text-core` | `task native` |
| `native-x86-64-function-calls` | `task check` |
| `nominal-records` | `task records` |
| `public-re-exports` | `task re-exports` |
| `reproducible-bootstrap` | `task bootstrap` |
| `rust-crate-shim` | `task rust-shim` |
| `self-recompile` | `task selfhost-profile` |
| `selfhost-native-corpus` | `task selfhost-native` |
| `source-extension` | `task repository-check` |
| `stable-diagnostics` | `task diagnostics` |
| `stage2-core-lowering` | `task stage2` |
| `stage2-typed-sidecar` | `task typed-sidecar-projector` |
| `stdio-language-server` | `task lsp` |
| `syscall-file-round-trip` | `task stdlib` |
| `syscall-stdlib-api` | `task stdlib` |
| `test-skip-reporting` | `task test` |
| `wasm32-arithmetic-core` | `task wasm` |
| `wasm32-hostabi1-object-arena` | `task wasm-object-arena` |
