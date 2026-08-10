# kotest: the Kofun unit-test framework

kotest is a unit-testing stack in the style of JUnit, go test, Rust's
`#[test]` harness, and vitest — written for the Kofun that compiles today.
The assertion library is pure Kofun
([`stdlib/testing/kotest.kofun`](../../stdlib/testing/kotest.kofun)); the
runner is POSIX shell ([`run.sh`](run.sh)); the gate is
[`tests/stdlib/kotest/check.sh`](../../tests/stdlib/kotest/check.sh)
(`task kotest`).

```sh
./bin/kofun unittest                       # all suites (stdlib + examples + tests)
./bin/kofun unittest examples/stdlib       # one directory
./bin/kofun unittest path/to/x_test.kofun  # one suite
./bin/kofun unittest --filter spy          # tests whose name contains "spy"
./bin/kofun unittest --list                # enumerate without running
./bin/kofun unittest --watch               # hot reload: re-run on change

KOTEST_KEEP_WORK=1 ./bin/kofun unittest    # keep the generated unit on a build failure
```

Output is vitest-shaped: `❯` per suite, green `✓` / red `✗` per test,
assertion diagnostics indented under the failing test, and a final
`Tests  N passed (N total, M suites)` line.  Colour respects `NO_COLOR`,
non-TTY output, and `--no-color`.  The exit code is 0 only when every
collected test passed.

## Writing tests

A test is a top-level function named `test_*` taking nothing and returning
its failed-assertion count:

```kofun
fn test_push_appends_in_order() -> Int {
    let mut failures = 0
    let values: IntList = list_push(list_push(list_empty(), 10), 20)
    failures = failures + expect_eq_int(list_length(values), 2)
    failures = failures + expect_eq_int(outcome_value_or(list_get(values, 0), 0 - 1), 10)
    return failures
}
```

Two file conventions, mirroring Rust and Go:

- **Suite files** — `X_test.kofun`, no `fn main`.  When a companion
  `X.kofun` exists next to it (as with every `examples/stdlib/*_sample.kofun`
  pair), the companion's functions are compiled into the unit with its demo
  `fn main` block removed, so the suite tests the real code without
  duplication.
- **Embedded tests** — any other `.kofun` file passed explicitly may carry
  `test_*` functions next to its code; its `fn main` is removed the same way.

The runner collects the test names, generates a harness `fn main` exactly
the way the Rust test harness collects `#[test]` functions, concatenates
framework + code + harness into one translation unit, builds it through
`kofun emit-c` and a C11 compiler, and renders the run.  Top-level `}` in
column zero is required (the repository style already does this) because
main-block removal is line-based.

## Assertions

vitest-order (`actual` first), all returning 0 on pass and 1 on failure:

| Assertion | Checks |
|---|---|
| `expect_eq_int(actual, expected)` | equality |
| `expect_ne_int(actual, forbidden)` | inequality |
| `expect_lt_int / expect_le_int / expect_gt_int / expect_ge_int` | ordering |
| `expect_between_int(actual, low, high)` | inclusive range |
| `expect_that_int(value, predicate)` | predicate returns 1 (vitest `toSatisfy`) |
| `expect_eq_text / expect_ne_text` | Text equality |
| `expect_text_len(actual, length)` | Text length |
| `expect_text_starts_with / expect_text_contains` | prefix / fragment |
| `fail_now(reason)` | unconditional failure (JUnit `fail()`) |

JUnit-order aliases: `assert_equals_int(expected, actual)`,
`assert_not_equals_int`, `assert_equals_text`.

## Mocks, stubs, and spies

The executable slice has no mutable capture, so mocking is Mockito's
*constructor injection* discipline made explicit — collaborators arrive as
callable parameters and tests script them:

```kofun
# stub: a scripted collaborator
let flat_price = product => 100 + product * 0
expect_eq_int(line_subtotal(flat_price, 7, 3), 300)

# forbidden collaborator: calling it prints a diagnostic and poisons the
# result with a sentinel
line_subtotal(stub_unreachable, 1, 0)

# spy: call count and last argument packed in an Int, threaded explicitly
let mut spy = spy_init()
spy = spy_record(spy, 41)
verify_called_times(spy, 1)
verify_last_argument(spy, 41)
```

Helpers: `spy_init`, `spy_record` (arguments must stay within ±999999),
`spy_count`, `spy_last`, `verify_called_times`, `verify_last_argument`,
`stub_unreachable`, `unreachable_sentinel`.
[`examples/stdlib/testing_sample_test.kofun`](../../examples/stdlib/testing_sample_test.kofun)
is the full showcase.

## Self-verification

Every generated harness runs `kotest_selfcheck()` — the framework asserting
its own passing paths and spy arithmetic inside the same binary — and the
gate additionally runs a deliberately failing fixture
([`tests/stdlib/kotest/fixtures/failing_test.kofun`](../../tests/stdlib/kotest/fixtures/failing_test.kofun))
asserting the nonzero exit, the `✗` line, and the diagnostics, so the
harness cannot report red as green.
