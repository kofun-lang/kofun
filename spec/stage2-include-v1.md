# Stage 2 bounded include v1

The top-level form by which a Stage 2 Core unit reuses a declared, digested
block instead of a build-time extraction. This is the design recorded on
[#1690](https://github.com/kofun-lang/kofun/issues/1690), filed from
[#1668](https://github.com/kofun-lang/kofun/issues/1668) question 1 as the
replacement for extracting the pair's SHA-256 block between a marker comment
and `fn main`.

**Every normative statement names the gate that fails if it is false.** The gate
is `task include-form`, added with the implementation this document specifies.
This draft is accepted design: it does not claim the form is implemented, and
`E2S02` still refuses every top-level form but `fn`, `type`, and `let` until the
implementation lands.

## Posture

A bounded, non-ambient source-inclusion form, not a general import or package
system ([#1457](https://github.com/kofun-lang/kofun/issues/1457)). It reads
exactly the files a committed manifest declares, each pinned by SHA-256, and
reads no other path. It does not make the filesystem an ambient input any more
than the existing bounded `Bytes` file read does.

## Source surface (gate `task include-form`)

- `include "NAME"` is a top-level form. `NAME` matches `[a-z][a-z0-9_]*` and is
  a declared include name, not a path.
- The include manifest is `bootstrap/stage2/includes-v1.tsv`; each row is
  `name<TAB>path<TAB>sha256`, where `path` is checkout-relative and tracked and
  `sha256` is the hex SHA-256 of the target's bytes.
- A target contributes only top-level `fn`, `type`, and `let` forms. Its
  declarations are spliced at the include site, before the including unit's own
  declarations.
- The form is not transitive: a target that itself carries `include` is refused.

## Refusals

Registered when the form is implemented, with the executable owner
`stage2-parser` in `tests/diagnostics/registry.tsv`:

- `E2S192` — `NAME` is not a declared include name.
- `E2S193` — the target's bytes do not hash to the manifest's `sha256`.
- `E2S194` — the manifest names a `path` outside the checkout, or the target is
  not a regular tracked file.
- `E2S195` — the target carries a nested `include`.

## Gate

`task include-form` compiles a module-headed program that includes the SHA-256
block and re-runs `task sha256-pair`'s oracle against the emitted program, so
the oracle stays independent of the include form. It also drives each refusal
above and asserts `git grep` finds no marker-to-`fn main` extraction in
`tests/stage2/sha256-pair/check.sh` or
`tests/conformance/bytes-read-file/run.sh`.

## Retirement

Replacing those two extractions retires their counted `shell-build-driver` rows,
recorded by `task forbidden-requirements-census`.
