# Stage 2 bounded include v1

The top-level form by which a Stage 2 Core unit reuses a declared, digested
block instead of a build-time extraction. This is the design recorded on
[#1690](https://github.com/kofun-lang/kofun/issues/1690), filed from
[#1668](https://github.com/kofun-lang/kofun/issues/1668) question 1 as the
replacement for extracting the pair's SHA-256 block between a marker comment
and `fn main`.

Both Stage 2 compilers implement this form. The `task include-form` gate runs
the public driver, the audited C seed and the canonical Kofun compiler.

## Posture

A bounded, non-ambient source-inclusion form, not a general import or package
system ([#1457](https://github.com/kofun-lang/kofun/issues/1457)). It reads
exactly the files a committed manifest declares, each pinned by SHA-256, and
reads no other target path. It does not make the filesystem an ambient input any more
than the existing bounded `Bytes` file read does.

## Source surface (gate `task include-form`)

- `include "NAME"` is a top-level form. `NAME` matches `[a-z][a-z0-9_]*` and is
  a declared include name, not a path.
- The include manifest is `bootstrap/stage2/includes-v1.tsv`; each row is
  `name<TAB>path<TAB>sha256`, where `path` is checkout-relative and tracked and
  `sha256` is the hex SHA-256 of the target's bytes.
- A target contributes only top-level `fn`, `type`, and `let` forms. Its
  declarations are spliced at the include site, before the including unit's own
  declarations. A single optional module header may precede the first include.
  Each name can appear once in the unit. The public driver checks that the
  declared module matches its path before compiling the standalone Core unit.
- The form is not transitive: a target that itself carries `include` is refused.

## Compiler inputs

The source names a block. The caller supplies the compiler with the exact
bytes in an explicit `--include-bundle BUNDLE` argument. The acquisition
step opens the manifest under the checkout root once and permits only the
regular files listed by `bootstrap/stage2/includes-v1.files`. The compiler's checkout driver also requires each path to match the
staged inventory and a regular-file mode in the Git index. Source archives
carry the same acquisition inventory. Every component below the checkout root must be
a real directory or the final regular file. The digest covers the bytes from
the same opened file that the compiler receives.

The v1 catalog allows 64 unique names of at most 64 ASCII bytes each and
65,536 bytes per target. Its prefix is `KOFUN-INCLUDES-1` followed by LF.
Each record contains the include name, TAB, the decimal payload length and
LF, exactly that many bytes of source, and a final LF. Paths remain private
to acquisition. A denied catalog leaves any prior destination intact.

## Refusals

The `include-form` diagnostic adapter exercises these refusals:

- `E2S224` — `NAME` is not a declared include name.
- `E2S225` — the target's bytes do not hash to the manifest's `sha256`.
- `E2S226` — the manifest names a `path` outside the checkout, or the target is
  not a regular tracked file, or the bounded catalog is malformed.
- `E2S227` — the target carries a nested `include`.

## Gate

`task include-form` compiles a module-headed program that includes the SHA-256
block and re-runs `task sha256-pair`'s oracle against the emitted program, so
the oracle stays independent of the include form. It also drives each refusal
above. It checks the digest build helper, SHA-256 pair gate and both Bytes
digest gates for the old SHA-256 marker lookup.

## Retirement

The digest command, SHA-256 pair gate and both Bytes digest fixtures compile
the pinned include. Removing the dedicated `bootstrap/digest/build.sh`
retires its shell source row. The two remaining gate scripts still have
shell responsibilities and remain in the forbidden-requirements census.
