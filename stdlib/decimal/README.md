# Compiler-native Decimal checkpoint

[`decimal.kofun`](decimal.kofun) exercises the language's arbitrary-precision
native `Decimal`; it no longer redeclares Decimal as an `Int` significand and
scale record. The source, the Stage 2 compiler, and
`bootstrap/stage2/decimal_v1.c` share one bounded surface:

```kofun
Decimal.round(value, destination_scale, HalfEven)
Decimal.divide(left, right, destination_scale, HalfUp)
Decimal.format(value, display_scale)
Decimal.parse(text)
```

The Stage 2 profile uses positional arguments. A destination scale and one of
`HalfUp`, `HalfEven`, `TowardZero`, `Floor`, or `Ceiling` are mandatory for
every operation that may discard digits. Missing arguments fail at compile
time; there is no process, thread, module, or overload default.

`Decimal.format` is not a rounding operation. It retains exactly the requested
number of fractional digits only when that is an exact rendering; requesting a
smaller scale than the value needs fails with `D007`. Parsing successful output
recovers the same canonical native value, including negative values.

## Fixed-point boundary

Plain `Decimal` uses runtime scale arguments. Its `runtime-scale/v1` profile
requires an explicit display or destination scale for formatting, rounding and
rounded division.

The ordinary Stage 2 C11 compiler also supports the owned `Fixed[S]` carrier.
A literal `S` from 0 through 6144 is part of its type. To construct a value in
a function returning `Result[Fixed[2], DecimalError]`, write
`let amount: Fixed[2] = Fixed.from_decimal(1.999, HalfUp)?`. The compiler
takes the scale from the annotation and propagates an allocation failure
through the enclosing result. Run `task decimal-fixed-carrier` for the
constructor, consuming match and owner-lifetime cases. Fixed formatting,
conversion to Decimal and arithmetic belong to later checkpoints.

## Executable evidence

[`tests/checkpoint.kofun`](tests/checkpoint.kofun) executes 15 native cases:
exact `0.1 + 0.2`, positive and negative ties for all five modes, carry
rounding, rounded division, and a format/parse round trip. The evidence remains
`bounded-examples`; it is not a universal algebraic proof.

[`examples/ledger_tax.kofun`](examples/ledger_tax.kofun) calculates three
amounts and 8.25% tax entirely as native Decimal. Each tax line explicitly
rounds to scale 2 with `HalfUp`, and formatting separately retains two display
places. Expected output is:

```text
149.14
1.65
0.47
10.18
12.30
161.44
```

The binary64 associativity counterexample remains beside the Decimal cases to
show why the two numeric types are not interchangeable. Run the checkpoint
with:

```sh
sh stdlib/decimal/tests/verify.sh
```
