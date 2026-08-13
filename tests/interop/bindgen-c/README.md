# bindgen-c stage-1 corpus

The executable gate for stage 1 of
[#574](https://github.com/kofun-lang/kofun/issues/574): `kofun bindgen-c`
generates audited raw C bindings from the Clang AST, before any C-to-Kofun
source translation exists.

```sh
sh tests/interop/bindgen-c/check.sh
```

That script runs the stage-1 checks below and then two sibling gates, each
owning one ready child of #574 and printing its own PASS lines so a reviewer
can tell which issue an assertion belongs to:

| Gate | Issue | What it owns |
|---|---|---|
| [`check-sanitizers.sh`](check-sanitizers.sh) | [#900](https://github.com/kofun-lang/kofun/issues/900) | the boundary under AddressSanitizer and UndefinedBehaviorSanitizer, on both sides |
| [`check-fuzz.sh`](check-fuzz.sh) | [#901](https://github.com/kofun-lang/kofun/issues/901) | adversarial macro expansion and bounded clang execution — corpus and README in [`fuzz/`](fuzz/) |

`task bindgen-c` runs those two after the stage-1 checks. Calling-convention
verification ([#903](https://github.com/kofun-lang/kofun/issues/903)) lives in
`check.sh` itself, alongside the ABI probe it extends.

The tool itself lives in [`tooling/bindgen-c/`](../../../tooling/bindgen-c/)
and is wired as `kofun bindgen-c HEADER.h --out-dir DIR`; its README states
the type mapping and the determinism contract. This directory holds the
pinned fixture library and the evidence.

## The fixture

[`fixture/kbfix.h`](fixture/kbfix.h) is a self-contained header (no
`#include`) exercising both halves of the stage-1 contract, implemented by
[`fixture/kbfix.c`](fixture/kbfix.c), which the gate compiles into
`libkbfix.so` with clang, offline.

Bound: an opaque handle create/destroy pair (client-owned, documented),
status-code returns over a closed `enum`, a buffer+explicit-length function,
a callback typedef with a documented invocation lifetime, a library-owned
string paired against the client-owned handle, and a fixed-layout record
passed and returned by value.

Audit-only, deliberately: an object-like macro constant, a function-like
macro, a variadic function, a union, a bitfield struct, a flexible array
member, a `static inline` function, and an x86_64 `ms_abi` declaration. Each
must appear in the
machine-readable report with a reason, and none may surface as a declaration
in the module — skipped constructs never silently disappear, and never
silently appear either.

Four fixture files sit beside it, owned by the sanitizer gate:

- [`fixture/kbfix_probe.c`](fixture/kbfix_probe.c) — the buffer+length and
  callback paths for #900. The checked C ABI profile cannot express a
  writable buffer or a function pointer from Kofun
  ([`bootstrap/c_abi/README.md`](../../../bootstrap/c_abi/README.md)), so
  those two contracts are exercised in C against the *same* sanitized
  library, and the gate requires every entry point it calls to be a bound
  symbol in the report;
- [`fixture/kbfix_negative.c`](fixture/kbfix_negative.c) — the
  AddressSanitizer negative fixture, which must fail with the library-side
  heap overflow;
- [`fixture/kbfix_leak.c`](fixture/kbfix_leak.c) — the LeakSanitizer negative
  fixture, which deliberately leaves a client-owned counter handle unfreed;
- [`fixture/kbfix_undefined.c`](fixture/kbfix_undefined.c) — the
  UndefinedBehaviorSanitizer negative fixture, which triggers signed overflow
  inside the fixture library.

## What is proved here

| Claim | Evidence |
|---|---|
| same inputs, same bytes | bindgen runs twice; module and report are compared with `cmp` |
| outputs carry no machine identity | neither artifact may contain the repository root or the gate work directory; the report is walked for any absolute path |
| the interpretation context is captured | the module and report must record the clang version, effective target triple, language standard, defines, include paths, sysroot, and the header's sha256, which the gate recomputes with `bin/kofun-sha256` |
| context changes invalidate the artifact | regenerating with `-D KBFIX_EXTRA=1` must change both artifacts and must add `kbfix_extra_probe`, a declaration that exists only under that define — the define provably reached clang |
| recorded ABI facts are the C compiler's facts | [`make-abi-probe.mjs`](make-abi-probe.mjs) generates a C program from the report; clang compiles it against the real header; its `sizeof`/`_Alignof`/`offsetof`/enum-constant output must equal the report's numbers byte for byte |
| calling conventions are checked, not asserted | each accepted function records a target- and AST-derived convention; the generated C probe compares its real function type with an explicitly attributed type, while missing/unknown data and the fixture's non-default `ms_abi` declaration must be rejected with machine-readable reasons |
| bound symbols exist | every `layout.functions[].symbol` must appear in `readelf --dyn-syms` of the fixture library |
| the module is mechanically valid | concatenated with [`driver.kofun`](driver.kofun), it builds through `kofun build --backend c --c-abi --link-library`, where the independent c_abi compiler re-derives the record layout and `_Static_assert`s it into the emitted C |
| the bindings actually work | the driver runs against `libkbfix.so` and must reproduce [`driver.stdout`](driver.stdout): scalar-only, pointer-bearing, and by-value record calls, accepted and refused status codes, an unchanged counter after refusal, and the library-owned string observed through the boundary |
| unsupported constructs are audited | [`check-report.mjs`](check-report.mjs) requires one row per deliberate construct, with kind, category, and a non-empty reason, in sorted order |
| raw is marked raw | the `.raw.` filename segment, the banner, `trust: raw-trusted-foreign` in module and report, and the instruction to import only behind a hand-reviewed safe façade are all asserted |
| malformed input fails loudly | a garbage header and a missing header must be refused with errors that name the cause, creating no output |
| neither side of the boundary hides a memory fault (#900) | `libkbfix.so` **and** the emitted C of the generated boundary are both rebuilt with ASan+UBSan and `-fno-sanitize-recover=all`; the gate asserts `__asan_` is present in both binaries before trusting a green run, and the driver must still reproduce `driver.stdout` with an empty stderr |
| the AddressSanitizer arm is armed (#900) | [`fixture/kbfix_negative.c`](fixture/kbfix_negative.c) lies about a buffer's capacity so the fault lands *inside* `kbfix_label_copy`; it must fail with a `heap-buffer-overflow` report naming `kbfix.c` |
| the LeakSanitizer arm is armed (#992) | with `detect_leaks=1`, [`fixture/kbfix_leak.c`](fixture/kbfix_leak.c) allocates through `kbfix_counter_new` and deliberately violates the client-owned handle contract; it must fail with `LeakSanitizer: detected memory leaks` |
| the UndefinedBehaviorSanitizer arm is armed (#992) | [`fixture/kbfix_undefined.c`](fixture/kbfix_undefined.c) triggers a signed `long` overflow inside `kbfix_stats_scale`; it must fail with `runtime error: signed integer overflow` naming `kbfix.c` |
| hostile macros are bounded, not survived (#901) | a committed corpus and a seeded mutation fuzzer, both described in [`fuzz/README.md`](fuzz/README.md); every case is either byte-identical twice or refused by name with no `--out-dir`, and a clang that never answers is refused by the wall-clock bound |

## What stage 1 deliberately does not claim

Generated code is **not evidence of safety**. The module is raw and trusted
by construction:

- pointer ownership (who allocates, who frees, how long a pointer stays
  valid) is not encoded in C headers and is therefore recorded as
  `ownership-unreviewed` review rows, one per pointer-bearing function —
  the gate fails if any such function lacks its row;
- opaque handles and other pointers are lowered to the untyped `CBytes`;
  nothing stops one handle type being passed where another is expected —
  each lowering is a review row, not a claim;
- callback invocation lifetime, thread affinity, and duration are prose in
  the header and review rows in the report, never machine-checked;
- enum constants are recorded in the report and as comments, not bound as
  Kofun values; macros are never bound at all;
- a hand-written safe façade over this module is future, reviewed work, and
  the module says so in its banner.

## The migrate-c boundary

#574 defers `kofun migrate-c` (C source → Kofun translation) until bindgen
is stable, because C aliasing, pointer arithmetic, unions, preprocessor
configuration, unchecked integer behavior, and lifetime conventions cannot
be relabeled as safe Kofun by syntax translation. Nothing in this corpus
translates C function bodies, and nothing here should be read as a first
step of that translator: stage 1 ends at declarations, layout facts, and
the audit trail.

## Known boundaries

The generated module targets the checked C ABI profile
([`bootstrap/c_abi/`](../../../bootstrap/c_abi/)), the only surface where
`extern "C"` declarations are compiled today; `kofun check` alone stops at
`error[E2S02]` on any extern declaration, so mechanical validation runs
through `--backend c --c-abi`. The profile has no named opaque handle
types, no enum declarations, no function-pointer types, and no unsigned
`size_t` distinct from `CULong`/`CSize` at this boundary; the report's
`layout` section carries the precise C types so no information is lost to
the lowering. Declarations pulled in through `#include` are resolved for
type mapping but not bound; the fixture header is self-contained on
purpose.
