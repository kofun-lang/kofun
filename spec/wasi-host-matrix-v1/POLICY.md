# wasm32-wasi-command1 host matrix policy v1

#26 requires at least two maintained hosts executing one versioned ABI. This
file says which two, how they are acquired, what is compared, and what happens
when one is missing. `hosts.json` is the same policy as data, and
`check.mjs` is the offline validator that holds them together.

Nothing here installs a host or runs a module. Runtime execution of the matrix
is a later child of #26; this is the contract that child implements.

## The selected option

**The #1098 pure oracle, plus a pinned Node using its built-in WASI
integration, plus a pinned Wasmtime using its maintained Preview 1 core-module
surface.** Recorded on
[#1294](https://github.com/kofun-lang/kofun/issues/1294) on 2026-08-14, with
both alternatives rejected:

- **Two JavaScript hosts** share an implementation heritage and do not give the
  implementation independence #26 asks for.
- **Wasmtime alone plus the oracle** fails the two-maintained-host criterion,
  because the oracle is not a maintained host.

## 1. Required hosts, and the oracle's role

| id | role | implementation | what its evidence is |
|---|---|---|---|
| `pure-oracle` | `differential-oracle` | in-tree | the answer every maintained host is compared against |
| `node` | `maintained-host` | `v8-node` | compatibility only |
| `wasmtime` | `maintained-host` | `cranelift-wasmtime` | compatibility only |

**The oracle is never one of the two.** The validator counts roles separately
and refuses a manifest where deleting the oracle leaves two maintained hosts,
because that manifest and a correct one would otherwise be indistinguishable.

**Two maintained hosts must be two implementations.** The `implementation`
field, not the `id`, is what must differ — two pinned builds of the same engine
are one implementation wearing two names.

## 2. Acquisition

Every maintained host pins an exact `MAJOR.MINOR.PATCH` version and, per
platform, an `https` URL and a 64-hex `sha256`. The URL must contain the pinned
version, so a manifest cannot claim one version and fetch another.

Current pins, recorded 2026-08-15:

- Node **24.19.0** — the release stream tracked here is Node LTS. Its WASI
  integration is what the matrix exercises.
- Wasmtime **47.0.3** — its `p1` layer is the maintained `wasi_snapshot_preview1`
  core-module surface.

Digests were taken from `nodejs.org/dist/v24.19.0/SHASUMS256.txt` and from the
Wasmtime release assets' own recorded digests.

## 3. Cadence and compatibility budget

Pins move only by pull request. The revisit triggers are a Node LTS transition,
a Wasmtime major, and a security advisory naming a pinned build.

A bump that changes any fixture outcome is a **profile question**, and the pull
request must say so. It is never a routine bump.

## 4. Lanes

Both maintained hosts are mandatory in the `linux-x86_64` lane, which
`hosts.json` names as `required_lane`. Any other platform lane is
informational until it has its own pins and its own evidence. The manifest
carries `linux-aarch64` artifacts for both hosts so that lane can be enabled
without a re-pin, and enabling it is a separate change.

## 5. Absence is failure

A required host that is missing, undownloadable, or digest-mismatched at gate
time is a hard failure naming the host. There is no skip path that produces a
green.

The validator enforces the structural half: `required: true` is the only
accepted value, so the policy cannot be weakened by adding a flag. A manifest
with an optional host is refused.

## 6. What is compared

`stdout`, guest-produced `stderr`, exit status, trap class, manifest-refusal
outcomes, and artifact digest identity — the same module bytes are fed to every
host. Host-owned diagnostics are never compared.

Dropping any one of those from `compared_observations` is refused.

## 7. Security wording

Passing this matrix is **compatibility evidence only**. It establishes no
sandbox, isolation, or safety property, and no release claim may cite it as
one.

Each host declares `security_claim`, and `none` is the only accepted value.
This is a field rather than a scan of the prose for forbidden words: the first
version of the rule scanned, and it refused the shipped manifest, because
Node's own note says its WASI is *"not a secure sandbox"* — a rule that fires
on the sentence disclaiming the claim teaches the author to delete the
disclaimer.

## 8. Retirement

Either pinned host deprecating or dropping `wasi_snapshot_preview1` support in
the release stream tracked here **freezes pin bumps** until a revised matrix
policy is accepted — a component-model migration, or a replacement host. Until
that trigger fires, component-model work stays out of scope.

`hosts.json` records the trigger, and a manifest without one is refused.

## 9. Distinct roles, so evidence is not borrowed

- the **pure oracle** is the differential oracle for this target;
- the **browser sample** is core-`wasm32` evidence and says nothing here;
- **`wasm32-hostabi1`** is its own profile with its own gates;
- this matrix covers **`wasm32-wasi-command1`** only.

## The gate

```sh
task wasi-host-matrix-policy
```

It validates the manifest offline and then runs 17 mutations, requiring each to
be refused **by its own reason**. That last clause is a rule about the rules:
when two mutations produced one message, the digest check was splitting neither
"forgotten" from "typed wrong", and a reader of the refusal could not tell which
fix they needed. Sharing a reason is treated as a defect in the checker, not as
a pass.

Offline is deliberate. #1294 allows the CI lane to reuse cached binaries; what
must not depend on the network is the proof that the manifest pins something a
fetcher could verify.
