# Package artifacts v1

Kofun's first package-manager slice resolves exact external native-library
artifacts without a central registry. It is deliberately aligned with the
external-code boundary that the compiler implements today: an explicit C ABI
static library. It does not claim source-package builds, semantic versions, or
transitive dependency resolution.

## Declare and lock

Create `kofun.packages.toml` beside the command's working directory:

```toml
format = 1

[dependency.answer]
source = "https://example.invalid/releases/libanswer-x86_64.a"
kind = "static-library"
```

`file:relative/path/libanswer.a`, `file:/absolute/path/libanswer.a`, and HTTPS
sources are supported. There is no package-name lookup or registry fallback;
the source is always explicit. The current parser accepts only the fields and
simple quoted values shown above and rejects escape sequences and unknown
syntax.

Resolve the bytes and generate `kofun.packages.lock`:

```sh
kofun package lock
```

The generated lock repeats the exact source and records its SHA-256. Commit
both files. Relocking fetches each declared artifact, verifies its bytes, puts
it in the cache, sorts packages by name, and writes the lock atomically.

## Fetch, use, and work offline

```sh
kofun package fetch
kofun build app.kofun --backend c --c-abi \
  --package answer -o app
```

`--package` looks up the locked dependency, verifies the cached bytes, fetches
only on a cache miss, and supplies the resulting library as an ordinary
argument to the host linker. It requires the explicit C ABI profile; packages
cannot silently switch a direct-native build to host C.

Cache objects live at:

```text
${KOFUN_PACKAGE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/kofun/packages}/sha256/<hash>
```

Once populated, network and source files are unnecessary:

```sh
kofun package fetch --offline
kofun build app.kofun --backend c --c-abi \
  --package answer --offline -o app
```

Offline mode fails on a cache miss. Every use recomputes SHA-256; corrupt cache
bytes fail instead of being trusted by path. A non-offline fetch also fails if
newly fetched bytes differ from the lock rather than silently rewriting it.

**What an interruption guarantees** (#1463). An entry is published by hard link
from a temporary in the same directory, so a partial file never occupies a final
name, whatever kills the process — `link(2)` has no partial state and `SIGKILL`
runs no handler either way. Two processes fetching the same package do not
coordinate and do not need to: the name is the digest, so the second `ln` fails
`EEXIST` and that process verifies the entry the first one published instead of
overwriting it.

What an interruption does leave is a `.tmp.*` file in the cache directory.
Nothing removes it today and there is no `clean` subcommand; that, and making a
digest mismatch recoverable rather than fatal, are #1457's.

## Current boundary

- `kind = "static-library"` is the only artifact kind.
- Resolution is direct and one level: no registry, version ranges, transitive
  dependencies, install scripts, extraction, or package-provided build steps.
- A lock pins artifact bytes, not the host compiler, linker, target ABI, or the
  behavior of foreign native code. Reproducible final native binaries therefore
  still require a pinned compatible toolchain.
- The static library is trusted native code and remains outside Kofun's
  memory-safety guarantees.

These constraints keep resolution a sorted lock scan plus SHA-256 cache lookup,
make offline behavior auditable, and avoid adding a runtime or Python
dependency.

## Target guidance: a core package and an adapter package

> **Not implemented.** This is guidance for when source packages exist,
> recorded with [RFC-0019](../rfcs/0019-dependency-foreign-grants.md). Today the
> resolver reads only `format = 1` native artifacts. It has no source packages
> and no grants.

Under RFC-0019, a consumer gives each dependency a grant: `plain`, the default,
or `foreign`. A `plain` package may contain no foreign code. That means no
`trust raw-foreign` module, no `extern "C"` declaration, and no native
artifact. No package can grant more than it was given.

A library that needs foreign code should ship as two packages:

| Package | Holds | Grant |
|---|---|---|
| core | the library's logic; it takes the RFC-0014 authority values it needs as parameters | `plain` |
| adapter | the `trust raw-foreign` module, its `extern "C"` declarations or native artifact, and the reviewed façade over them | `foreign` |

**The core never depends on the adapter.** A `plain` package cannot grant
`foreign`, so a core that depended on its adapter would need `foreign` itself.
The adapter may depend on the core. The application depends on both. It is
always `foreign`, so it can grant `foreign` to the adapter, and it connects the
two.

The split keeps most of the code where a `plain` grant checks it. A consumer
grants `foreign` only to the small adapter, which is the part worth reviewing.
A consumer who does not trust that adapter can write their own and keep the
core.
