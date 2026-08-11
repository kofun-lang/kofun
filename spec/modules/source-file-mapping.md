# Source files, module declarations, and stable identities

Status: accepted normative design for GitHub issue #300.

This document fixes the authority that maps manifest source files to semantic
modules and defines the versioned inputs for `FileId` and `ModuleId`. It builds
on [`package-roots.md`](package-roots.md); a compiler must select one package
before applying this contract.

The words **must**, **must not**, **should**, and **may** are normative.

## Decision

Kofun chooses an explicit module declaration as the sole authority for a
manifest source file's module:

~~~kofun
module user.service
~~~

The manifest is authoritative for which logical source files belong to the
package. The source header is authoritative for the module path. A directory,
filename, source root, current working directory, or discovery order never
supplies a fallback module name.

This is option B from #300. Path-derived, manifest-mapped, and hybrid module
identities are rejected because they either make file moves semantic renames
or introduce two competing authorities. Tooling may lint a path convention,
but a lint cannot change `ModuleId`.

| Option | Refactor stability | Reproducibility | Discovery/readability | Tooling/generated sources | Beginner cost | Decision |
| --- | --- | --- | --- | --- | --- | --- |
| path-derived | file moves rename modules; poor | host case/path rules leak unless heavily normalized | familiar tree | generators must imitate a tree | low initially, hidden move cost | reject |
| explicit header | module survives file moves; strong | source spelling is host-independent | readable in every file | one parser authority; generated files declare intent | one short header | **accept** |
| manifest mapping | module survives moves; strong | manifest can be canonical | source is opaque alone | large mappings and generators centralize churn | high manifest overhead | reject |
| path plus optional assertion | still path-coupled | two apparent authorities can disagree | familiar but ambiguous | tooling must reconcile both | moderate and surprising | reject |

The explicit header is the only option that keeps source identity readable,
supports nonstandard/generated layouts, and separates a physical file move
from an API rename without adding a second semantic mapping table.

## Source modes

Every source is interpreted in exactly one mode selected before parsing:

| Mode | Source inventory authority | Module authority |
| --- | --- | --- |
| manifest package | the selected manifest's explicit source list | required source `module` header |
| anonymous single-file package | the explicit CLI source operand | one synthetic root module |
| generated manifest source | a declared build action output | required source `module` header |

A manifest source requires one module header even when it is the package's only
source. An anonymous single-file source must not contain a module header in v1;
it always belongs to the synthetic root. This prevents a direct source from
appearing importable or acquiring a different identity because of nearby
project state.

Wildcard discovery, implicit source roots, directory modules, index files, and
multi-source direct mode are unsupported.

## Module header grammar and position

The header grammar is:

~~~text
module-header := "module" module-path NEWLINE
module-path   := identifier ("." identifier)*
~~~

`module` is contextual at the first non-comment token of a manifest source; it
is not added to the general hard-keyword set by this decision. Blank lines and
line comments may precede the header. Nothing else may precede it, and imports
and ordinary declarations follow it. A second or late header is an error.

Each path component follows the Unicode 15.1 XID/NFC identifier contract in
`spec/syntax/FOUNDATIONS_AND_CONTROL.md` and must not equal a hard keyword or
the discard identifier `_`. Escapes, empty components, leading/trailing dots,
and whitespace around a dot are invalid. Equality is scalar-for-scalar after
requiring source spelling to already be NFC; host filesystem case folding is
irrelevant.

The fixed v1 limits are 64 components, 255 UTF-8 bytes per component, and
4,096 UTF-8 bytes for the complete module path. Crossing a limit is a source
diagnostic, never truncation. The current bootstrap lexer remains ASCII-only;
this document does not claim executable Unicode module parsing.

## Identity terms

- `PackageIdPayload` is the selected package identity from
  `package-roots.md`.
- A **logical source path** is the validated package-relative `/` path from
  that contract.
- A **source role** is either authored or generated.
- A **provenance key** identifies the manifest inventory or a deterministic
  generator action without using a host path, process ID, or timestamp.
- `FileId` identifies one declared source input.
- `ModuleId` identifies one semantic module in one package.

The payloads below are canonical identity inputs. #303 owns the production
digest algorithm and encoded ID width. The SHA-256 values in the reference gate
are regression fingerprints only and do not pre-decide #303.

## FileId input

The canonical field order is:

~~~text
kofun.file-id-input/v1
package-payload-begin
<exact canonical PackageIdPayload bytes>
package-payload-end
logical-path=<validated logical path>
source-role=authored|generated
provenance=<normalized stable provenance key>
~~~

For an authored manifest file, `provenance=manifest-source`. For an anonymous
source, `provenance=explicit-source`. A generated source uses
`source-role=generated` and a producer-provided stable action key. A generated
key must be derived from declared semantic/action inputs; it cannot contain an
absolute path, clock value, random value, or process identity.

A generated provenance key is valid UTF-8 already in NFC, contains no control
scalar, newline, backslash, URI scheme, absolute prefix, or empty/`.`/`..` path
component, and is at most 512 UTF-8 bytes. `/` separates its semantic producer
and output components. These bytes are compared exactly; environment expansion
and host path canonicalization are forbidden.

