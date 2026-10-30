# goose-lit

[![Goose Language](https://img.shields.io/badge/lang-goose-blue.svg?style=flat-square)](https://github.com/aardappel/goose)
[![License](https://img.shields.io/badge/license-Apache%202.0-lightgrey.svg?style=flat-square)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/Lemon4ksan/goose-lit/ci.yml?branch=main&style=flat-square)](https://github.com/Lemon4ksan/goose-lit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Lemon4ksan/goose-lit?style=flat-square)](https://github.com/Lemon4ksan/goose-lit/releases)
[![Platform: Linux x64](https://img.shields.io/badge/platform-Linux%20x64-blue.svg?style=flat-square)](https://github.com/Lemon4ksan/goose-lit/releases)
[![Platform: Windows x64](https://img.shields.io/badge/platform-Windows%20x64-blue.svg?style=flat-square)](https://github.com/Lemon4ksan/goose-lit/releases)

External verification runtime, LLVM-grade FileCheck matcher, binary wire stream verifier, and G-CRAP risk analyzer for the [Goose programming language](https://github.com/aardappel/goose).

---

## Overview

`goose-lit` provides external black-box and wire verification for Goose repositories. Designed around a **Zero-Footprint Testing** philosophy, it tests libraries and applications through command-line invocations and standard input/output streams without bundling test runners, assertion frameworks, or mocks into production compilation units.

Key subsystems:
- **LIT Directive Runner**: Discovers test files and executes `// RUN:` command pipelines with path and tool substitutions (`%s`, `%S`, `%t`, `%FileCheck`, `%lit`, `%not`).
- **FileCheck Verification Engine**: Verifies sequential program output using text patterns, regular expression wildcards (`{{...}}`), and dynamic variable captures (`[[VAR:regex]]`).
- **Wire Edge & Mutation Verifier**: Proves parser resilience against prefix truncations (`verify_split_stream`) and pseudo-random bit/byte mutations (`mutate_stream`).
- **G-CRAP Safety & Complexity Radar**: Statically evaluates cyclomatic and cognitive complexity, combines unproven Bounds Check Elimination markers (`bce:keep`), branch coverage profiles, and hardware risk gates.
- **Contained Test Execution**: Captures panics and aborts in isolated execution contexts using `thread_spawn_contained`.

---

## Installation

### Prebuilt Release Binaries

Prebuilt standalone binaries for Linux (x86_64) and Windows (x86_64) are attached to each GitHub Release.

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

# Add to user PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
}
```

### Compiling from Source

Prerequisites: Goose compiler `v2026.3` or later and a C compiler (GCC or Clang).

```bash
git clone https://github.com/Lemon4ksan/goose-lit.git
cd goose-lit

# Build with Just
just build

# Or compile directly with Goose
# Linux:
goose build -O2 -o bin/goose-lit bin.goose

# Windows:
goose build --cc gcc -O2 -o bin/goose-lit.exe bin.goose
```

---

## Quick Start

### 1. Execute Test Suites

Run all tests in a directory or execute a single test file:

```bash
goose-lit tests/
```

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

### 2. Writing a LIT Test with FileCheck

Create a standalone test file with run directives and expected output patterns:

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

To run FileCheck directly from a standard input pipe:

```bash
goose run sample.goose | goose-lit filecheck sample.goose
```

### 3. G-CRAP Risk Radar & Complexity Gates

Scan source files for cyclomatic complexity and unproven compiler bounds checks:

```bash
goose-lit crap src/
```

Enforce a G-CRAP risk ceiling in CI (fails with exit code 1 on violation):

```bash
goose-lit gate src/ 25.0 --cov 0.85
```

---

## CLI Reference

### Subcommands

| Subcommand | Syntax | Purpose |
| :--- | :--- | :--- |
| `<path>` | `goose-lit <file\|dir>` | Recursively discovers and executes all `// RUN:` test directives. |
| `filecheck` | `goose-lit filecheck <file>` | Verifies standard input stream against FileCheck directives in `<file>`. |
| `gate` | `goose-lit gate <path> [max]` | Enforces G-CRAP risk gate ceiling (default: `25.0`, exits `1` on violation). |
| `crap` | `goose-lit crap <path>` | Generates integrated G-CRAP complexity and bounds safety radar report. |
| `inspect` | `goose-lit inspect <file\|hex>` | Dumps byte buffers in canonical hex/ASCII or 128-bit SIMD lanes. |
| `not` | `goose-lit not <command...>` | Executes a command pipeline and inverts exit status (`0` &rarr; `1`, non-zero &rarr; `0`). |
| `version` | `goose-lit version` | Displays `goose-lit` version string. |
| `help` | `goose-lit help` | Prints CLI usage and flag reference. |

### Options and Flags

| Flag | Supported In | Description |
| :--- | :--- | :--- |
| `--prefix <PREF>` | `filecheck` | Configures FileCheck pattern prefix (default: `CHECK`). |
| `--verbose`, `-v` | `<path>`, `gate`, `crap` | Enables verbose diagnostic output and execution timings. |
| `--simd [byte]` | `inspect` | Displays 128-bit SIMD lane inspection matching byte (default: `/`). |
| `--offset <N>` | `inspect` | Sets base memory address offset for hexdump formatting. |
| `--cov <val\|file>` | `crap`, `gate` | Sets simulated branch coverage (`0.0..1.0`) or loads coverage profile. |
| `--default-cov <val>`| `crap`, `gate` | Sets default coverage fallback for static triage (default: `0.0`). |
| `--threshold <val>` | `crap` | Sets G-CRAP warning threshold for radar reporting (default: `25.0`). |
| `--format <fmt>` | `crap`, `gate` | Formats output report: `table` (default), `md`, `json`, `gcc`, `sarif`. |
| `--out <file>` | `crap`, `gate` | Writes formatted risk report directly to file. |
| `--baseline <file>` | `crap`, `gate` | Compares against baseline snapshot for CI ratchet enforcement. |
| `--save-baseline <f>`| `crap`, `gate` | Saves current analysis metrics as baseline snapshot. |
| `--delta <val>` | `gate` | Allowed G-CRAP regression tolerance over baseline (default: `5.0`). |
| `--include-tests` | `crap`, `gate` | Includes test files in complexity analysis (excluded by default). |

---

## Directives Reference

### FileCheck Directives

Directives are parsed from comment lines in test files:

| Directive | Description |
| :--- | :--- |
| `// CHECK: <pattern>` | Matches `<pattern>` forward from the previous match location. |
| `// CHECK-NEXT: <pattern>` | Asserts that `<pattern>` matches on the line immediately following the previous match. |
| `// CHECK-NOT: <pattern>` | Asserts that `<pattern>` does not appear anywhere between the previous match and the next match. |
| `// CHECK-LABEL: <pattern>` | Divides test output into independent verification blocks; matches cannot cross label boundaries. |
| `// CHECK-SAME: <pattern>` | Matches `<pattern>` on the identical line as the previous match. |
| `// CHECK-EMPTY:` | Asserts that the next line in the output stream is completely empty. |
| `// CHECK-DAG: <pattern>` | Matches a set of patterns in arbitrary line order within the current scope. |
| `// CHECK-COUNT-<N>: <pattern>` | Asserts that `<pattern>` matches exactly `<N>` times consecutively. |

### Pattern Matching & Wildcards

- **Fixed Strings**: Plain substrings are matched exactly.
- **Regular Expressions**: `{{regex}}` matches regular expressions (e.g. `{{[0-9a-fA-F]+}}` for hex values, `{{.*}}` for arbitrary text).
- **Variable Capture**: `[[VAR:regex]]` captures matched text into named variable `VAR`.
- **Variable Reference**: `[[VAR]]` matches identical text captured by a preceding variable declaration.

### LIT Command Substitutions

Inside `// RUN:` directive pipelines, `goose-lit` expands the following macros:

| Macro | Replacement |
| :--- | :--- |
| `%s` | Absolute native path to the current test source file. |
| `%S` | Directory containing the current test file. |
| `%t` | Temporary scratch file path (`%s.tmp`). |
| `%lit` | Path to the current `goose-lit` executable. |
| `%FileCheck` | Invocable command for `goose-lit filecheck`. |
| `%not` | Invocable command for `goose-lit not`. |

### Test Filtering & Expectations

| Directive | Description |
| :--- | :--- |
| `// XFAIL: <target\|*>` | Marks the test as an expected failure. If the test passes unexpectedly, it reports `XPASS` and fails. |
| `// REQUIRES: <features>` | Runs the test only if the host satisfies specified features (`windows`, `linux`, `macos`, `x86_64`, `arm64`, `gcc`, `clang`). Otherwise marked `UNSUPPORTED`. |
| `// UNSUPPORTED: <features>` | Skips test if the host matches specified features, marking it `UNSUPPORTED`. |

---

## Wire Verification API

For in-process wire and stream fuzzing without external harness code, tests can import `lit` directly:

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
    // Verifies parser correctly handles all partial prefixes 1..N-1
    let ok = lit::verify_split_stream(raw_pkt[..], -1, 0, diag, parse_packet);
    assert(ok);
}
```

---

## Integration & Zero-Footprint Testing

See [`docs/INTEGRATION.md`](docs/INTEGRATION.md) for:
- **Zero-Footprint Testing Guide**: Architectural rationale and step-by-step instructions for eliminating in-tree test frameworks (such as `core/test/` from `goose-wing`).
- **CI Workflow Template**: Ready-to-use GitHub Actions workflow for building and verifying third-party Goose projects with `goose-lit`.
- **Justfile Integration**: Task automation recipes for local development.

See [`examples/basic_project`](examples/basic_project/) for a minimal example repository tested with `goose-lit`.

---

## License

`goose-lit` is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

Copyright (c) 2026 Lemon4ksan (Komolov Arsenii).
