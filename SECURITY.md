# Security policy

## Supported versions

`goose-lit` is in `0.x` development. Security fixes are applied to the `main` branch and the latest tagged release in [`version.txt`](version.txt).

## Reporting a vulnerability

Do not open public GitHub issues or pull requests for suspected security bugs. Report vulnerabilities through [GitHub Private Vulnerability Reporting](https://github.com/Lemon4ksan/goose-lit/security/advisories/new).

Include the following details in your report:

- Affected subsystem and source path (for example, `shim/proc.c`, `shim/fuzz_driver.c`, `runner/lit_runner.goose`, or `sloc/cli.goose`).
- A minimal reproduction case (test file, `.litconfig`, or CLI invocation) showing the trigger.
- Impact class: command injection through directive or path handling, memory corruption in C shims, or arbitrary file overwrite outside `.lit/cache/`.

Reports receive an initial triage response within 7 days. Once a fix is verified on `main`, an advisory is published upon release.

## Scope

Security issues in `goose-lit` cover:

- Memory safety and buffer bounds in C11 shims (`shim/proc.c`, `shim/alloc_count.c`, `shim/profiler.c`, `shim/fuzz_driver.c`).
- Path handling and shell escaping in CLI runners (`runner/lit_runner.goose`, `cov/cli.goose`, `profile/cli.goose`, `fuzz/cli.goose`, `sloc/cli.goose`).
- Tempfile and cache cleanup behavior under `.lit/cache/`.

## Out of scope

- Arbitrary command execution via `// RUN:` directives in untrusted test files, because executing user-declared shell commands is the intended function of a LIT runner.
- Vulnerabilities in the Goose compiler (`aardappel/goose`) or external C toolchains.
