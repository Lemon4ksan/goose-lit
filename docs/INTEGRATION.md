# Integrating goose-lit into Goose Projects

This guide details how to integrate `goose-lit` into Goose projects, including automated continuous integration (CI) workflows, `Justfile` task automation, and migrating systems libraries to a **Zero-Footprint Testing** model.

---

## Zero-Footprint Testing Guide

### The Problem with Bundled Test Frameworks

High-performance networking and systems libraries (such as `goose-wing`) operate under strict constraints:
- **Zero dynamic memory allocation** on wire parsing and serialization hot paths.
- **Dead code elimination**: Every symbol included in production binaries increases attack surface, cache pressure, and binary size.
- **Boundary discipline**: Protocols must be validated at the ingress boundary (`const u8[:]`) without internal white-box mocks that bypass protocol state machines.

When a repository bundles test harnesses directly into production modules (e.g. `core/test/` included in `core.goose`):
1. **Symbol and Binary Pollution**: Assertion helpers, string diff engines, and mock structures compile into release artifacts unless conditionally compiled out.
2. **Artificial Mock Couplings**: Developers are tempted to write unit tests against internal mock structs rather than raw wire bytes, hiding RFC framing violations, fragmented packets, and buffer boundary regressions.
3. **Namespace Clutter**: Exported test utilities risk accidental usage by downstream consumers.

### The Zero-Footprint Model

`goose-lit` adopts the LLVM LIT / FileCheck architecture:

```
┌────────────────────────────────────────────────────────┐
│                      goose-lit                         │
│  (External Verification Binary & Static Risk Analyzer) │
└───────────┬────────────────────────────────┬───────────┘
            │ Subprocess Execution           │ Static Analysis
            ▼                                ▼
┌────────────────────────┐      ┌────────────────────────┐
│ Standalone Test File   │      │ Production Core        │
│ // RUN: goose %s | ... │      │ (e.g. core.goose)      │
│ // CHECK: pattern      │      │ Zero test code bundled │
└────────────────────────┘      └────────────────────────┘
```

- **Pure Production Targets**: `core.goose` and `wing.goose` contain zero test runners, zero mocks, and zero assertion harnesses.
- **Out-of-Process Black-Box Execution**: Test suites are standalone `.goose` files executed as separate binaries. `goose-lit` verifies standard output streams against `// CHECK:` patterns.
- **Zero-Allocation Stream Verification**: Wire edge testing (`lit::verify_split_stream`) and fuzz mutation (`lit::mutate_stream`) operate purely on borrowed slices (`const u8[:]`) in isolated test binaries.

### Step-by-Step: Removing `core/test/` from `goose-wing`

Follow these steps to eliminate the `core/test/` footprint from `goose-wing`:

#### Step 1: Replace `core::test` Assertions with Native Assertions & Output

Migrate tests using custom assertions (`test::assert_eq`, `test::assert_true`) to native Goose `assert` statements or diagnostic `print` statements verified by FileCheck:

```goose
// Before (in-tree mock framework):
import core.test;
fn test_parser() {
    let res = parse_frame(buf);
    test::assert_eq(res.magic, 0x4757);
}

// After (zero-footprint LIT test):
// RUN: goose %s | %FileCheck %s
import std;
import wing;

fn main() {
    let res, ok = parse_frame(buf);
    assert(ok);
    print("MAGIC: ", res.magic);
}
// CHECK: MAGIC: 18263
```

#### Step 2: Migrate Wire Edge Testing to External `goose-lit`

For protocol framing and partial-slice edge testing, import `lit` only inside test files (e.g. `tests/lit/verify_wire.goose`), never in library sources:

```goose
// RUN: goose check %s
import std;
import lit from "tools/goose-lit";

fn test_framer() {
    let raw: u8[..4] = [0x01, 0x02, 0x03, 0x04];
    var diag: u8[>..] = [];
    let ok = lit::verify_split_stream(raw[..], -1, 0, diag, my_decoder);
    assert(ok);
}
```

#### Step 3: Remove `core/test/` Invocations and Directory

1. In `core.goose`, remove any test harness exports:
   ```diff
   - import core.test;
   ```
2. Remove the `core/test/` directory (`assert.goose`, `bridge.goose`, `context.goose`, `diff.goose`, `mock.goose`, `runner.goose`).
3. Verify typecheck cleanliness:
   ```bash
   goose check core.goose
   goose check wing.goose
   ```

