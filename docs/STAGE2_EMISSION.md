# Working on Stage 2 emission issues

Start with the issue reproducer through `bin/kofun build`, including
`--emit-c PATH`. A successful syntax, inference, or sidecar check alone does
not prove that the emitted C compiles. `task emission-compiles` classifies every
tracked Kofun program and requires its exception ledger to match in both
directions.

The canonical pair is `bootstrap/stage2/compiler.kofun` and `compiler.c`.
Update both under the resource ownership rules in
[CONCURRENT_AGENTS.md](CONCURRENT_AGENTS.md). The C file is a maintained seed;
round-tripping the Kofun file does not execute its lowering logic.

| Change | Shared implementation point | Focused gate |
| --- | --- | --- |
| Whether a binding is used | `binding_has_use` reads resolved HIR BindingIds | `task unused-function` |
| C references for unused parameters and scalar/constructor locals | `unused_binding_discard`; callers retain initializer evaluation and cleanup | `task unused-function` |
| A lambda binding used as a value | `emit_primary` selects its lifted function symbol | `task unused-function hm-levels call-arguments` |
| Whole-carrier Bytes return | `emit_bytes_return` owns failure cleanup, transfer, then success cleanup | `task bytes-carrier bytes-mutation` |
| A temporary passed to a Bytes parameter | `emit_argument` requires `bytes_named_carrier_binding` before taking an address | `task bytes-carrier` |
| Which positional calls consume a binding | `call_argument_parameter_property` resolves the slot; `move_positional_binding` and `move_positional_owner` bound direct calls and owning types | `task move-call-crossings` |
| Whether a later name is the moved value | `move_same_binding` compares HIR BindingIds for every move spelling | `task move-call-crossings records call-arguments` |
| Trivial-record `edit` in the by-value ABI | `move_trivial_record` defines the shared type bound; `validate_move_record_modes` refuses the declaration | `task move-call-crossings` |

The discard helper does not decide whether a construct may lower, erase an
initializer, or change ownership. It is called after a declaration exists in
the current C scope. Other aggregate declaration paths still have their own
lowering; when extending one, explicitly check the unused-value case.

The Bytes helper accepts the lowered whole-carrier expression and the current
live-owner cleanup sequence. It checks `kofun_failed` before the move, while
all allocations still belong to named bindings. `kofun_bytes_take` only copies
fields and clears the source. The subsequent cleanup therefore skips the
moved-from storage and releases the other owners before returning the result.
If a future return form can fail while evaluating its address, first lower
that evaluation into a checked temporary; the whole-carrier invariant would
otherwise no longer apply.

The positional move helpers are not a general ownership pass. Their new slice
is a bare owning Bytes or Int/Bool-only nominal record passed to a direct,
resolved current-file `take` parameter in straight-line source order. They
exclude lexical/member/indirect callees, borrowed arguments, authority and
composite types, and conditional/loop crossings. Existing labelled and
pipeline rules keep their earlier scope. A crossing invalidates the resolved
BindingId; a later shadowing declaration must not inherit the earlier move.
`boundary_driver.c` tests those component decisions using production-built HIR;
some excluded shapes remain outside full backend admission. Its compiler
mutations are separate from the complete-source diagnostic and runtime tests.

Keep the original reproducer in a gate reachable from `task verify`. For an
emission defect, compile with strict C11 warnings, check observable behavior,
and reintroduce the defective output to prove the regression check fails.
For ownership, use real allocations and cover failure as well as success;
`tests/conformance/bytes-carrier/return_driver.c` demonstrates an emitted-C
probe with allocation counts and sanitizers.

Before integration, refresh the pair digests and manifest, run `task preflight`
and the static pair gates, then run `task verify` on a quiet machine. A change
to `Taskfile.yml` also requires `task release-evidence`. Run the full emission
census when changing C generation and remove every exception it proves stale.
The multi-hour branch-coverage measurement is a separate gate; its historical
ledger is not evidence that every changed branch was measured on this commit.
