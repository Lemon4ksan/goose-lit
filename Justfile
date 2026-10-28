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
[unix]
check:
    ./scripts/test_all.sh --check-only

[windows]
check:
    powershell -ExecutionPolicy Bypass -File .\scripts\test_all.ps1 -CheckOnly

# Run the full test suite
[unix]
test:
    ./scripts/test_all.sh

[windows]
test:
    powershell -ExecutionPolicy Bypass -File .\scripts\test_all.ps1

# Run LIT test runner over tests/
[unix]
lit:
    ./bin/goose-lit tests/

[windows]
lit:
    .\bin\goose-lit.exe tests/

# Format all Goose source files
fmt:
    goose format .

# Verify Goose source formatting without modifying files
fmt-check:
    goose format --check .
