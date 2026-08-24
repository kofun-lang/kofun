# Native CLI profile reference

## Declaration grammar

The bounded source shape is:

```text
cli Identifier {
  name "application-name"
  version "version"
  about "description"
  command Identifier {
    about "description"
    position Identifier "description"
    option Identifier "--long-name" (bool | text) "description"
      [default "text"]
    action (greet | sum | env | status)
  }
}
```

Comments start with `#`. Strings support `\n`, `\t`, `\"`, and `\\`.
Declarations do not use semicolons. App fields and command fields may be
ordered freely, but duplicates are errors.

The profile supports 2–8 commands, 0–4 positions per command, and 0–8 options
per command. Identifiers are at most 63 bytes, strings are at most 255 bytes,
the source is at most 65,536 bytes, and serialized metadata is at most 65,536
bytes.

The current action contracts are deliberately concrete:

| Action | Positions | Options | Success |
| --- | --- | --- | --- |
| `greet` | one name | `shout` bool and `prefix` text | formatted greeting |
| `sum` | two Int64 texts | none | checked Int64 sum |
| `env` | one variable name | none | environment value |
| `status` | one label | none | terminal-aware status |

This action set is a checkpoint for the framework runtime. It is not a general
callback or module system.

Issue #1551 has selected the future static typed binding contract in
[`native-cli-action-binding-v1`](../../spec/native-cli-action-binding-v1/PROFILE.md).
The four-action grammar above remains the only implemented behavior; the
decision profile advances no callback, target, or release claim.

## Runtime command contract

- no arguments and global `-h`/`--help` print generated global help;
- `<command> --help` prints generated command help;
- unknown commands, unknown options, missing values, duplicate options,
  unexpected positions, and invalid or overflowing integers exit `2`;
- a missing environment variable exits `3`;
- successful commands and help exit `0`;
- `--` ends option parsing;
- text option values following the option may begin with `-`;
- environment lookup uses the process `envp`, not a compile-time value.

Diagnostics go to stderr and successful output goes to stdout.

## Build and target limits

The only application target is Linux x86-64 ELF64 using the syscall ABI. The
application is static and has no libc. macOS, Windows, AArch64, localization,
shell completion, arbitrary callbacks, nested subcommands, short-option
bundles, Unicode case conversion, and interactive line editing are outside
this checkpoint.

The host needs a C11 compiler to build the declaration compiler when its cache
is cold. It does not need `cc`, `as`, or `ld` to turn a declaration into the
final application after that compiler exists. The acceptance gate uses `ld`
only to reproduce and audit the checked runtime prefix.
