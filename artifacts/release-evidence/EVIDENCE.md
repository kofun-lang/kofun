# Release evidence

Generated from `release/claims.json` by `task release-evidence`. Do not edit.

| Claim | Positive gate | Observation |
|---|---|---|
| `affine-resource-handle` | `task affine-resource-handle` | The reference evaluator, emitted Stage 2 C11, and scripted C11 host model agree on read, write, drain, close, cancel, terminal, and reuse observations. |
| `arithmetic-core` | `sh tests/cli.sh` | The arithmetic Core validates and emits without a diagnostic. |
| `bindgen-c-stage1` | `sh tests/interop/bindgen-c/check.sh` | The pinned fixture header generates byte-identical bindings and an audit report twice; the C compiler confirms the recorded sizes, offsets, enum values, and calling convention; and the bindings build, link, and run against the fixture library under AddressSanitizer and UndefinedBehaviorSanitizer with leak detection on. |
| `borrowed-list-ownership` | `sh bootstrap/stage2/check.sh` | The borrowed-List Copy/move checkpoint passes. |
| `bounded-tzdb-producer` | `sh tests/stdlib/tzdb/check.sh` | Typed HIR, emitted C11, the reference executor, and two repeated backend runs agree on exact normal/gap/fold, provenance, malformed, and resource-limit observations. |
| `bytes-bounded-mutation` | `task bytes-mutation` | Exact byte values survive read, write, copy and append at the boundary lengths, under O0 and O2 and under the sanitizers, with every failure leaving the carrier unchanged. |
| `c-abi-profile` | `sh bootstrap/c_abi/check.sh` | The C ABI profile builds and round-trips through host C. |
| `c11-function-calls` | `sh bootstrap/stage2/check.sh` | Int Core user-function calls lower and execute through C11. |
| `c11-list-int-values` | `task list-int-values` | Bounded list locals, direct-call copies, positive and negative reads and writes, source isolation, dynamic traps, exact refusals, and sanitizer execution agree. |
| `checked-int64-contract` | `sh tests/conformance/run.sh` | The numeric conformance corpus passes on every supported backend. |
| `cli-commands` | `sh tests/cli.sh` | Each subcommand succeeds on Core sources. |
| `cli-framework` | `sh framework/cli/check.sh` | The declarative CLI example builds statically and runs. |
| `compiled-visibility-interfaces` | `sh tests/conformance/modules/stage2-kif-producer/run.sh` | Compiler-produced label vectors round-trip source-free; internal-name renames remain stable while external-label renames invalidate the affected public and package-internal digests. |
| `compiler-seed` | `sh bootstrap/stage1/check.sh` | The C seed accepts and executes one corpus covering all 15 typed profile builtins, both `len` overloads, argv/file I/O, Text operations, character predicates, Unicode validation, and stdout. All 30 builtin arity/type boundary rows exit nonzero and write no C, while the older corpora remain byte-identical. |
| `decimal-arithmetic-v1` | `task decimal-arithmetic` | The Stage 2 C11 backend executes all Decimal and Float cases, including exactness beyond binary64, checked division, five signed rounding modes, mandatory scale/mode refusals, and format/parse round trips. |
| `deterministic-fuzzing` | `sh tests/fuzz/semantic_differential.sh` | Oracle and backend observations agree for every generated program. |
| `diverse-double-compilation` | `task selfhost-diverse-double-compilation` | Both toolchains' compilers emit byte-identical C and agree on the driver corpus. |
| `documentation-index` | `task documentation-index` | An actual Stage 2 KIF binary and matching typed sidecar project deterministically into distinct public and exact-package internal documentation views, including explicit current, partial, stale and cancelled trust states. |
| `elf64-image-writer` | `sh bootstrap/native/check.sh` | A static ELF64 image is written and executes. |
| `enum-matching` | `sh tests/conformance/syntax/issues_35_47/run.sh` | Payload-free and one-`Int`-payload enum matches lower and execute with exhaustiveness enforced; the fixtures read real payloads across local bindings, direct arguments, returns, guarded arms, and a re-matched binding catch-all. |
| `http-framework` | `sh tests/http/check.sh` | The bounded HTTP/1.1 server accepts and answers gated requests. |
| `macho64-ad-hoc-signing` | `task native` | Kofun emits both embedded ad-hoc signed images twice with identical bytes; an independent parser validates the load commands, SuperBlob, CodeDirectory, executable-segment fields, and independently recomputed page hashes, while optional file/LLVM tools identify both architectures. |
| `macho64-image-writer` | `task native` | Kofun emits the x86-64 and AArch64 Mach-O 64 images twice with identical bytes; the independent parser validates every load-bearing field and optional file/LLVM tools identify both exact architectures. |
| `module-aliases` | `sh tests/conformance/modules/import-aliases/run.sh` | Same-package aliases resolve while preserving target identity. |
| `native-aarch64-function-calls` | `sh bootstrap/native/check.sh` | AArch64 images are emitted and, with qemu present, execute to the expected values. |
| `native-constant-stack-returns` | `sh bootstrap/native/check.sh` | Three million recursive steps complete under a lowered stack limit. |
| `native-int64-values` | `sh bootstrap/native/check.sh` | Int64 magnitudes and checked expressions emit deterministic encodings on both targets. |
| `native-integer-division` | `sh bootstrap/native/check.sh` | Floor division and remainder agree with the specification on both targets. |
| `native-list-int-core` | `sh bootstrap/native/check.sh` | `List[Int]` programs lower and execute on both targets. |
| `native-six-host-execution` | `sh tests/native-host-evidence/check.sh` | The committed six-row evidence has one matching architecture/runner observation per target, binds every digest to bootstrap/native/SHA256SUMS, records the expected output and exit status, and records strict Apple validation for both Mach-O images. |
| `native-text-returning-calls` | `sh bootstrap/native/check.sh` | Text-returning calls lower and execute on both targets. |
| `native-utf8-text-core` | `sh bootstrap/native/check.sh` | UTF-8 `Text` programs lower and execute on both targets. |
| `native-x86-64-function-calls` | `sh tests/conformance/run.sh` | The functions corpus passes on the x86-64 native backend. |
| `nominal-records` | `task records` | The retained scanner fixture gates the full typed contract; the Stage 2 record fixture executes construction in both label orders, field reads, value arguments/results, AggregateLayout assertions, and the existing argument/refusal boundary. The additive aggregate-bridge dependency executes a mixed Text/List[Int]/Int report twice under strict C11, checks production emitted-C member reads and exact UTF-8 runtime bytes, independently matches every AggregateLayout offset and the record size, and requires exact no-C refusals for capacity 65, List[Text], and a named nested record/list path plus four capability mutations. Its separate complete sidecar check proves nominal, function, resolved base-reference, and concrete-type facts without claiming selector or field-use facts. |
| `pe32plus-image-writer` | `task native` | Kofun emits the x86-64 and AArch64 PE32+ images twice with identical bytes, and the independent parser validates every load-bearing DOS, COFF, optional-header, section, and entry field. |
| `public-re-exports` | `sh tests/conformance/modules/re-exports/run.sh` | Re-export chains resolve within the stated bounds and preserve binding identity. |
| `reproducible-bootstrap` | `sh bootstrap/stage1/check.sh` | Regeneration reproduces the checked-in Stage 1 artifact and its digest. |
| `rust-crate-shim` | `sh examples/rust-shim/check.sh` | The vendored crate builds and answers through the C ABI shim. |
| `self-recompile` | `task selfhost-fixed-point` | A2 compiles canonical S into a C3 byte-identical to C2 and rebuilds an A3 byte-identical to A2, twice in normalized clean directories, with all 45 driver corpus cases agreeing across A1 and A3 in emitted C, stdout, stderr, and exit status. |
| `selfhost-native-corpus` | `sh bootstrap/selfhost/native/check-native-corpus.sh` | The native and C11 self-host paths produce identical output. |
| `source-extension` | `task repository-check` | No Python or `.kf` sources remain. |
| `stable-diagnostics` | `sh tests/diagnostics/check.sh` | Every registry code has an owner and every fixture matches exactly. |
| `stage2-core-lowering` | `sh bootstrap/stage2/check.sh` | Integer Core sources lex, parse, lower and execute. |
| `stage2-typed-sidecar` | `task typed-sidecar-projector` | Stage 2 events project into a schema-valid typed-sidecar v1 document. |
| `stdio-language-server` | `sh tests/lsp/check.sh` | Every supported request answers and the measured percentiles stay inside their budgets. |
| `syscall-file-round-trip` | `sh stdlib/tests/verify.sh` | The file round-trip succeeds and returns the written bytes. |
| `syscall-stdlib-api` | `sh stdlib/tests/verify.sh` | The declared syscall and stdlib contracts check and execute. |
| `test-skip-reporting` | `sh tests/cli.sh` | Skipped cases appear in the report with their own count. |
| `wasm32-arithmetic-core` | `sh bootstrap/wasm/check.sh` | wasm32 modules are emitted and execute to the expected values. |
| `wasm32-hostabi1-object-arena` | `sh bootstrap/wasm/object_arena_check.sh` | The module passes v1 identification and its allocator/header implementation agrees with independent runtime and layout oracles. |
