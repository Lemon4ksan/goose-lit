#!/usr/bin/env python3

# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Lemon4ksan

"""
goose-lit Cross-Platform Test Runner.

Provides typechecking, compilation, and execution for all test suites
across Windows, Linux, and macOS.
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

_IS_TTY = sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def _c(text: str, code: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _IS_TTY else text


def cyan(text: str) -> str:
    return _c(text, "36")


def green(text: str) -> str:
    return _c(text, "32")


def yellow(text: str) -> str:
    return _c(text, "33")


def red(text: str) -> str:
    return _c(text, "31")


def bold(text: str) -> str:
    return _c(text, "1")


def find_goose_binary() -> str:
    binary = shutil.which("goose")
    if binary:
        return binary
    home = Path.home()
    if platform.system() == "Windows":
        goose_root = home / ".goose"
        if goose_root.is_dir():
            for cand_dir in sorted(goose_root.glob("goose-*-windows-x64"), reverse=True):
                cand = cand_dir / "goose.exe"
                if cand.exists():
                    return str(cand)
    return "goose"


def run_command(cmd: list[str], cwd: Path | None = None) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        return proc.returncode, proc.stdout, proc.stderr
    except Exception as ex:
        return 1, "", str(ex)


def main() -> int:
    parser = argparse.ArgumentParser(description="goose-lit test runner")
    parser.add_argument("--pattern", default="*", help="Filter test files by glob pattern")
    parser.add_argument(
        "--check-only",
        "--check_only",
        "-CheckOnly",
        dest="check_only",
        action="store_true",
        help="Only typecheck without executing",
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    args = parser.parse_args()

    root_dir = Path(__file__).resolve().parent.parent
    tests_dir = root_dir / "tests"
    lit_file = root_dir / "lit.goose"
    cli_file = root_dir / "cli.goose"
    bin_file = root_dir / "bin.goose"

    goose = find_goose_binary()

    if platform.system() == "Windows":
        gcc_noavx = root_dir / "tools" / "gcc_noavx.cmd"
        if gcc_noavx.exists():
            os.environ.setdefault("GOOSE_CC", str(gcc_noavx))

    print(cyan(bold("goose-lit test runner")))

    # 1. Typecheck library and CLI
    print(f"\n{yellow('[1/4] Typechecking lit.goose, cli.goose, and bin.goose...')}")
    t0_check = time.perf_counter()

    for target in [lit_file, cli_file, bin_file]:
        code, out, err = run_command([goose, "check", str(target)], cwd=root_dir)
        if code != 0:
            print(red(f"FATAL: goose check {target.name} failed!"))
            if out:
                print(yellow(out))
            if err:
                print(red(err))
            return 1

    dt_check_ms = int((time.perf_counter() - t0_check) * 1000)
    print(green(f"  OK: lit.goose, cli.goose, and bin.goose typechecked cleanly in {dt_check_ms}ms."))

    # 2. Discover test files
    if not tests_dir.exists():
        print(red(f"Tests directory not found: {tests_dir}"))
        return 1

    all_test_files = [
        f for f in sorted(tests_dir.glob("*.goose")) if fnmatch.fnmatch(f.name, args.pattern)
    ]

    if not all_test_files:
        print(yellow(f"No tests matched pattern: {args.pattern}"))
        return 0

    print(f"\n{yellow(f'[2/4] Checking {len(all_test_files)} test suites...')}")
    t0_tests = time.perf_counter()
    for tf in all_test_files:
        code, out, err = run_command([goose, "check", str(tf)], cwd=root_dir)
        if code != 0:
            print(red(f"FATAL: goose check tests/{tf.name} failed!"))
            if out:
                print(yellow(out))
            if err:
                print(red(err))
            return 1

    dt_tests_ms = int((time.perf_counter() - t0_tests) * 1000)
    print(green(f"  OK: {len(all_test_files)} test files typechecked cleanly in {dt_tests_ms}ms."))

    if args.check_only:
        print(green("\nTypecheck complete: 100% valid."))
        return 0

    # 3. Build and execute via goose-lit binary
    print(f"\n{yellow('[3/4] Executing test suite via goose-lit...')}")
    exe_name = "goose-lit.exe" if platform.system() == "Windows" else "goose-lit"
    bin_path = root_dir / "bin" / exe_name

    if not bin_path.exists():
        print(yellow(f"Building {exe_name}..."))
        build_cmd = [goose, "build", "--cc", "gcc", "-O2", "-o", str(bin_path), str(bin_file)]
        code, out, err = run_command(build_cmd, cwd=root_dir)
        if code != 0:
            print(red(f"FATAL: Failed to build {exe_name}"))
            if out:
                print(yellow(out))
            if err:
                print(red(err))
            return 1

    lit_cmd = [str(bin_path), str(tests_dir)]
    if args.verbose:
        lit_cmd.append("--verbose")

    code, out, err = run_command(lit_cmd, cwd=root_dir)
    if out:
        print(out.strip())
    if err:
        print(red(err.strip()))

    if code != 0:
        print(red("\nTest execution failed."))
        return 1

    # 4. Verifying G-CRAP integration
    print(f"\n{yellow('[4/4] Verifying G-CRAP integration...')}")
    crap_cmd = [str(bin_path), "crap", str(tests_dir / "pipeline_test.goose")]
    code, out, err = run_command(crap_cmd, cwd=root_dir)
    if out:
        print(cyan(out.strip()))
    if err:
        print(red(err.strip()))

    if code != 0:
        print(red("\nG-CRAP verification failed."))
        return 1

    print(green("\nAll test suites passed successfully."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
