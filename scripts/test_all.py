#!/usr/bin/env python3

# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Lemon4ksan

"""
scripts/test_all.py - Cross-platform verification runner for goose-lit.

Delegates execution to tools/test_runner.py.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "tools"))

from test_runner import main

if __name__ == "__main__":
    sys.exit(main())
