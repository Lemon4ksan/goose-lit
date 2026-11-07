# goose-lit

[![Goose Language](https://img.shields.io/badge/lang-goose-blue.svg?style=flat-square)](https://github.com/aardappel/goose)
[![License](https://img.shields.io/badge/license-Apache%202.0-lightgrey.svg?style=flat-square)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/Lemon4ksan/goose-lit/ci.yml?branch=main&style=flat-square)](https://github.com/Lemon4ksan/goose-lit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Lemon4ksan/goose-lit?style=flat-square)](https://github.com/Lemon4ksan/goose-lit/releases)
[![Platform: Linux x64](https://img.shields.io/badge/platform-Linux%20x64-blue.svg?style=flat-square)](https://github.com/Lemon4ksan/goose-lit/releases)
[![Platform: Windows x64](https://img.shields.io/badge/platform-Windows%20x64-blue.svg?style=flat-square)](https://github.com/Lemon4ksan/goose-lit/releases)

Test runner, FileCheck pattern matcher, wire stream verifier, and static complexity analyzer for the [Goose programming language](https://github.com/aardappel/goose).

## Overview

goose-lit tests Goose programs through standard input and output streams. Test files declare shell command pipelines in comments; goose-lit executes these commands and checks the resulting output against expected patterns. Libraries and applications are tested from the outside, so test runners, assertions, and mock structures do not compile into production binaries.

Components:
- LIT runner: finds test files and executes `// RUN:` commands with `%s`, `%S`, `%t`, `%FileCheck`, `%lit`, and `%not` substitutions.
- FileCheck engine: compares program stdout with patterns, regular expressions (`{{...}}`), and variable captures (`[[VAR:regex]]`).
- Wire verifier: tests packet parsers against split streams (`verify_split_stream`) and byte mutations (`mutate_stream`).
- G-CRAP analyzer: calculates cyclomatic and cognitive complexity, unproven bounds check markers (`bce:keep`), and branch coverage weights.
- Thread isolation: runs tests in subprocesses or isolated threads with panic capture.

## Installation

### Prebuilt release binaries

Prebuilt binaries for Linux (x86_64) and Windows (x86_64) are attached to each GitHub Release.

#### Linux (x86_64)

```bash
LATEST_TAG=$(curl -s https://api.github.com/repos/Lemon4ksan/goose-lit/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
curl -sSL "https://github.com/Lemon4ksan/goose-lit/releases/download/${LATEST_TAG}/goose-lit-${LATEST_TAG}-linux-x64.tar.gz" | sudo tar -xz -C /usr/local/bin
sudo chmod +x /usr/local/bin/goose-lit
```

#### Windows (x86_64, PowerShell)

```powershell
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/Lemon4ksan/goose-lit/releases/latest"
$tag = $release.tag_name
$zipUrl = "https://github.com/Lemon4ksan/goose-lit/releases/download/$tag/goose-lit-$tag-windows-x64.zip"
$installDir = "$HOME\.goose-lit\bin"

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Invoke-WebRequest -Uri $zipUrl -OutFile "$installDir\lit.zip"
Expand-Archive -Path "$installDir\lit.zip" -DestinationPath $installDir -Force
Remove-Item "$installDir\lit.zip" -Force

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
}
```

### Compiling from source

Requirements: Goose compiler v2026.3 or later and a C compiler (GCC or Clang).

```bash
git clone https://github.com/Lemon4ksan/goose-lit.git
cd goose-lit

# Build with Just
just build

# Or compile with Goose directly
# Linux:
goose build -O2 -o bin/goose-lit bin.goose

# Windows:
goose build --cc gcc -O2 -o bin/goose-lit.exe bin.goose
```

## Quick start

### Running tests

Run all tests in the project (reads `tests_dir` from `.litconfig` or scans `tests/`):

```bash
goose-lit
```

Or target a specific directory or file:

```bash
goose-lit tests/
goose-lit tests/my_feature_test.goose
```

Test discovery and execution rules:
- Files with `// RUN:` directives: executes each declared command pipeline in sequence.
- Files with `// CHECK:` patterns: automatically executes `goose %s | %FileCheck %s`.
- Test files (`*_test.goose` or files declaring `fn main`): automatically executes `goose %s`.
- Interface tests without `main`: verified with `goose check %s`.
- Captured command output and temporary buffers are kept in `.lit/cache/` and cleaned up automatically.

Example output:
```text
=== Goose LIT Test Runner ===
  [PASS] tests/filecheck_test.goose (87 ms)
  [PASS] tests/pipeline_test.goose (61 ms)
  [PASS] tests/gate_test.goose (31 ms)
  [UNSUPPORTED] tests/unsupported_test.goose
  [PASS] tests/wire_test.goose (81 ms)
  [XFAIL] tests/xfail_test.goose (39 ms)
-----------------------------------------------------------------------
Test Summary: 4 passed, 0 failed, 1 xfailed, 1 unsupported in 299 ms
```

### Writing a LIT test with FileCheck

Create a test file with run directives and expected output patterns:

```goose
// tests/sample.goose
// RUN: goose %s | %FileCheck %s

import std;

fn main() {
    print("INIT: Service online");
    print("CHANNEL: 0x4A status=READY");
    print("PORT: 8080");
    print("DONE: Processed 42 items");
}

// CHECK: INIT: Service online
// CHECK-NEXT: CHANNEL: 0x4A status=READY
// CHECK-DAG: PORT: {{[0-9]+}}
// CHECK-NOT: ERROR
// CHECK: DONE: Processed [[COUNT:[0-9]+]] items
```

To run FileCheck from a standard input pipe:

```bash
goose run sample.goose | goose-lit filecheck sample.goose
```

### Static analysis and complexity gates

Scan source files for cyclomatic complexity and unproven compiler bounds checks:

```bash
goose-lit crap src/
```

Enforce a G-CRAP risk ceiling in CI (exits with code 1 on violation):

```bash
goose-lit gate src/ 25.0 --cov 0.85
```

## Command reference

### Subcommands

| Subcommand | Syntax | Purpose |
| :--- | :--- | :--- |
| `<path>` | `goose-lit <file\|dir>` | Recursively discovers and executes all `// RUN:` test directives. |
| `filecheck` | `goose-lit filecheck <file>` | Verifies standard input stream against FileCheck directives in `<file>`. |
| `gate` | `goose-lit gate <path> [max]` | Enforces G-CRAP risk gate ceiling (default: `25.0`, exits `1` on violation). |
| `crap` | `goose-lit crap <path>` | Calculates cyclomatic complexity and unproven bounds checks. |
| `inspect` | `goose-lit inspect <file\|hex>` | Dumps byte buffers in hex/ASCII or 128-bit SIMD lanes. |
| `not` | `goose-lit not <command...>` | Executes a command pipeline and inverts exit status (`0` to `1`, non-zero to `0`). |
| `version` | `goose-lit version` | Displays goose-lit version string. |
| `help` | `goose-lit help` | Prints CLI usage and flag reference. |

### Options and flags

| Flag | Supported in | Description |
| :--- | :--- | :--- |
| `--config <file>` | all | Loads custom configuration file (default: `.litconfig`). |
| `--test-dir <dir>` | `<path>`, `test` | Overrides test root directory (default: `tests` or `tests_dir` in `.litconfig`). |
| `--timeout <ms>` | `<path>`, `test` | Per-command execution timeout in milliseconds (default: `30000`, `0` = unlimited). |
| `--prefix <PREF>` | `filecheck` | Configures FileCheck pattern prefix (default: `CHECK`). |
| `--verbose`, `-v` | `<path>`, `gate`, `crap` | Shows command output and execution time. |
| `--simd [byte]` | `inspect` | Displays 128-bit SIMD lane inspection matching byte (default: `/`). |
| `--offset <N>` | `inspect` | Sets memory offset for hexdump output. |
| `--bce-lines [file]` | `crap`, `gate` | Loads compiler bounds-check elimination output or runs `goose --bce-lines` (enabled by default). |
| `--no-bce` | `crap`, `gate` | Disables automatic `goose --bce-lines` compiler bridge. |
| `--cov <val\|file>` | `crap`, `gate` | Sets branch coverage (`0.0..1.0`) or loads a coverage file. |
| `--default-cov <val>`| `crap`, `gate` | Sets fallback coverage when a function has no profile data (default: `0.0`). |
| `--threshold <val>` | `crap` | Sets G-CRAP warning threshold (default: `25.0`). |
| `--format <fmt>` | `crap`, `gate` | Output format: `table` (default), `md`, `json`, `gcc`, or `sarif`. |
| `--out <file>` | `crap`, `gate` | Writes report to `<file>`. |
| `--baseline <file>` | `crap`, `gate` | Compares metrics against baseline file (default: `.lit-baseline` if present). |
| `--no-baseline` | `crap`, `gate` | Disables automatic baseline comparison. |
| `--save-baseline [f]`| `crap`, `gate` | Writes current metrics to baseline file (default: `.lit-baseline`). |
| `--delta <val>` | `gate` | Allowed G-CRAP increase above baseline (default: `5.0`). |
| `--include-tests` | `crap`, `gate` | Includes test files in analysis. |

## Configuration

goose-lit loads settings from `.litconfig` or `lit.conf` in the current or parent directory. CLI flags override file settings.

Example `.litconfig`:

```ini
# .litconfig
baseline = .lit-baseline
ceiling = 25.0
cov = 0.85
delta = 5.0
format = table
prefix = CHECK
tests_dir = tests
src_dir = src
include_tests = false
```

Configuration keys:
- `baseline`: path to baseline snapshot file for ratchet comparisons.
- `ceiling`: G-CRAP gate ceiling (default: `25.0`).
- `cov`: default branch coverage (default: `0.0`).
- `delta`: regression tolerance over baseline (default: `5.0`).
- `format`: output format (`table`, `md`, `json`, `gcc`, `sarif`).
- `prefix`: FileCheck directive prefix (default: `CHECK`).
- `tests_dir`: directory scanned when running tests without arguments.
- `src_dir`: target directory for G-CRAP analysis.
- `include_tests`: include test files in complexity analysis (`true` or `false`).

## Directives reference

### FileCheck directives

Directives are parsed from comments in test files:

| Directive | Description |
| :--- | :--- |
| `// CHECK: <pattern>` | Matches `<pattern>` after the previous match. |
| `// CHECK-NEXT: <pattern>` | Matches `<pattern>` on the line immediately after the previous match. |
| `// CHECK-NOT: <pattern>` | Asserts `<pattern>` does not appear between the previous and next match. |
| `// CHECK-LABEL: <pattern>` | Divides output into blocks; matches cannot cross labels. |
| `// CHECK-SAME: <pattern>` | Matches `<pattern>` on the same line as the previous match. |
| `// CHECK-EMPTY:` | Asserts the next line is empty. |
| `// CHECK-DAG: <pattern>` | Matches patterns in any order within the current block. |
| `// CHECK-COUNT-<N>: <pattern>` | Matches `<pattern>` `<N>` times on consecutive lines. |

### Pattern matching and wildcards

Pattern rules:
- Plain substrings match exact text.
- `{{regex}}` matches regular expressions (`{{.*}}`, `{{.+}}`, character classes like `{{[0-9a-fA-F]+}}`, negated classes `{{[^ ]+}}`, and escape classes `\d`, `\w`, `\s`). Full alternation (`a|b`) and counted repetitions (`{m,n}`) are not supported in the zero-allocation engine.
- `[[VAR:regex]]` matches the pattern and stores the matched text in variable `VAR`.
- `[[VAR]]` matches the text saved in `VAR`.
- `[[#VAR:]]` captures an unsigned decimal integer into numeric variable `VAR`, and `[[#VAR + N]]` / `[[#VAR - N]]` matches the evaluated decimal value with a non-digit boundary check.

### LIT command substitutions

Inside `// RUN:` commands, goose-lit expands these substitutions:

| Macro | Replacement |
| :--- | :--- |
| `%s` | Absolute path to the test file. |
| `%S` | Directory containing the test file. |
| `%t` | Temporary scratch file path (`%s.tmp`). |
| `%lit` | Path to the goose-lit binary. |
| `%FileCheck` | Command for `goose-lit filecheck`. |
| `%not` | Command for `goose-lit not`. |

### Test filtering and conditions

| Directive | Description |
| :--- | :--- |
| `// XFAIL: <target\|*>` | Expected failure. Fails if the test passes. |
| `// REQUIRES: <features>` | Runs the test only if the host matches the listed features (`windows`, `linux`, `macos`, `x86_64`, `arm64`, `gcc`, `clang`). |
| `// UNSUPPORTED: <features>` | Skips the test if the host matches the listed features. |

## In-process test framework

When writing unit tests, table-driven suites, or component tests, import `lit` directly. Assertions, mocks, deterministic clocks, and test runners reside in `lit::`:

```goose
// tests/unit_test.goose
// RUN: goose %s | %FileCheck %s

import std;
import lit from "..";

fn test_feature(t: lit::T&) {
    lit::assert_true(t, 1 + 1 == 2, "arithmetic check");
    lit::assert_eq(t, 42, 42);
    lit::assert_contains(t, "user_id=123", "123");

    // Mocks and fuzzing
    var clock = lit::new_mock_clock();
    lit::advance_ms(clock, 50);

    var rng = lit::new_fuzz_rng();
    let num = lit::next_range(rng, 1, 100);
    lit::assert_ge(t, num, 1);
}

fn main() {
    var runner = lit::new_runner("my_suite", lit::Verbosity.Golden);
    runner.run_case("feature", test_feature);
    runner.finish();
}

// CHECK: [PASS] feature
// CHECK: SUITE: my_suite | PASS: 1/1 | FAIL: 0
```

Included utilities:
- Assertions: `assert_true`, `assert_false`, `assert_eq`, `assert_ne`, `assert_bytes_eq`, `assert_struct_eq`, `assert_contains`, `assert_elements_match`, `assert_in_delta`, and aborting `require_*` equivalents.
- Lifecycle: `T`, `Runner`, `new_runner`, `run_case`, `run` (subtests), `run_table` (table-driven tests).
- Mocks: `MockClock`, `MockMonoClock`, `new_mock_clock`, `advance_ms`, `advance_sec`, `spy`, `record_call`.
- Property testing: `FuzzRng`, `new_fuzz_rng`, `next_u64`, `next_range`, `next_bool`.
- Latency & parity: `verify_latency_budget`, `verify_slice_parity`.
- Sandboxing: `wait_contained_result`, `assert_balanced`.

## Wire verification API

Tests can import `lit` directly to test packet decoders against split inputs or mutations:

```goose
import std;
import lit from "path/to/goose-lit";

fn parse_packet(buf: const u8[:]) -> i64 {
    if buf.len < 4 { return -1; }
    return 0;
}

fn main() {
    var raw_pkt: u8[>..] = [];
    lit::parse_packet_payload("01020304", raw_pkt);

    var diag: u8[>..] = [];
    let ok = lit::verify_split_stream(raw_pkt[..], -1, 0, diag, parse_packet);
    assert(ok);
}
```

## Integration

Documentation and examples:
- [`docs/INTEGRATION.md`](docs/INTEGRATION.md) describes CI workflows, Justfile recipes, and decoupling in-tree test frameworks.
- [`examples/basic_project`](examples/basic_project/) provides a sample Goose project tested with LIT.

## License

goose-lit is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

Copyright (c) 2026 Lemon4ksan (Komolov Arsenii).
