# Issue 32: Stage 2 fixed point

## Verified starting point

The repository has three distinct working checkpoints:

1. the audited Stage 1 C11 seed builds a Kofun-written arithmetic-Core
   compiler;
2. the Stage 2 frontend produces stable source, token-tape, and structural IR
   projections and lowers a small integer `main` to C11; and
3. the native checkpoint executes deterministic Kofun-authored ELF fixtures.

The Stage 2 source projection reaches a byte fixed point, but this is not a
compiler fixed point. Stage 1 cannot parse and lower its own `Text`,
`List[Text]`, direct-call, loop, file-I/O, and string-building implementation.

## Artifact contract

The fixed-point gate uses these names conceptually:

```text
S   canonical compiler source
C1  deterministic C11 compiler source produced from the audited seed and S
A1  executable compiler produced by the declared normalized host cc from C1
C2  deterministic C11 compiler source produced by running A1 on S
A2  executable compiler produced by the same host cc from C2
C3  deterministic C11 compiler source produced by running A2 on S
A3  executable compiler produced by the same host cc from C3
```

Generated C11 is explicitly allowed for this first fixed point. All build
inputs, host-compiler identities and flags, target triples, layout rules, and
reproducibility settings must be declared and identical. Success requires
byte equality from generation 2 on:

```text
sha256(C2) == sha256(C3)
cmp C2 C3
sha256(A2) == sha256(A3)
cmp A2 A3
```

C1 and A1 are provenance, not fixed-point criteria. Decided on
[#271](https://github.com/kofun-lang/kofun/issues/271): C1 comes from the
trusted seed's emitter and C2 from the Kofun-written Stage 1 compiler — two
independently derived emitters for the same semantics, with different banners,
include order, runtime symbol names, and helper layout. Requiring `C1 == C2`
would mean rewriting the seed's lowering to stay byte-compatible with the
Kofun emitter forever, on a component whose purpose is to stay small and
auditable. A three-stage bootstrap's stage 1 is built by a foreign compiler
and is not expected to match; the fixed-point test is stage 2 against
stage 3. The gate records C1's digest, proves it built a runnable A1, and
states this criterion in its own output. Each generation's C must be written
under the same basename in its own directory, because the host C compiler
records the source basename in the binary it produces — a mismatch there
reports a fixed-point failure that has nothing to do with Kofun.

Direct-native compiler reproduction is not a prerequisite for this B4/B5
gate. It remains a separate strengthening track. Equality of token tapes,
structural IR, stdout, or behavior alone is useful differential evidence but
cannot replace both C-source and executable byte equality for this issue.

The manifest entry that closes the gate must record at least:

- canonical source path and SHA-256;
- trusted seed path and SHA-256;
- target triple and artifact format;
- exact reproduction command;
- SHA-256 for `C1`, `C2`, and `C3`;
- SHA-256 for `A1`, `A2`, and `A3`;
- host C compiler identity, binary digest, flags, and normalized environment;
- compiler version and source revision; and
- successful semantic conformance corpus digest.

The gate must rebuild in two clean temporary directories and reject an
undeclared environment-dependent difference.

## Required implementation order

1. Represent every construct used by canonical compiler source in parsed and
   typed IR.
2. Lower `Text`, `List[Text]`, calls, returns, branches, loops, mutation, and
   bootstrap file operations.
3. Produce `C1/A1` and run `A1` on the existing arithmetic and error corpus.
4. Produce `C2/A2` and `C3/A3` through the artifact chain above.
5. Compare exact C-source and executable bytes and update the manifest only in
   the same verified change.

Each language expansion must add a focused positive fixture, at least one
compile-fail fixture, and a differential execution case before it is used by
the compiler source.

## Executable close checklist

- [x] Canonical Stage 1 and Stage 2 source and audited seed hashes are checked.
- [x] The smallest canonical compiler `S` has a hash-pinned, executable feature
      inventory in `bootstrap/selfhost/`.
- [x] Stage 2 source/token/IR projection is deterministic.
- [x] A deliberately small integer Core lowers and executes deterministically.
- [ ] Stage 1 accepts every construct in its canonical source.
- [ ] The trusted seed produces `C1/A1`, and `A1` successfully compiles `S`.
- [ ] `A1` and `A2` produce `C2/A2` and `C3/A3`.
- [ ] `C1`, `C2`, and `C3` are byte-identical.
- [ ] `A1`, `A2`, and `A3` are byte-identical executables.
- [ ] The bootstrap corpus has identical values, statuses, and diagnostics.
- [ ] `bootstrap/manifest.json` closes both self-recompile gates and records
      the required hashes.
