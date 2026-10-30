# Integrating goose-lit into Goose projects

This guide covers CI workflows, Justfile recipes, and how to test Goose libraries without compiling test frameworks into production binaries.

## Zero-footprint testing

### Problems with bundled test frameworks

When a library exports test harnesses from its core modules (for example, `core/test/` imported inside `core.goose`):
- Assertion helpers, string formatters, and mock structs compile into release binaries.
- Tests written against internal mock structures do not verify raw wire bytes, which can mask framing bugs and slice boundary errors.
- Test utilities clutter the public module namespace.

### The zero-footprint model

In this model:
- Production modules contain no test runners, mocks, or assertion functions.
- Test files are standalone `.goose` programs executed as separate processes. goose-lit verifies standard output against `// CHECK:` patterns.
- Stream verification (`lit::verify_split_stream`) and mutation (`lit::mutate_stream`) run only in test binaries.

### Removing in-tree test code

Follow these steps to eliminate an in-tree test directory:

#### Step 1: Replace custom assertions with native assertions or print statements

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

#### Step 2: Move wire tests to external test files

For protocol framing and partial-slice tests, import `lit` inside test files (e.g. `tests/lit/verify_wire.goose`), not in library sources:

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

#### Step 3: Delete the test directory and remove the import

1. In the main module, remove the test import:
   ```diff
   - import core.test;
   ```
2. Remove the `core/test/` directory (`assert.goose`, `bridge.goose`, `context.goose`, `diff.goose`, `mock.goose`, `runner.goose`).
3. Verify typecheck cleanliness:
   ```bash
   goose check core.goose
   goose check wing.goose
   ```

## Continuous integration workflow

Add this workflow (`.github/workflows/lit.yml`) to run tests and enforce G-CRAP safety gates in GitHub Actions:

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

## Justfile recipes

Add these recipes to your project's `Justfile` for local testing:

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

## Example project

A minimal example project is located in [`examples/basic_project`](../examples/basic_project/):
- [`examples/basic_project/sample.goose`](../examples/basic_project/sample.goose): library module with no test dependencies.
- [`examples/basic_project/tests/verify_sample.goose`](../examples/basic_project/tests/verify_sample.goose): external verification test specifying `// RUN: goose %s | %FileCheck %s`.