The logical path participates in `FileId`. Moving or renaming a file therefore
changes `FileId`, even when its bytes and module declaration are unchanged.
Contents, mtime, inode, checkout root, target triple, optimization flags, and
source-list position are excluded.

Authored and generated provenance namespaces cannot collide. Repeating the
same complete FileId input is a duplicate-source error rather than two files
sharing one ID.

## ModuleId input

A declared manifest module uses:

~~~text
kofun.module-id-input/v1
package-payload-begin
<exact canonical PackageIdPayload bytes>
package-payload-end
kind=declared
module-path=<normalized declared module path>
~~~

The anonymous root uses:

~~~text
kofun.module-id-input/v1
package-payload-begin
<exact canonical anonymous PackageIdPayload bytes>
package-payload-end
kind=synthetic-root
~~~

`ModuleId` excludes the source path and source role. Moving an authored or
generated file leaves `ModuleId` unchanged when its package and declaration are
unchanged. Renaming the declared module changes `ModuleId` and is a semantic API
rename. The same path in two different packages produces different IDs.

## Uniqueness and partial modules

V1 requires exactly one source file per `ModuleId`. If two authored/generated
files declare the same module path in one package, compilation reports both
logical paths in canonical `FileId` order and fails before body resolution or
artifact emission. Different provenance does not create a partial module.

This deliberately rejects partial modules, including a generated file trying
to augment an authored module. A future partial-module design requires an
edition/schema change and must define declaration ordering, initialization,
visibility, and incremental invalidation first.

Multiple module headers in one file, a missing/late header, and a header in an
anonymous source are syntax errors. None may be repaired from the filesystem
path.

### Module trust

The header may carry one optional second line, on the line immediately
following it:

```kofun
module ffi.kbfix
trust raw-foreign
```

`trust` is a contextual keyword: a keyword on that one line, and an ordinary
identifier everywhere else, including as a declaration name. Its value is drawn
from a closed set, and v1 defines exactly one, `raw-foreign`. Absence means the
module is ordinary.

Trust joins this document's authority rather than sitting beside it, and under
the same refusals. A duplicate `trust` line, a `trust` line separated from its
header by a blank line, a `trust` line elsewhere in the file, a value outside
the closed set, text after the value, and a `trust` line in an anonymous source
are all syntax errors. **None may be repaired from the filesystem path** — a
class a path could supply is a class a rename could change, which is the
failure RFC-0012 exists to close.

Two refusals are worth stating as rules rather than leaving to be inferred.

An unknown value is a syntax error and **not** a forward-compatible unknown. A
trust class a reader does not understand may not be treated as absent, because
absent is the permissive reading.

`raw - foreign` is not a second spelling of `raw-foreign`. One class with two
spellings is a class two readers can disagree about, so the value is admitted
only as adjacent bytes.

The validated inventory records the class for **every** module, ordinary
included. A field that appeared only when set could not distinguish an ordinary
module from one written by a producer that did not know about trust, and those
must not read alike.

RFC-0012 defines the rest of the design — the `trusted import` crossing and KIF
tag `0x800A` — and neither is implemented by this rule.

## Stable inventory and serialization

After every source has a validated `FileId` and `ModuleId`, consumers process
the inventory in ascending canonical `ModuleId` bytes and then canonical
`FileId` bytes. Manifest order, directory enumeration, parallel parse
completion, and hash-map iteration never determine observable order.

Diagnostics that mention multiple files use this same order. Serialized HIR,
compiled interfaces, dependency edges, and LSP indexes carry both IDs and the
logical path for display. They must not reconstruct a module path from that
display path.

Changing the absolute checkout directory while preserving the package payload,
logical paths, roles, provenance keys, and headers produces byte-identical
identity inputs and inventory ordering.

## Diagnostics and transaction boundary

A mapping failure reports the logical path, relevant header/component span,
failed rule, and one safe remedy. Duplicate-module diagnostics report both
headers. A diagnostic may include an absolute path only as optional local debug
detail; serialized output never includes it.

The compiler validates the complete source inventory before committing a
module table, reusable interface, object, executable, or cache success. Limits
and duplicate checks are deterministic and cannot leave a partial module graph.

## Compatibility

The first payload line is a schema domain. Changing field meaning, order,
normalization, anonymous-root semantics, or partial-module policy requires a
new domain or edition migration. Readers reject unknown required domains and
request a rebuild; they do not guess a path-derived identity.

File moves invalidate file-local diagnostics and facts keyed by `FileId` but do
not rename the module. Module declaration changes invalidate module consumers.
#301 defines dependency invalidation, while #303 defines semantic interface and
ABI digests.

## Implementation status and non-goals

`spec/source-file-mapping/check.sh` executes canonical identity-input,
path-remap, move/rename, uniqueness, header-shape, generated/authored, and
ordering examples. The focused `module_symbols.c` checkpoint can consume
already-validated IDs for several distinct one-file modules and re-enforces
the V1 duplicate-`ModuleId` boundary; it does not discover or validate a
manifest graph itself. The active compiler still consumes one explicit source.
Passing either gate is not a claim that imports or cross-module resolution are
implemented.

This contract does not define imports, re-exports, package dependencies,
workspaces, source fetching, wildcard discovery, partial modules, module
initialization, LSP rename behavior, production ID hashing, or cache eviction.
No source-to-module mapping question remains open after this decision.
