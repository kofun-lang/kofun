# Bounded affine resource handle

This gate implements the deliberately narrow checkpoint accepted by RFC-0010
for issue #784. It is a per-type protocol, not a general ownership pass and not
environment authority.

`transport.kofun` declares one `AffineTransport` nominal record and exactly
five ordinary transition functions:

| Transition | Parameter mode | Result | Successor |
|---|---|---|---|
| `read` | `read` | observation | same handle remains live |
| `write` | `take` | `AffineTransport` | generation + 1 |
| `drain` | `take` | `AffineTransport` | generation + 1, reusable |
| `close` | `take` | copyable `TerminalSummary` | none |
| `cancel` | `take` | copyable `TerminalSummary` | none |

The source executes twice: the standalone record evaluator is the reference
backend, and the production Stage 2 compiler emits strict C11 from the same
types and transition bodies. The reference evaluator does not implement
`print`, so the gate removes only `main` from a temporary copy before asking it
to evaluate every zero-parameter observation. The executable C11 output and
the checked reference `.run` artifact pin the same values.

The static boundary uses the existing record move diagnostic. Three production
fixtures prove use after a write-shaped move, a second terminal transition,
and a read after cancellation all fail as registered `E2S123` observations,
with no C artifact.

`runtime_model.c` owns the host-boundary generation backstop that ordinary
Kofun source cannot forge. It executes the same normal observations, then has
two adversarial lanes: a stale generation and two copies of one initial handle.
The first copy advances the resource; the second is no longer live. Both lanes
exit 1, publish no stdout, and write exactly:

```text
EARH01: affine resource handle already consumed
```

This is the only new diagnostic identity. `E2S122` and `E2S123` retain their
existing meaning and owner. The generation backstop does not imply that the
compiler implements general alias, branch, loop, lifetime, or cleanup
analysis; it bounds one declared type crossing one scripted host boundary.

Run the lasting gate with:

```sh
task affine-resource-handle
```
