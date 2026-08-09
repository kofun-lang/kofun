# First self-host profile

This directory freezes the smallest honest compiler source profile for the
first semantic self-recompile. The canonical source `S` is the existing,
reviewed seed:

```text
bootstrap/stage1/compiler.kofun
```

It is deliberately reused rather than copied into a second self-host tree.
`profile.meta` pins its digest, `profile.tsv` records every language and host
feature used by that source, and `check-profile.sh` rejects an unreviewed
source/profile drift.

Run the gate with:

```sh
task selfhost-profile
```

Run the actual compiler self-compile slice with:

```sh
task selfhost-self-compile
```

That gate builds `A1`, has it compile the exact canonical `S` bytes from
different directories and source names, and requires the two nonempty `C2`
outputs to be byte-identical and valid strict C11. On hosts exposing
`ulimit -v`, each compilation also runs under a 1.5 GiB address-space ceiling.
This closes the first `A1(S)` step; it does not claim the three-generation
fixed point below.

## Typed HIR contract and phase gates

`hir-v1.md` freezes the versioned `kofun.selfhost-hir/v1` schema: the typed
HIR that the #619 frontend must produce and that #620–#622 consume without
reparsing source text. Phase completion gates check evidence cells owned by
one implementation step:

```sh
sh bootstrap/selfhost/check-profile.sh --phase frontend
sh bootstrap/selfhost/check-profile.sh --phase c11-text
sh bootstrap/selfhost/check-profile.sh --phase c11-control
```

The frontend phase gate fails whenever any profile row's frontend cell
lacks checked-in evidence, listing each pending cell explicitly; it is the
#619 acceptance check. Since #654 landed the canonical-source port of the
typed-HIR emitter and per-family fixtures, all 46 frontend cells carry
evidence in `frontend/` and the gate runs green inside `task verify`.
The c11-text and c11-control gates are the matching #620/#621
completion checks for the c11 cells owned by the Text/function slice
and the mutation/loop/List slice. #622 completed the remaining host
cells and every other evidence column, and
`check-compiler-driver.sh` proves the trusted seed compiles the frozen
`S` into a runnable compiler whose Core-corpus behavior matches the
audited Stage 1 seed byte for byte (`driver/`).

## What the status columns mean

Each profile row has evidence slots for the canonical source, typed frontend,
C11 lowering, four separated compiler-evidence classes, positive test,
negative test, and differential test.

- a repository path means that evidence exists;
- `planned:#NNN` names the issue that must supply the evidence;
- `partial` means at least the frozen source evidence exists but the complete
  self-compile chain does not;
- `complete` requires every evidence class below to be **executed**, not
  merely present.

### The four compiler-evidence classes

`kofun.selfhost-profile/v2` replaces the single `self_compiler` column, which
held one path — `driver/S.c` — on all 46 rows and was checked by testing that
the file existed. One path cannot distinguish four different facts, and file
existence proves none of them. Each row now declares a prover per class, and
`check-profile.sh` runs it:

| Class | Cell | What runs |
|---|---|---|
| `used_by_s` | `inventory:S` | the feature must appear in the inventory the gate derives from the pinned canonical source |
| `accepted_by_a1` | `a1-accept:<corpus>` | A1 compiles `driver/<corpus>.kofun`, exits zero, and writes no diagnostic |
| `lowered_by_a1` | `a1-lower:<corpus>` | A1's emitted C is byte-identical to the reviewed `driver/<corpus>.c` |
| `self_application` | `gate:selfhost-self-compile` | A1 compiles the canonical source into a nonempty `C2`, and the named task target runs `check-compiler-driver.sh` inside the aggregate verification |

A row may not claim a corpus that does not use its feature: the gate derives
the corpus's own inventory with the same detector it applies to `S` and
requires the row's key to be in it. `A1` itself is built once from the reviewed
`driver/S.c`; that file's correspondence to `S` is the self-compile gate's
property, so this gate reads it rather than re-deriving it. Set
`KOFUN_SELFHOST_A1` to reuse an already-built binary.

The full self-compile proof — determinism, path independence, the audited
hand-port differential, and the strict-C11 host boundary — stays in
`check-compiler-driver.sh` and is not re-implemented here.

