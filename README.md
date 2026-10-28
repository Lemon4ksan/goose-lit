# goose-lit

[![Goose Language](https://img.shields.io/badge/lang-goose-blue.svg?style=flat-square)](https://github.com/Lemon4ksan/goose)
[![License](https://img.shields.io/badge/license-Apache%202.0-lightgrey.svg?style=flat-square)](LICENSE)

Test runner, FileCheck matcher, binary wire stream verifier, and G-CRAP risk analyzer for Goose.

## Overview

goose-lit is an external verification runtime for Goose repositories. It tests codebases without adding library dependencies to production targets. Projects interact with the harness through command-line invocations and borrowed byte slices (`const u8[:]`).

The runtime includes:
- Test execution based on `// RUN:` directives in source comments.
- Pattern matching against program output using FileCheck directives.
- Binary stream prefix slicing and pseudo-random payload mutation.
- Static risk triage based on cyclomatic complexity, bounds check elimination reports, and branch coverage.
- Isolated test execution using `thread_spawn_contained`.

## Capabilities

| Component | Description |
| :--- | :--- |
| LIT runner | Parses `// RUN:` command pipelines in `.goose` and `.lit` files. Supports `%s`, `%S`, `%t`, `%FileCheck`, and `%lit` substitutions. Discovers test files using breadth-first traversal. |
| FileCheck engine | Verifies text output against `CHECK:`, `CHECK-NEXT:`, `CHECK-NOT:`, `CHECK-LABEL:`, `CHECK-SAME:`, and `CHECK-EMPTY:` directives. |
| Wire edge tester | Slices binary buffers into prefixes `1..N-1` to verify parser behavior on truncated inputs (`verify_split_stream`). |
| Stream mutator | Applies bit flips, byte swaps, and extreme integer values using `xorshift64_step`. |
| G-CRAP radar | Computes cyclomatic and cognitive complexity, loads bounds check data from `goose --bce-lines`, imports branch coverage, and evaluates regression gates. |
| Contained testkit | Spawns test threads via `thread_spawn_contained` to capture aborts and panics. |

## Quick start

### 1. Build the binary

```bash
just build
```

Or invoke the compiler directly:

```bash
goose build --cc gcc -O2 -o bin/goose-lit.exe bin.goose
```

### 2. Run test files

Execute tests in a directory or file:

```bash
.\bin\goose-lit.exe tests/
```

Output:
```text
=== Goose LIT Test Runner ===
  [PASS] tests/filecheck_test.goose (87 ms)
  [PASS] tests/pipeline_test.goose (61 ms)
  [PASS] tests/wire_test.goose (81 ms)
-----------------------------------------------------------------------
Test Summary: 3 passed, 0 failed in 230 ms
```

### 3. FileCheck directives in tests

Add run instructions and assertions to a source file:

```goose
// tests/sample.goose
// RUN: goose %s | %FileCheck %s

import std;

fn main() {
    print("INIT: Service online");
    print("CHANNEL: 0x4A status=READY");
    print("DONE: Processed 42 items");
}

// CHECK: INIT: Service online
// CHECK-NEXT: CHANNEL: 0x4A status=READY
// CHECK-NOT: ERROR
// CHECK: DONE: Processed 42 items
```

To run FileCheck directly from standard input:

```bash
goose run sample.goose | goose-lit filecheck sample.goose
```

### 4. G-CRAP risk analysis

Scan source code for complexity and unproven bounds checks:

```bash
.\bin\goose-lit.exe crap src/
```

Output:
```text
=== goose-crap risk radar (G-CRAP) ===

| Function                         |   CC |  Cog |   Cov% | bce:keep |     CRAP |   G-CRAP | Archetype          |
|----------------------------------|------|------|--------|----------|----------|----------|--------------------|
| parse_header                     |    5 |    3 |  85.0% |      0/4 |      5.0 |      2.5 | LOW_PRIORITY       |
| decode_frame                     |   18 |   14 |   0.0% |      6/8 |     42.0 |    192.0 | PANIC_HAZARD       |

Summary:
  Total functions scanned: 2
  Panic hazard functions:  1 (holding 6 unproven bce:keep in uncovered branches)
```

## Directives reference

### FileCheck patterns
- `// CHECK: <pattern>`: matches text forward from the previous match.
- `// CHECK-NEXT: <pattern>`: matches text on the line immediately following the previous match.
- `// CHECK-NOT: <pattern>`: verifies that the pattern does not occur before the next match.
- `// CHECK-LABEL: <pattern>`: splits output into independent verification blocks.
- `// CHECK-SAME: <pattern>`: matches text on the same line as the previous match.
- `// CHECK-EMPTY:`: verifies that the next line contains no text.

### LIT substitutions
- `%s`: path to the test file.
- `%S`: directory containing the test file.
- `%t`: temporary file path (`%s.tmp`).
- `%lit`: path to the `goose-lit` executable.
- `%FileCheck`: command invoking `goose-lit filecheck`.

## Wire verification API

Unit tests can call the stream verification functions directly:

```goose
import std;
import lit from "path/to/goose-lit";

fn sample_decoder(buf: const u8[:]) -> i64 {
    if buf.len < 4 { return -1; }
    return 0;
}

fn main() {
    var raw_pkt: u8[>..] = [];
    lit::parse_packet_payload("01020304", raw_pkt);

    var diag: u8[>..] = [];
    let ok = lit::verify_split_stream(raw_pkt[..], -1, 0, diag, sample_decoder);
    assert(ok);
}
```

## Verification

Run the test suite:

```bash
# Windows
powershell -ExecutionPolicy Bypass -File .\scripts\test_all.ps1

# Unix
./scripts/test_all.sh
```

## License

goose-lit is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for terms.

Copyright (c) 2026 Lemon4ksan (Komolov Arsenii).
