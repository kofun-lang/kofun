# Shell verdict audit

This is the #1554 sweep of shell status values that can be confused with
failure by `set -e`. It was measured at
`2d3aef9215b4a930827dff997418f7ebceb9cb61`.

## Scope

The sweep covers all five tracked `tooling/**/*.sh` files:

- `tooling/compile-census/check.sh`
- `tooling/forbidden-requirements/fixtures/mention-and-invoke.sh`
- `tooling/kotest/run.sh`
- `tooling/lsp/build-semantic-bundle.sh`
- `tooling/machine-dependent/check.sh`

It also checks the two shell gates that directly execute those scripts,
`tests/lsp/check.sh` and `tests/stdlib/kotest/check.sh`. They are callers, not
harnesses launched by `tooling/`. The kotest runner launches `bin/kofun`, but
that shell entrypoint is an explicit exclusion in #1554.
`tests/tooling/verify-object-reuse/check.sh` mentions the LSP builder only as
text inspected by `grep`, so it is not an execution path.

The sweep does not cover `bin/kofun`, `bootstrap/**`, unrelated `tests/**`, or
shell files outside these direct paths. The forbidden-requirements file is a
detector fixture, not a gate; it remains in the inventory so its command
substitution cannot be mistaken for an omission.

## Status used as data

| producer | status | consumer | verdict |
| --- | --- | --- | --- |
| `tooling/kotest/run.sh:318-397` (`run_unit`) | `3` at line 336 means no selected tests; `2` at lines 344, 374, and 382 classifies a build error; the compiled suite's status is captured at lines 385-388 and returned at line 396 | the sole call is `if run_unit ...; then ... else unit_status=$?; fi` at lines 431-435, followed by the status `case` at line 436 | safe: the command is in a POSIX tested context, so `set -e` cannot consume the data status; the adjacent comment names #1554 |

There are no unguarded occurrences and therefore no unsafe site to rewrite.

## Near matches reviewed

| site | why it is not the defect |
| --- | --- |
| the four tooling `ROOT=$(...)` initializers | output is path data, but a nonzero status is a real initialization failure |
| `tooling/lsp/build-semantic-bundle.sh:19-22,48` | Node prints a path and `uname` prints a platform; a nonzero status is failure, not a third verdict |
| `tooling/forbidden-requirements/fixtures/mention-and-invoke.sh:43-45` | Node prints a version and failure is failure; this file is included here, though the forbidden-requirements production census excludes its detector-fixture directory |
| `tooling/kotest/run.sh:81-83,168-169,181,321,401-402,448-459,481,496-500` | the substitutions collect text, sizes, paths, or counts; nonzero means failure rather than a data verdict, and the `awk` fallback at lines 448-459 is explicitly guarded by `||` |
| `tooling/kotest/run.sh:400-477` (`run_pass`) | its return is the runner command's success/failure, not a multi-valued verdict; watch mode invokes it in `if` at line 492 and the normal path invokes it as the final command at line 506 |
| `tests/stdlib/kotest/check.sh:116-120,153-157,179-184,243-260,324-331` | expected failing runner statuses are captured between `set +e` and `set -e`; both `grep -c` count substitutions guard the zero-match status with `|| :` |
| `tests/lsp/check.sh:4,7,25` | path and revision output are data; the builder is a must-succeed command, so nonzero is a gate failure |
| `tooling/compile-census/check.sh`, `tooling/machine-dependent/check.sh` | neither defines a status-returning function nor reads `$?` |

## Fixed-site proof

The unsafe occurrence fixed by #1512 is outside this sweep and remains the
real-call regression for this defect class. `stdlib/check-capabilities.sh:154-174`
prints `live`, `closed`, or `unchecked` on stdout and returns only success.
`newer_than_snapshot` at lines 344-357 calls it through the production shape,
`newer_decided=$(validate_liveness ...) || fail`; its comment explains why a
tested-context-only check would pass the broken implementation. `task
capabilities` executes that proof on the same `sh` path used by CI. Because the
sweep found no unsafe site, it records that zero honestly instead of creating a
synthetic fix merely to duplicate this proof.