All 46 rows are `complete`. The final five rows are exercised by the #947
driver fixtures: `corpus_profile_complete` covers a parameterized declaration,
mutable local, assignment, and bare return, while `corpus_trap_fail` compiles
the zero-arity `fail()` builtin and pins its exit-1 runtime behavior. Both
fixtures carry reviewed emitted C, so their acceptance and lowering evidence
is executed rather than inferred from `S`.

The profile gate derives built-in calls and the bounded syntax/type inventory
from `S`, then compares it with the manifest. Changing `S` therefore requires
an explicit review of both its SHA-256 and coverage rows.

## Fixed-point boundary

The first fixed point permits generated deterministic C11 and one normalized,
declared host C compiler:

```text
S --trusted seed--> C1 --host cc--> A1
A1(S)------------> C2 --host cc--> A2
A2(S)------------> C3 --host cc--> A3
```

Success requires byte-identical `C2/C3` and byte-identical `A2/A3` — the
criterion decided on [#271](https://github.com/kofun-lang/kofun/issues/271).
`C1/A1` are recorded provenance: C1 comes from the trusted seed's independent
emitter, so it is not expected to match the Kofun-written compiler's output
byte for byte, and requiring it would freeze both emitters together forever.
Direct-native compiler reproduction is a separate strengthening track; it does
not block this first C11 fixed point.

The generation gates share one vocabulary, `generations-lib.sh` — criterion
string, declared flags, normalized environment (`LC_ALL=C`, `TZ=UTC`,
`umask 022`), resource bounds, digest helpers, generation derivation, and the
corpus differential — the same role `bootstrap/stage2/build.sh` plays for the
Stage 2 compile line.

`sh bootstrap/selfhost/build-a1-a2.sh OUTPUT` is the one documented generation
command: it verifies every declared input digest, derives `C1/A1` and `C2/A2`
twice in normalized clean directories (each generation's C under the same
basename), requires the two runs to agree byte for byte, runs the full driver
corpus through A1 and A2 differentially, and promotes the artifacts, the A1
corpus observations, and path-independent provenance under `OUTPUT` only.
`sh bootstrap/selfhost/check-a1-a2.sh OUTPUT` rejects missing, empty, stale,
or non-runnable output; `task selfhost-generations` runs both.

`sh bootstrap/selfhost/check-fixed-point.sh OUTPUT [BUNDLE]` closes the loop:
it consumes an existing validated bundle (or rebuilds one itself when no
`BUNDLE` is given), derives `C3/A3` from `A2(S)` twice in normalized clean
directories, asserts `C2 == C3` and `A2 == A3` byte for byte, runs the full
driver corpus through A3 against the bundle's promoted A1 observations, and
asserts the machine-independent digests recorded in
`bootstrap/manifest.json`'s `fixed_point_closure` entry against its own
measurements. `task selfhost-fixed-point` is the gate.

`sh bootstrap/selfhost/declare-inputs.sh OUTPUT` writes the acquisition set:
every file the chain reads, by role, with a content digest, plus the two set
digests the generation gates verify, the toolchain the recorded C digests came
from, and what a builder should conclude from a toolchain mismatch. It answers
the question `provenance.tsv` cannot — that file describes a build that already
happened in a checkout an independent reproducer is trying to establish rather
than assume.

`sh bootstrap/selfhost/check-declared-inputs.sh OUTPUT` refuses three classes
by name: a declared input **missing** from the checkout, one **altered**, and
an input the checkout carries that the manifest does not declare — **extra**.
The third is the one a digest list alone cannot catch and the one reproduction
depends on, because a build that silently reads an undeclared file is not
reproducible from the declared set however well every declared digest matches.
`task selfhost-declared-inputs` runs both.

That is the producer-owned half of B6. The reproduction itself — by a builder
that did not produce the evidence — stays open as #274, and diverse double
compilation (B7) stays open too.

The implementation order is
[#619](https://github.com/kofun-lang/kofun/issues/619) through
[#622](https://github.com/kofun-lang/kofun/issues/622), followed by the executable
generation gates in
[#271](https://github.com/kofun-lang/kofun/issues/271) and
[#272](https://github.com/kofun-lang/kofun/issues/272).
