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
