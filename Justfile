# Task runner recipes for goose-lit

set windows-shell := ["powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass", "-Command"]

# List available recipes
default:
    @just --list

# Build the native goose-lit CLI binary
[unix]
build:
    goose build -O2 -o bin/goose-lit bin.goose

[windows]
build:
    goose build --cc gcc -O2 -o bin/goose-lit.exe bin.goose

# Typecheck library, CLI, and test suite without compiling binaries
check:
    python tools/test_runner.py --check-only

# Run test suites matching a pattern (defaults to all)
test pattern="*":
    python tools/test_runner.py --pattern "{{pattern}}"

# Run LIT test runner over tests/
[unix]
lit:
    ./bin/goose-lit tests/

[windows]
lit:
    .\bin\goose-lit.exe tests/

# Run hardware complexity gate check on target
[unix]
gate target="." max="25":
    ./bin/goose-lit gate {{target}} {{max}}

[windows]
gate target="." max="25":
    .\bin\goose-lit.exe gate {{target}} {{max}}

# Check SPDX Apache-2.0 license headers
license-check:
    python tools/licensing.py --check

# Apply missing SPDX Apache-2.0 license headers
license-fix:
    python tools/licensing.py --fix

# Format all Goose source files
fmt:
    goose format .

# Verify Goose source formatting without modifying files
fmt-check:
    goose format --check .
