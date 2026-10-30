#!/usr/bin/env bash

# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Lemon4ksan

# scripts/test_all.sh - Test runner and verification script for goose-lit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

PYTHON_BIN="python3"
if ! command -v python3 &> /dev/null; then
    PYTHON_BIN="python"
fi

exec "${PYTHON_BIN}" tools/test_runner.py "$@"
