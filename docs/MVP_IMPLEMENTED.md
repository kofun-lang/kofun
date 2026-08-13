# Implemented status

| Capability | Status | Gate | Claim |
|---|---|---|---|
| `.kofun` source extension | implemented | `task repository-check` | `source-extension` |
| Kofun-written compiler seed | implemented: nested-block and looping Int/Bool/Text/List[Text] Core with 15 typed profile builtins | `bootstrap/stage1/check.sh` | `compiler-seed` |
| Reproducible bootstrap | implemented | `bootstrap/stage1/check.sh` | `reproducible-bootstrap` |
| arithmetic Core validation/emission | implemented | `tests/cli.sh` | `arithmetic-core` |
| build/run/check/test CLI | Core only | `tests/cli.sh` | `cli-commands` |
| explicit skip reporting and coverage | implemented | `kofun test` | `test-skip-reporting` |
| semantic compiler self-recompile | three-generation fixed point reached for the frozen profile: C2 == C3 and A2 == A3 byte for byte | `task selfhost-fixed-point` | `self-recompile` |
| diverse double compilation | two unrelated host C compilers build Kofun compilers that emit byte-identical C; independent reproduction (B6) stays open | `task selfhost-diverse-double-compilation` | `diverse-double-compilation` |
| Stage 2 lexer, parser, and integer Core lowering | checkpoint implemented | `bootstrap/stage2/check.sh` | `stage2-core-lowering` |
| Stage 2 semantic tooling output | bounded compiler-derived KSE projects one-way into canonical non-authoritative typed-sidecar v1 for explicit single-file `kofun check`; compiler/KIF/cache consumers remain forbidden | `task stage2-events`, `task typed-sidecar-projector` | `stage2-typed-sidecar` |
| compiled visibility interfaces | bounded Stage 2 KIF v2: exact resolved flat-nominal function/payload refs and parameter labels; public/internal/private leak rejection; atomic public/internal filtering | `task visibility-filtering`, `task visibility-api-leaks`, `task module-interface-artifact` | `compiled-visibility-interfaces` |
| typed-sidecar documentation index | bounded KIF-filtered projection: canonical public and exact-package internal declaration views with explicit partial/stale trust and atomic publication | `task documentation-index` | `documentation-index` |
| qualified module aliases | bounded same-package `import a.b as local`; local-only `AliasBindingId` preserves target identity, with no public/per-name/external aliases or `bin/kofun` routing | `tests/conformance/modules/import-aliases/run.sh`, `task import-aliases` | `module-aliases` |
| C11 user-function calls | bounded Int Core: recursion and forward calls | `bootstrap/stage2/check.sh` | `c11-function-calls` |
| C11 bounded List[Int] values and mutable local writes | bounded by-value 64-element locals and direct function carriers; standalone mutable-local element assignment with checked positive, negative, constant, and dynamic indices | `task list-int-values`, `task list-int-signatures` | `c11-list-int-values` |
| x86-64 native user-function calls | bounded Int Core: six arguments, guarded returns, recursion | `tests/conformance/functions` | `native-x86-64-function-calls` |
| x86-64/AArch64 native Text-returning calls | bounded compiler-shaped profile with parameters, locals, concatenation, forwarding, and direct calls | `bootstrap/native/check.sh` | `native-text-returning-calls` |
| AArch64 native user-function calls | same bounded Int Core lowered to AArch64; executed under `qemu-aarch64` | `tests/conformance/functions`, `bootstrap/native/check.sh` | `native-aarch64-function-calls` |
| x86-64/AArch64 native Int64 values | literal magnitudes through `INT64_MAX`, backward-compatible deterministic encodings, and the complete signed range through checked expressions | `bootstrap/native/check.sh` | `native-int64-values` |
| x86-64/AArch64 native integer division | `//` and `%` use the specified floor semantics; `/` is not defined on `Int` and both targets refuse it with one diagnostic (#687); both guard zero and non-representable quotients with canonical per-operator `R010` diagnostics | `tests/conformance/numeric`, `tests/conformance/functions`, `bootstrap/native/check.sh` | `native-integer-division` |
| exact Decimal arithmetic, explicit rounding, and binary64 Float | Stage 2 C11 lowers native Decimal `+`, `-`, `*`, comparison/equality, checked `/`, all five signed rounding modes, rounded division with mandatory scale/mode, and exact display-scale format/parse; Float remains observably binary64; every other declared backend has an explicit unsupported capability row (#724) | `tests/conformance/decimal-arithmetic`, `tests/conformance/capabilities.tsv`, `tests/conformance/decimal/run.sh`, `stdlib/decimal/tests/verify.sh` | `decimal-arithmetic-v1` |
| self-host success corpus as a native binary | the driver's five-`print` corpus reaches a static ELF on both targets and matches the self-host C11 path exactly | `bootstrap/selfhost/native/check-native-corpus.sh` | `selfhost-native-corpus` |
| x86-64/AArch64 constant-stack returned calls | a `return` of a direct call branches instead of calling, so direct and mutual recursion in that position run in constant stack; proved by executing three million steps under a lowered stack limit | `bootstrap/native/check.sh`, `tests/conformance/functions` | `native-constant-stack-returns` |
| stable diagnostics | canonical registry plus executable family owners; Stage 2 retains 46/46 codes and 3 explicit span debts | `tests/diagnostics/`, `task diagnostics` | `stable-diagnostics` |
| explicit public re-exports | bounded same-package `pub import` / `pub from`; non-widening `ExportBindingId` edges, 64-edge chains, 1,024 bindings/module and 65,536 edges/package, KIF export facts, and facade/canonical tooling paths | `tests/conformance/modules/re-exports/run.sh`, `task re-exports` | `public-re-exports` |
| deterministic compiler fuzzing | versioned oracle/backend observations for arithmetic plus focused grammar, value-if, match-guard, match-value, and enum-match families | `tests/fuzz/`, `task fuzz` | `deterministic-fuzzing` |
| concrete enum matching with one `Int` payload | bounded Stage 2 C11 slice with constructor-set exhaustiveness; constructors and enum bindings cross ordinary function arguments and returns, `C(name)` exposes the payload to guards and arm bodies, and a binding catch-all may be re-matched. Wider payload types, more than one field, nested payload patterns, generics, and non-C11 backends stay outside it | `tests/conformance/syntax/issues_35_47/run.sh`, `tests/fuzz/enum_match.sh` | `enum-matching` |
| nominal heterogeneous records | bounded Stage 2 C11 mixed `Text`/capacity-64 `List[Int]`/`Int` records: labelled construction, declaration-order AggregateLayout, typed field reads, whole-record pass/return, and list-field copy semantics; no general lists, `List[Text]`, nested aggregates, modules, generics, native lowering, or stable ABI | `task aggregate-bridge`, `task records`, `spec/records-v1.md` | `nominal-records` |
| general parser/type checker | open | no active gate | `general-parser-type-checker` |
| borrowed-List Copy/move ownership check | narrow Stage 2 checkpoint | `bootstrap/stage2/check.sh` | `borrowed-list-ownership` |
| bounded injected-Bytes time-zone transition producer | bounded Stage 2/C11 checkpoint | `task tzdb` | `bounded-tzdb-producer` |
| bounded affine resource-handle protocol | bounded Stage 2/C11 checkpoint | `task affine-resource-handle` | `affine-resource-handle` |
| general ownership and law checking | open | no active general pass | `general-ownership-checking` |
| ELF64/x86-64 native image writer | checkpoint implemented | `bootstrap/native/check.sh` | `elf64-image-writer` |
| Mach-O 64/x86-64 and AArch64 native image writer | bounded deterministic image checkpoint with a declared libSystem runtime dependency; matching-host execution covered by the six-host evidence claim, not a macOS CLI/general runtime | `bootstrap/native/check.sh`, `bootstrap/native/check-macho64.sh` | `macho64-image-writer` |
| Mach-O 64 embedded ad-hoc signing | bounded deterministic x86-64/AArch64 signed-image checkpoint; matching-host strict validation/execution covered separately; no notarization or certificate claim | `bootstrap/native/check.sh`, `bootstrap/native/check-macho64-signed.sh` | `macho64-ad-hoc-signing` |
| PE32+/x86-64 and AArch64 native image writer | bounded deterministic no-import image checkpoint; matching-host execution covered by the six-host evidence claim, not a Windows CLI/general runtime | `bootstrap/native/check.sh`, `bootstrap/native/check-pe32plus.sh` | `pe32plus-image-writer` |
| exact six native checkpoint images on matching hosts | Linux, Windows, and macOS x86-64/AArch64 digest-bound execution; macOS also passes strict Apple signature validation | `tests/native-host-evidence/check.sh`, `.github/workflows/native-hosts.yml` | `native-six-host-execution` |
| wasm32 Int64 arithmetic Core + lazy browser host | executable checkpoint | `bootstrap/wasm/check.sh`, `tests/conformance/numeric`, `examples/wasm-browser` | `wasm32-arithmetic-core` |
| wasm32 host ABI v1 bounded object arena | executable checkpoint | `task wasm-object-arena` | `wasm32-hostabi1-object-arena` |
| x86-64/AArch64 List[Int] Core | checkpoint implemented; AArch64 executes under qemu | `bootstrap/native/check.sh`, `tests/conformance/list` | `native-list-int-core` |
| x86-64/AArch64 UTF-8 Text Core | checkpoint implemented; AArch64 executes under qemu | `bootstrap/native/check.sh`, `tests/conformance/text` | `native-utf8-text-core` |
| general native lowering | open | unified types/control flow and additional target profiles | `general-native-lowering` |
| C ABI `extern` / `repr(C)` profile | bounded host-C implementation | `bootstrap/c_abi/check.sh` | `c-abi-profile` |
| audited raw C bindings from the Clang AST | bounded stage-1 generator; raw and trusted, not safe | `tests/interop/bindgen-c/check.sh` | `bindgen-c-stage1` |
| vendored Rust crate through C ABI shim | implemented example | `examples/rust-shim/check.sh` | `rust-crate-shim` |
| Linux HTTP/1.1 epoll framework through C ABI | bounded library implementation | `tests/http/check.sh` | `http-framework` |
| Linux x86-64 native CLI application framework | bounded direct-static implementation | `framework/cli/check.sh` | `cli-framework` |
| Linux x86-64 syscall/stdlib API | Kofun source contract | `stdlib/tests/verify.sh` | `syscall-stdlib-api` |
| syscall file round-trip execution | implemented | native ELF success and errno failure gates | `syscall-file-round-trip` |
| stdio language server | bounded diagnostics, definitions, hover, completion, outline, references, highlights, ownership inlay hints, signature help, folding, selection ranges, semantic tokens, and rename for locals and parameters | `tests/lsp/check.sh` | `stdio-language-server` |
| formatter and REPL | open | design only | `formatter-and-repl` |
| checked Int64 contract | implemented for Core | numeric conformance corpus | `checked-int64-contract` |

Historical prototypes do not count as active after their source is removed.

The `Claim` column is the stable identity of each row in
[`release/claims.json`](../release/claims.json), which binds it to a positive
gate, a boundary that fails outside it, and a reproduction command.
`task release-claims` fails if a row here gains, loses, or reworders a
capability without the manifest following, so this table and the evidence
cannot drift apart. Status text lives here and is mirrored into the manifest;
do not restate it in the manifest by hand.
