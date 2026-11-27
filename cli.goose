// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// goose-lit CLI facade: re-exports the lightweight lit library alongside the
// LIT directive runner, FileCheck matcher, G-CRAP analyzer, branch coverage
// collector, stage profiler CLI, SanCov/libFuzzer driver, and cycles-vs-SLOC engine.
namespace lit;

import std;

// ---- lightweight test library facade ---------------------------------------
import lit;

// ---- process execution, byte helpers & configuration -----------------------
import sys.bytes;
import sys.proc;
import sys.config;

// ---- filecheck verification engine -----------------------------------------
import check.filecheck;

// ---- lit runner, parallel check & verify engines ---------------------------
import runner.lit_runner;
import runner.check_cli;
import runner.verify_cli;

// ---- integrated goose-crap safety radar ------------------------------------
import crap.crap;

// ---- real coverage, stage profiler & coverage-guided fuzz CLI engines ------
import cov.cli;
import profile.cli;
import fuzz.cli;

// ---- cycles-vs-SLOC engine -------------------------------------------------
import sloc.model;
import sloc.scanner;
import sloc.correlate;
import sloc.baseline;
import sloc.report;
import sloc.cli;
