#!/usr/bin/env bash

# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Lemon4ksan

# scripts/test_all.sh - Test runner and verification script for goose-lit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

CHECK_ONLY=0
if [[ "${1:-}" == "--check-only" ]]; then
    CHECK_ONLY=1
fi

echo "goose-lit verification runner"

# 1. Typecheck library and CLI
echo -e "\n[1/4] Typechecking lit.goose, bin.goose & tests..."
goose check lit.goose
goose check bin.goose
goose check tests/auto_runner_test.goose
goose check tests/bench_test.goose
goose check tests/config_test.goose
goose check tests/filecheck_test.goose
goose check tests/gate_test.goose
goose check tests/inspect_test.goose
goose check tests/pipeline_test.goose
goose check tests/standalone_unit_test.goose
goose check tests/testkit_test.goose
goose check tests/wire_test.goose
echo "  OK: lit.goose, bin.goose & tests typechecked cleanly."

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    echo -e "\nTypecheck Complete: 100% Valid."
    exit 0
fi

# 2. Build native binary
echo -e "\n[2/4] Building native bin/goose-lit..."
mkdir -p bin
goose build -O2 -o bin/goose-lit bin.goose
echo "  OK: Built bin/goose-lit."

# 3. Run LIT test suite
echo -e "\n[3/4] Running LIT test suite..."
./bin/goose-lit tests

# 4. Verifying G-CRAP integration
echo -e "\n[4/4] Verifying G-CRAP integration..."
./bin/goose-lit crap tests/pipeline_test.goose

echo -e "\nAll goose-lit verification gates passed successfully!"
