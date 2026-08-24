# Native CLI action-binding profile v1

Normative schema: `kofun.native-cli-action-binding-v1/v1`.
Decision owner: Issue #1551. Selected: **Option A**, one static typed action
table. This profile records the binding boundary; it does not claim that a
user-defined action is executable today.

## Static binding

Each command names one current-file top-level function. Resolution records the
function's nominal `FunctionId`, never display spelling alone. The one admitted
conceptual signature is:

```kofun
fn action(
    take context: CliActionContext,
    read invocation: CliInvocation,
) -> CliActionResult
```

The declaration compiler resolves every target and exact type/mode before it
writes metadata or an application. A missing, imported, overloaded, generic,
capturing, wrong-mode, or wrong-result target is a build-time refusal naming
both command and target. Table rows are command declaration order plus resolved
`FunctionId`; runtime string lookup never decides which code executes.

## Invocation and result

`CliInvocation` contains the resolved command identity, up to four positional
`Text` values in declaration order, and up to eight tagged `Bool`/`Text` option
values in declaration order. Defaults are materialized before the call.
Unknown/duplicate options, missing values, extra positions, invalid UTF-8, and
limit overflow retain the existing exit-2 parser boundary. An action receives
no raw `argv`, option spelling map, ambient environment, TTY, descriptor, or
filesystem handle.

`CliActionResult` returns the affine context on every branch as `Ready` or
`Revoked`, a status in 0..125, and complete stdout/stderr `Bytes` values bounded
to 65,536 bytes each. Partial output is not success. The framework writes
stdout then stderr after the action returns; write failure has its own terminal
classification and cannot cause the action to run twice.

## Authority

`CliActionContext` contains only capabilities explicitly derived from the one
process `RootAuthority` and declared for that application. Possessing an action
function, CLI metadata, or a command-line spelling grants nothing. Environment,
terminal, filesystem, clock, entropy, process, and network access require their
own entitlement rows. This keeps package-manager commands from reintroducing
the shell driver's ambient authority under a callback name.

The four existing `greet`, `sum`, `env`, and `status` spellings remain source
compatibility shorthands, but implementation migrates each to a private Kofun
function on this same ABI. They do not retain a second runtime dispatch path.
The `env` and `status` functions therefore wait for their explicit context
capabilities rather than preserving ambient `envp`/TTY access as precedent.

## Build and target

The first target remains `linux-x86_64`. Other targets refuse before publishing
an application. The Kofun native emitter produces the bounded action code
image, and the framework performs internal static code-image composition with
the checked runtime template and action table. The final application build may
invoke no C compiler, assembler, linker, shell, or dynamic loader, and retains
no `PT_INTERP` or dynamic dependency.

Implementation remains blocked on the root/entitlement carrier and on an
executable aggregate ABI for `CliActionContext`, `CliInvocation`, and
`CliActionResult`. Those blockers are not papered over by a C callback.
`task native-cli-action-binding-decision` mutates the target, nominal lookup,
signature, bounds, result/authority return, compatibility migration,
toolchain-free publication, and no-claim boundary independently.
