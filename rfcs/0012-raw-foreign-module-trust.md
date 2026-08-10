# RFC-0012: A raw foreign binding is classified by its source, and crossed once explicitly

- Shepherd: hjosugi
- Opened: 2026-08-10
- Status: accepted
- Decided: 2026-08-10

Proposal for [#902](https://github.com/kofun-lang/kofun/issues/902), the
raw-import boundary child of [#574](https://github.com/kofun-lang/kofun/issues/574).
This proposal records target semantics only. No generator, parser, module
table, KIF field, import rule, diagnostic, or release capability is implemented
by it.

Measured against `origin/main@1c27baa8`.

## Summary

A module that holds generated raw C bindings says so **in its own source
bytes**, on a `trust` line in its module header, and no ordinary import can
name it. One contextual form, `trusted import`, admits it into exactly one
importing module, and that admission does not propagate: re-exporting a raw
module, or any declaration that originates in one, is refused.

The classification is a parsed semantic fact carried into the module table and
into KIF as a required field. It is not the filename, not the banner comment,
and not the `.bindgen.json` report — those remain audit evidence. Renaming
`kbfix.raw.kofun` to `kbfix.kofun`, or copying it next to safe code, changes
nothing about what the compiler will let you do with it.

## Motivation

The Stage 1 generator already emits `NAME.raw.kofun` with a banner and the
comment `trust: raw-trusted-foreign`, and a `NAME.bindgen.json` report carrying
the same string and the module digest.
`sh tests/interop/bindgen-c/check.sh` is green and proves deterministic
generation, ABI/layout/calling-convention probes, C-ABI execution, sanitizer
instrumentation, and a 42-case adversarial macro corpus.

None of that is a boundary. Measured on the audited commit:

```sh
git grep -l 'raw-trusted-foreign' -- ':!graphify-out/**' | wc -l
# 8 — the generator, its tests and docs, and release evidence

git grep -niE 'raw-trusted-foreign|raw-foreign|trusted import' -- \
    bootstrap/stage2 spec/modules tests/conformance/modules/kif-v1 | wc -l
# 0 — no parser, module table, KIF writer or reader, import resolver,
#     or re-export resolver consumes it as semantic authority
```

So today the marker is a comment, `.raw.` is a filename convention, no module
or KIF record carries a trust class, ordinary imports cannot tell a raw binding
from a safe module, and `tests/interop/bindgen-c/import-boundary/` does not
exist. Copying or renaming the generated source silently converts raw bindings
into an ordinary module with no diagnostic. The executable driver in the
existing fixture is concatenated after the generated declarations rather than
importing them, so nothing has ever exercised an import of a raw module.

No ledger row owns this: 0 of the 36 recorded decisions names a raw-binding
trust class, grammar, KIF encoding, or import crossing.

## Detailed design

### 1. Trust authority: the source

The module header gains an optional second line:

```kofun
module ffi.kbfix
trust raw-foreign
```

`trust` is a **contextual keyword**, valid only on the line immediately
following a `module` header. Its value is drawn from a closed set. v1 defines
exactly one value, `raw-foreign`. An unknown value is a syntax error, not a
forward-compatible unknown — a trust class the compiler does not understand may
not be treated as absent.

Absence of the line means the module is ordinary. That default is safe under
this design precisely because the classification lives in the bytes: the
failure mode #902 names — a generated binding losing its class when copied or
renamed — cannot occur, because the copy carries the line.

This composes with DD-025 rather than competing with it.
`spec/modules/source-file-mapping.md` already makes the explicit source `module`
header the sole module-path authority for manifest sources and refuses to
repair a missing or misplaced header from the filesystem path. Trust joins that
same authority, on the same header, under the same refusals: multiple `trust`
lines in one file, a `trust` line not attached to a module header, and a
`trust` line in an anonymous source are syntax errors, and none may be repaired
from the path.

### 2. The crossing

```kofun
trusted import ffi.kbfix
```

`trusted` is a contextual keyword valid only immediately before `import`. It is
the only form that may name a module whose trust class is `raw-foreign`, and it
is valid **only** when the named module actually carries that class — writing
`trusted import` for an ordinary module is refused, so the marker cannot become
decorative noise that a reader learns to skip.

### 3. Anonymous mode

Raw extern declarations are **always refused** in anonymous single-file mode.

This falls out of DD-025 rather than being invented here: an anonymous source
must not contain a module header, so it has nowhere to carry a trust class, and
this proposal refuses to infer one from a path. There is therefore no way to
compile a raw binding except as a declared manifest source, which is also the
only mode in which anything could import it.

### 4. KIF contract

`spec/modules/module-identity.md` already has the mechanism. KIF fields are
`tag:u16be`, `length:u32be`, then bytes; tags strictly increasing; **a tag with
bit `0x8000` set is required**, and an unknown required tag rejects the artifact
with a rebuild instruction.

The active envelope gains required tag **`0x800A`**, the next free required tag
after `0x8001`–`0x8009`, carrying the trust class as canonical UTF-8 text from
the closed set.

Three refusals, all closed:

- **Unknown value** in `0x800A` — reject. A reader may not skip it; it is a
  required tag.
- **Absent `0x800A`** in an artifact the active envelope requires it in —
  reject as rebuild-required. Absence is explicitly **not** "safe": that is the
  one downgrade this whole proposal exists to prevent, and the required-tag rule
  already gives it for free in the other direction, since an old reader meeting
  `0x800A` also rejects rather than ignoring it.
- **Contradiction** between the source's `trust` line and the artifact's
  `0x800A` — reject. Neither side wins; the artifact is rebuilt.

The field participates in **both** semantic digests, so changing a module's
trust class invalidates its interface digest and every dependent's cached view
of it. A trust change is an interface change.

### 5. Propagation

The crossing is **façade-local**.

- `trusted import` admits the raw module into exactly the module that writes it.
- Ordinary qualified, aliased, and selective imports of a `raw-foreign` module
  are refused.
- **Re-export is refused** — of the raw module, and of any declaration whose
  origin is a raw module. A façade exports only its own reviewed declarations,
  which are ordinary declarations that happen to call raw ones.

So trust never forwards. A downstream consumer of the façade cannot acquire the
crossing transitively, and cannot discover from the façade's interface that a
raw module exists behind it.

## Semantics

A program is well-formed under this proposal when every reference to a
declaration originating in a `raw-foreign` module occurs in a module that
itself wrote `trusted import` for that module.

- **Classification is a parsed fact.** It is established from the source bytes
  at inventory validation, before the module table is committed, and it is
  transactional with the rest of header validation.
- **Classification is not transitive.** A module that `trusted import`s a raw
  module is itself ordinary unless it declares its own `trust` line.
- **Trust is not an effect.** It does not appear in signatures, does not
  propagate through calls, and constrains nothing about what the declarations
  do. It constrains only who may name them.

Deliberately left undefined: any trust class other than `raw-foreign`; whether
a façade may be required to be reviewed by tooling; whether the crossing may be
narrowed to individual declarations rather than a whole module; and any
relationship to a future language-wide unsafe/trusted effect, which this
proposal does not create and does not foreclose.

## Diagnostics

Every refusal below is new. **Stable codes are allocated in
`tests/diagnostics/registry.tsv` at implementation time, not here** — #902 asks
for exactly that, so concurrent work on other slices does not race for numbers.
Each must name the raw `ModuleId` and display path, the attempted import form,
the source span, and the exact explicit remedy.

| Situation | Refusal |
|---|---|
| ordinary, aliased, or selective import of a `raw-foreign` module | refused, naming `trusted import` as the remedy |
| re-export of a raw module, or of a declaration originating in one | refused; no remedy — a façade re-exports its own declarations instead |
| `trusted import` naming a module that is not `raw-foreign` | refused |
| unknown value on a `trust` line | syntax error |
| duplicate or unattached `trust` line, or one in an anonymous source | syntax error |
| raw extern declarations in anonymous single-file mode | refused |
| KIF `0x800A` unknown, absent where required, or contradicting the source | rejected, rebuild-required |

Failure writes no KIF, typed sidecar, object, executable, cache success, or
partial module table.

## Ownership and effects

No interaction with `read`/`edit`/`take`, affine resources, or the effect
discipline. Trust classifies a *module*, not a value and not a computation, and
carries no obligation into any signature. A raw declaration's ownership modes
are whatever it declares.

## Alternatives

**Candidate B — a manifest source-role field.** Rejected. It avoids a second
header row, and reuses the authored/generated source roles the manifest already
has, but the classification is lost the moment a generated source is copied or
compiled outside that manifest entry. That forces a separate anonymous-source
and raw-extern refusal rule to close the hole, and it pushes toward treating a
physical location as authoritative — which #902's own "Rejected representation
class" forbids, and which DD-025 already refuses for module paths. Two
authorities for facts about one source is the drift this repository gates
against everywhere else.

**Keep the comment and the `.raw.` filename.** Rejected, and it is the status
quo. Both are audit evidence and stay; neither survives a rename.

**A language-wide `unsafe`/`trusted` effect.** Rejected as this issue's scope.
It is a much larger decision about the effect discipline, it would need to
answer propagation through calls rather than through imports, and #902
explicitly does not own it. Nothing here forecloses it.

**Do nothing.** Rejected: the marker keeps reading as a boundary while a rename
converts raw bindings into a safe module with no diagnostic, and #574 stays
blocked on a boundary nobody may build.

## Drawbacks

The module header grows a second row, which every module-header parser, the
module table, and the KIF writer and reader must learn. That is the cost of
choosing the source as the authority, and it is paid once.

`trust` and `trusted` become contextual keywords. They collide with nothing
today, but they narrow the space of future syntax at the start of a line.

A required KIF tag makes every existing artifact rebuild-required. KIF artifacts
are build outputs, so this is a rebuild rather than a migration, but it is not
free on a large tree.

The `trusted import` form is per-module, not per-declaration, so a façade that
needs one raw function admits the whole raw module. Narrowing it is left open
above.

## Compatibility and migration

`additive`. No tracked program changes meaning and none stops compiling.

Every construct is new surface: the `trust` header line, the `raw-foreign`
class, the `trusted import` form, KIF required tag `0x800A`, and the refusals
above. Nothing that compiles today acquires a trust class, because absence of
the line means ordinary, and no tracked source writes the line.

The one non-source effect is that KIF artifacts rebuild once, which the
required-tag rule already handles by construction: an old reader meeting
`0x800A` rejects with a rebuild instruction rather than misreading it, and a new
reader meeting an artifact without it rejects rather than assuming safe.

Migration: the generator emits the `trust raw-foreign` line and a declared
module path in its output, and the existing bindgen fixture's concatenated
driver becomes two real modules — generated raw bindings plus a hand-written
façade that writes `trusted import`.

## Implementation plan

Acceptance commits to no schedule. When it is built, the order is:

1. the `trust` header line parsed and validated at source inventory, refused
   transactionally, with no module table committed on failure;
2. KIF required tag `0x800A`, its three refusals, and its participation in both
   digests;
3. `trusted import` accepted, and ordinary/aliased/selective imports of a raw
   module refused;
4. re-export refusal, including declarations originating in a raw module;
5. the generator emitting the line and the report recording the same class;
6. the fixture split into raw bindings plus a reviewed façade.

Steps 1–2 are separately reviewable and land first. Diagnostic codes are
allocated as each step lands.

## Validation

The gate is a new `tests/interop/bindgen-c/import-boundary/` target, included in
`task verify`. Its positive case is a façade that writes `trusted import`,
builds through the existing C ABI, and runs.

The boundary is proved negatively, and the negative cases are the point: an
ordinary import, an aliased import, a selective import, and a re-export of the
raw module must each fail with their registered code and write no artifact; and
**a renamed copy of the generated source, with `.raw.` removed, must still be
refused by an ordinary import** — that is the fixture that distinguishes this
design from the status quo, and a version of this gate that omits it proves
nothing this proposal adds.

Existing gates that must stay green: `sh tests/interop/bindgen-c/check.sh`,
`sh spec/source-file-mapping/check.sh`, `sh spec/module-identity/check.sh`,
`task imports-qualified`, `task imports-selective`, `task re-exports`,
`task kif-v1`, `task diagnostics`, and `task verify`.

This proposal records no `implementation` in the ledger, because nothing is
implemented.

## Unresolved questions

- **Whether the crossing should be narrowable to individual declarations.**
  Left open above; settled by the first façade that finds whole-module admission
  too coarse.
- **Whether any trust class other than `raw-foreign` is ever wanted.** The set
  is closed at one value deliberately; a second value is a further decision, and
  the unknown-value refusal is what keeps that decision from being made by
  accident.
- **Whether tooling should verify a façade was human-reviewed.** Out of scope:
  this proposal makes the crossing explicit and greppable, which is the
  precondition for any such check, but defines none.
