// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// goose-lit: LLVM-grade Integrated Test Harness, FileCheck & Risk Runtime for Goose.
// Combines directive runner, FileCheck matcher, binary wire verification,
// sandboxed contained execution, and G-CRAP complexity/safety radar.
namespace lit;

import std;

// ---- core systems & test utilities -----------------------------------------
import core.bytes;
import core.proc;
import core.time;
import core.config;

// ---- filecheck verification engine ----------------------------------------
import check.filecheck;

// ---- packet edge & stream mutator -----------------------------------------
import wire.edge;
import wire.mutate;
import wire.inspect;

// ---- in-process unit testkit, assertions, mocks & sandbox ------------------
import testkit.context;
import testkit.diff;
import testkit.assert;
import testkit.mock;
import testkit.runner;
import testkit.testkit;
import testkit.bench;

// ---- lit runner engine ----------------------------------------------------
import runner.lit_runner;

// ---- integrated goose-crap safety radar -----------------------------------
import crap.crap;
