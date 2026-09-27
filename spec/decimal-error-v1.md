# DecimalError and the Fixed v1 source forms

The source-level answers RFC-0015 names but does not define, recorded on
[#1663](https://github.com/kofun-lang/kofun/issues/1663) (2026-09-27). This
document is normative for `kofun.fixed-decimal/v1` and is listed in RFC-0015's
`normative_spec`.

**Every normative statement below is asserted in
`spec/native-toolchain-v1/contract.json` and `model.mjs`, so mutating an answer
turns `task fixed-decimal-profile` red.**

## DecimalError

- **Shape.** `DecimalError` is an opaque nominal value with exactly one
  observation: a code accessor returning the stable `D00x` code as `Text`.
- **Members.** Its member set is exactly `D001`–`D004`, the contract's
  `failures` list. `D002` is static in #1252's arithmetic and `D003` is
  unreachable because no v1 operation parses text; the four are reserved now.
- **Ownership.** `DecimalError` is unrestricted (copyable), and a
  `DecimalError` value never requires allocation.
- **Observation.** v1 ships the code accessor only. `match` on members,
  `print(error)`, and the `error[D00x]: …` message text are deferred to #1253.
- **Scope.** `DecimalError` is reserved for `Fixed` operations in v1. A future
  fallible plain-Decimal operation may reuse it, but that is not promised in
  v1.

## The explicit clone form

- The v1 form is **`Fixed.clone(value)`** in the type namespace, matching
  `Decimal.round(value, scale, mode)`, with parameter mode `read`.

## The v1 format form

- The v1 form is **`Decimal.format(value, display_scale)`**. If #1251 finds
  RFC-0015's `Fixed[S].format()` spelling binding, that is #1251's decision.

## Authority

- **RFC-0015 is authoritative over `docs/DECIMAL.md`** where the two disagree on
  the `from_decimal` spelling. The two `docs/DECIMAL.md` spellings
  (`Fixed[2].from_decimal(1.999, HalfUp)` and the named `rounding:` argument)
  are corrected by #1253.
