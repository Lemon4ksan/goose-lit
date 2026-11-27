// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// goose-lit library facade: lightweight in-process testkit, assertions, mocks,
// allocation counter, stage profiler API, and binary wire verification.
// CLI engines (runner, FileCheck, G-CRAP, coverage, profiler/fuzzer/SLOC CLIs)
// reside in cli.goose so test imports do not compile CLI subsystems.
namespace lit;

import std;

// ---- core test utilities ---------------------------------------------------
import sys.bytes;
import sys.time;

// ---- packet edge, stream mutator & hex/SIMD inspector ----------------------
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
import testkit.alloc;
import testkit.profile;
