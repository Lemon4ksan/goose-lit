# goose-lit

[![Goose Language](https://img.shields.io/badge/lang-goose-blue.svg?style=flat-square)](https://github.com/aardappel/goose)
[![License](https://img.shields.io/badge/license-Apache%202.0-lightgrey.svg?style=flat-square)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/Lemon4ksan/goose-lit/ci.yml?branch=main&style=flat-square)](https://github.com/Lemon4ksan/goose-lit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Lemon4ksan/goose-lit?style=flat-square)](https://github.com/Lemon4ksan/goose-lit/releases)
[![Platform: Linux x64](https://img.shields.io/badge/platform-Linux%20x64-blue.svg?style=flat-square)](https://github.com/Lemon4ksan/goose-lit/releases)
[![Platform: Windows x64](https://img.shields.io/badge/platform-Windows%20x64-blue.svg?style=flat-square)](https://github.com/Lemon4ksan/goose-lit/releases)

Test runner, FileCheck pattern matcher, branch coverage collector, stage profiler, coverage-guided fuzzer, wire stream verifier, and G-CRAP / SLOC gate tool for the [Goose programming language](https://github.com/aardappel/goose).

## Overview

goose-lit tests Goose programs through standard input and output streams. Test files declare shell command pipelines in comments; goose-lit executes these commands and checks the resulting output against expected patterns. Libraries and applications are tested from the outside, so test runners, assertions, and mock structures do not compile into production binaries.

Components:
- LIT runner: discovers test files and executes `// RUN:` commands in parallel with `%s`, `%S`, `%t`, `%FileCheck`, `%lit`, `%not`, `%alloc_hook`, `%prof_hook`, `%fuzz_driver`, and `%cov_rt` substitutions.
- FileCheck engine: compares program stdout with patterns, regular expressions (`{{...}}`), variable captures (`[[VAR:regex]]`), and numeric expressions (`[[#VAR + N]]`).
- Branch coverage collector (`cov`): instruments `.goose` branches in an isolated shadow workspace, runs tests, merges `.gcrap-cov` profiles, and exports LCOV tracefiles.
- Stage profiler and benchmark runner (`profile`): compiles and executes cycle-accurate stage profiles and `testing.B`-style benchmarks with benchstat comparisons.
- Coverage-guided fuzzer (`fuzz`): compiles Goose fuzz targets with SanitizerCoverage or libFuzzer and runs mutation campaigns with RSS drift and complexity gates.
- Cycles-vs-SLOC radar (`sloc`): measures SLOC, packing density, compiler smells, dead functions, multi-entry BCE counts, and Pareto cycle regressions.
- Wire verifier (`lit::wire`): tests packet parsers against split streams (`verify_split_stream`) and byte mutations (`mutate_stream`).
- G-CRAP analyzer (`crap`, `gate`): calculates cyclomatic and cognitive complexity, unproven bounds check markers (`bce:keep`), and real branch coverage weights.
- In-process testkit (`lit::`): assertions, mocks, deterministic clocks, allocation counters, and contained-thread panic capture.

## Installation

### Prebuilt release binaries

Prebuilt standalone binaries for Linux (x86_64) and Windows (x86_64) are attached to each GitHub Release. Runtime shim headers and drivers (`alloc_hook.h`, `prof_hook.h`, `cov_rt.h`, `fuzz_driver.c`) are embedded inside the binary and materialized into `.lit/cache/shim/` on demand when no sibling `shim/` directory is present.

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

Requirements: Goose compiler `v2026.4` or later and a C11 compiler (GCC or Clang).

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

### Minimal setup (tests only)

If you only want a test runner and assertions without configuring coverage, profiling, or static gates, three steps are enough:

1. Install the `goose-lit` binary (above).
2. Add a `.goose` test under `tests/` (either a plain `fn main()` test or `// RUN:` + `// CHECK:` directives).
3. Run `goose-lit` from the project root.

### Running tests

Run all tests in the project (reads `tests_dir` from `.litconfig` or scans `tests/`):

```bash
goose-lit
```

Or target a specific directory or file:

```bash
goose-lit tests/
goose-lit tests/ -j auto --fail-fast
goose-lit tests/my_feature_test.goose
```

Test discovery and execution rules:
- Files with `// RUN:` directives execute each declared command pipeline in sequence.
- Files with `// CHECK:` patterns automatically execute `goose %s | %FileCheck %s`.
- Test files (`*_test.goose` or files declaring `fn main`) automatically execute `goose %s`.
- Interface tests without `main` are verified with `goose check %s`.
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

### Static analysis, real coverage, and complexity gates

Scan source files for cyclomatic complexity and unproven compiler bounds checks:

```bash
goose-lit crap src/
```

Enforce the static complexity and BCE gate in CI (exits with code 1 on violation):

```bash
goose-lit gate src/ 25.0
```

Collect real branch coverage and evaluate G-CRAP against the resulting `.gcrap-cov` profile:

```bash
goose-lit cov src/ --tests tests/ --out .lit/cache/cov/merged.gcrap-cov --lcov coverage.info
goose-lit gate src/ 25.0 --cov .lit/cache/cov/merged.gcrap-cov
```

Run format check, typecheck, G-CRAP gate, and an optional LIT test in one command:

```bash
goose-lit verify src/parser.goose --max-gcrap 25 --lit tests/parser_test.goose
```

## Command reference

### Subcommands

| Subcommand | Syntax | Purpose |
| :--- | :--- | :--- |
| `<path>` | `goose-lit <file\|dir>` | Recursively discovers and executes `.goose` / `.lit` tests. |
| `check` | `goose-lit check <path...>` | Typechecks `.goose` files in parallel (`-j`, `--filter`, `--fail-fast`). |
| `cov` | `goose-lit cov <src_target>` | Instruments branches, runs tests, merges `.gcrap-cov`, and exports LCOV. |
| `verify` | `goose-lit verify <target>` | Runs `goose format --check`, `goose check`, `gate`, and optional `--lit`. |
| `filecheck` | `goose-lit filecheck <file>` | Verifies standard input stream against FileCheck directives in `<file>`. |
| `not` | `goose-lit not <command...>` | Executes a command pipeline and inverts exit status (`0` to `1`, non-zero to `0`). |
| `gate` | `goose-lit gate <path> [max]` | Enforces G-CRAP risk gate ceiling (default: `25.0`, exits `1` on violation). |
| `crap` | `goose-lit crap <path>` | Calculates cyclomatic complexity, cognitive complexity, and unproven bounds checks. |
| `profile` | `goose-lit profile [bench.goose]` | Builds and runs stage profiler or `testing.B` benchmark suites with benchstat diffs. |
| `sloc` | `goose-lit sloc [path...]` | Runs cycles-vs-SLOC radar, anti-packing checks, compiler smells, and Pareto gate. |
| `fuzz` | `goose-lit fuzz [entry.goose]` | Builds and runs SanitizerCoverage or libFuzzer fuzzing campaigns. |
| `inspect` | `goose-lit inspect <file\|hex>` | Dumps byte buffers in hex/ASCII or 128-bit SIMD lanes. |
| `version` | `goose-lit version` | Displays goose-lit version string. |
| `help` | `goose-lit help` | Prints CLI usage and flag reference. |

Run `goose-lit <subcommand> --help` for full per-subcommand flags.

### Common options and flags

| Flag | Supported in | Description |
| :--- | :--- | :--- |
| `--config <file>` | all | Loads custom configuration file (default: `.litconfig`). |
| `-j`, `--jobs <N\|auto>` | `<path>`, `check`, `cov` | Parallel worker count (`auto` caps workers by CPU cores and available RAM). |
| `--filter <glob>` | `<path>`, `check`, `cov`, `profile`, `sloc` | Filters targets or benchmark cases. |
| `--fail-fast`, `-x` | `<path>`, `check` | Stops scheduling new work after the first failure. |
| `--json` | `<path>` | Emits a structured JSON test summary. |
| `--list-tests` | `<path>` | Lists discovered test files without executing them. |
| `--allow-empty` | `<path>` | Returns exit code `0` when no test files are discovered. |
| `--timeout <sec>` | `<path>`, `cov` | Per-command execution timeout in seconds (default: `60` for runner, `120` for `cov`). |
| `--prefix <PREF>` | `filecheck` | Configures FileCheck pattern prefix (default: `CHECK`). |
| `--verbose`, `-v` | `<path>` | Shows command output and execution time. |
| `--simd [byte]` | `inspect` | Displays 128-bit SIMD lane inspection matching byte (default: `/`). |
| `--offset <N>` | `inspect` | Sets base memory offset for hexdump output. |
| `--bce-lines [file]` | `crap`, `gate` | Loads compiler bounds-check elimination output or runs `goose --bce-lines` (enabled by default). |
| `--no-bce` | `crap`, `gate` | Disables automatic `goose --bce-lines` compiler bridge. |
| `--specs [file]` | `crap`, `gate` | Loads or auto-runs `goose --specs` diagnostics. |
| `--cov <file>` | `crap`, `gate`, `verify` | Loads a `.gcrap-cov` branch coverage profile generated by `goose-lit cov`. |
| `--lcov <file>` | `crap`, `gate` | Loads an LCOV tracefile. |
| `--require-cov` | `crap`, `gate`, `verify` | Fails with exit code `2` if no real coverage profile is loaded. |
| `--explain` | `crap`, `gate` | Prints branch-level line hotspot breakdown for G-CRAP and BCE. |
| `--threshold <val>` | `crap`, `gate` | Sets G-CRAP warning threshold (default: `25.0`). |
| `--format <fmt>` | `crap`, `gate`, `sloc` | Output format (`table`, `md`, `json`, plus `gcc`/`sarif` for `crap`/`gate`, `tsv` for `sloc`). |
| `--out <file>` | `crap`, `gate`, `cov`, `sloc` | Writes output report or profile to `<file>`. |
| `--baseline <file>` | `crap`, `gate`, `sloc` | Compares metrics against baseline file (auto-detects `.lit/baseline` or `.lit-baseline`). |
| `--no-baseline` | `crap`, `gate`, `sloc` | Disables automatic baseline comparison. |
| `--save-baseline [f]` | `crap`, `gate`, `sloc` | Writes current metrics to baseline file. |
| `--delta <val>` | `crap`, `gate` | Allowed G-CRAP increase above baseline (default: `5.0`). |
| `--include-tests` | `crap`, `gate`, `sloc` | Includes test files in analysis. |

## Configuration

goose-lit loads settings from `.litconfig` or `lit.conf` in the current or parent directory. CLI flags override file settings.

Example `.litconfig`:

```ini
# .litconfig
baseline = .lit/baseline
ceiling = 25.0
delta = 5.0
format = table
prefix = CHECK
tests_dir = tests
src_dir = src
exclude = vendor/, scratch/
cc = gcc
cc_windows = tools/gcc_noavx.cmd
jobs = auto
timeout = 60
include_tests = false
```

Configuration keys:
- `baseline`: path to G-CRAP baseline snapshot file for ratchet comparisons.
- `ceiling`: G-CRAP gate ceiling (default: `25.0`).
- `delta`: regression tolerance over baseline (default: `5.0`).
- `format`: output format (`table`, `md`, `json`, `gcc`, `sarif`).
- `prefix`: FileCheck directive prefix (default: `CHECK`).
- `tests_dir`: directory scanned when running tests without arguments.
- `src_dir`: target directory for G-CRAP and coverage analysis.
- `exclude`: comma-separated directory or path prefixes skipped during discovery.
- `cc` / `goose_cc`: default C compiler path passed to `GOOSE_CC`.
- `cc_windows`, `cc_linux`, `cc_macos` (or `goose_cc_*`): OS-specific compiler overrides that take precedence over `cc`.
- `check_entries`: comma-separated package root `.goose` entry points used by `check` and `verify` when resolving internal submodules.
- `jobs`: default parallel worker count (positive integer or `auto` for CPU/RAM-aware scheduling).
- `timeout`: per-command timeout in seconds (default: `60`).
- `include_tests`: include test files in complexity analysis (`true` or `false`).
- `bce`: enable or disable automatic `goose --bce-lines` (`true` or `false`).
- `cov_profile`, `profile_target`, `fuzz_entry`, `fuzz_extra_c`, `fuzz_extra_libs`: defaults for `cov`, `profile`, and `fuzz`.
- `sloc_baseline`, `sloc_map`, `sloc_exclude`, `sloc_bce_entries`, `sloc_max_packing`, `sloc_max_delta`, `sloc_cycle_noise`: defaults for `sloc`.

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
| `%s` | Path to the test file. |
| `%S` | Directory containing the test file. |
| `%t` | Temporary scratch file path inside `.lit/cache/`. |
| `%lit` | Path to the running `goose-lit` binary. |
| `%FileCheck` | Command for `goose-lit filecheck`. |
| `%not` | Command for `goose-lit not`. |
| `%alloc_hook` | Path to `alloc_hook.h` (resolved from disk or embedded cache). |
| `%prof_hook` | Path to `prof_hook.h` (resolved from disk or embedded cache). |
| `%fuzz_driver` | Path to `fuzz_driver.c` (resolved from disk or embedded cache). |
| `%cov_rt` | Path to `cov_rt.h` (resolved from disk or embedded cache). |

### Test filtering and conditions

| Directive | Description |
| :--- | :--- |
| `// XFAIL: <target\|*>` | Expected failure. Fails if the test passes. |
| `// REQUIRES: <features>` | Runs the test only if the host matches all listed features (`windows`, `linux`, `macos`, `x86_64`, `arm64`, `gcc`, `clang`, `goose`). |
| `// UNSUPPORTED: <features>` | Skips the test if the host matches any listed feature. |

## In-process test framework

When writing unit tests, table-driven suites, or component tests, import `lit` directly. The root [`lit.goose`](lit.goose) facade exports only the lightweight test library (`testkit` and `wire`), without pulling in the CLI engines (`crap`, `sloc`, `cov`, `fuzz`, or `runner`). Assertions, mocks, deterministic clocks, allocation counters, profiler spans, and test runners reside in `lit::`:

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
- Allocation and profiling: `alloc_reset`, `alloc_mark`, `alloc_growth`, `verify_zero_allocs`, `new_bench_suite`, `bench`, `prof_span`, `verify_latency_budget`, `verify_slice_parity`.
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
- [`ARCHITECTURE.md`](ARCHITECTURE.md) describes the internal module layout and verification stages.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) covers prerequisites, coding standards, and test commands.

## License

goose-lit is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

Copyright (c) 2026 Lemon4ksan (Komolov Arsenii).