---

## Continuous Integration Workflow (GitHub Actions)

Add the following workflow file (`.github/workflows/lit.yml`) to run tests and enforce G-CRAP safety gates in CI:

```yaml
name: Test Verification

on:
  push:
    branches: [main]
  pull_request:

jobs:
  verify:
    name: LIT & Gate (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: ubuntu-latest
            lit-bin: goose-lit
            archive: goose-lit-v0.1.0-linux-x64.tar.gz
            url: https://github.com/Lemon4ksan/goose-lit/releases/download/v0.1.0/goose-lit-v0.1.0-linux-x64.tar.gz
          - os: windows-latest
            lit-bin: goose-lit.exe
            archive: goose-lit-v0.1.0-windows-x64.zip
            url: https://github.com/Lemon4ksan/goose-lit/releases/download/v0.1.0/goose-lit-v0.1.0-windows-x64.zip

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      # Bootstrap Goose compiler
      - name: Install Goose (Linux)
        if: runner.os == 'Linux'
        run: |
          sudo mkdir -p /opt
          curl -sSL https://github.com/aardappel/goose/releases/download/v2026.3/goose-v2026.3-linux-x64.tar.gz | sudo tar -xz -C /opt
          sudo ln -sf /opt/goose-v2026.3-linux-x64/goose /usr/local/bin/goose

      - name: Install Goose (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          New-Item -ItemType Directory -Force -Path "$HOME\.goose" | Out-Null
          Invoke-WebRequest -Uri "https://github.com/aardappel/goose/releases/download/v2026.3/goose-v2026.3-windows-x64.zip" -OutFile "$HOME\.goose\goose.zip"
          Expand-Archive -Path "$HOME\.goose\goose.zip" -DestinationPath "$HOME\.goose\bin" -Force
          "$HOME\.goose\bin" | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append

      # Install prebuilt goose-lit
      - name: Install goose-lit (Linux)
        if: runner.os == 'Linux'
        run: |
          curl -sSL "${{ matrix.url }}" | tar -xz -C /usr/local/bin
          chmod +x /usr/local/bin/goose-lit

      - name: Install goose-lit (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          New-Item -ItemType Directory -Force -Path "$HOME\.goose-lit" | Out-Null
          Invoke-WebRequest -Uri "${{ matrix.url }}" -OutFile "$HOME\.goose-lit\lit.zip"
          Expand-Archive -Path "$HOME\.goose-lit\lit.zip" -DestinationPath "$HOME\.goose-lit" -Force
          "$HOME\.goose-lit" | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append

      # Execute verification
      - name: Run LIT test suites
        run: goose-lit tests/

      # Enforce G-CRAP complexity and bounds check safety gate
      - name: Enforce G-CRAP Gate
        run: goose-lit gate src/ 25.0 --cov 0.85
```

---

## Justfile Integration Recipes

Add these recipes to your project's `Justfile` for local developer workflow parity with CI:

```just
# Task runner recipes for LIT testing and G-CRAP gating

# Run all LIT test suites under target directory
[unix]
lit target="tests/":
    goose-lit {{target}}

[windows]
lit target="tests/":
    goose-lit.exe {{target}}

# Enforce hardware complexity and bounds safety gate (default ceiling 25.0)
[unix]
gate target="src/" max="25" cov="0.85":
    goose-lit gate {{target}} {{max}} --cov {{cov}}

[windows]
gate target="src/" max="25" cov="0.85":
    goose-lit.exe gate {{target}} {{max}} --cov {{cov}}

# Display G-CRAP risk radar table
[unix]
crap target="src/":
    goose-lit crap {{target}}

[windows]
crap target="src/":
    goose-lit.exe crap {{target}}

# Verify standard input against FileCheck directives in target file
filecheck target:
    goose-lit filecheck {{target}}
```

---

## Minimal Example Project Reference

A working minimal example project demonstrating zero-footprint testing with `goose-lit` is located in [`examples/basic_project`](../examples/basic_project/):

- [`examples/basic_project/sample.goose`](../examples/basic_project/sample.goose): Pure library module containing zero test dependencies or harnesses.
- [`examples/basic_project/tests/verify_sample.goose`](../examples/basic_project/tests/verify_sample.goose): External verification test specifying `// RUN: goose %s | %FileCheck %s` and pattern matching.
