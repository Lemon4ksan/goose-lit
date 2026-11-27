// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// goose-lit public library facade (namespace lit only): in-process testkit,
// assertions, mocks, allocation counter, stage profiler / testing.B benchmarks,
// and binary wire verification. Internal CLI engines (runner, FileCheck, G-CRAP,
// coverage, profiler/fuzzer/SLOC CLIs, and namespace crap) live in cli.goose.
namespace lit;

import std;

// ---- monotonic clock & stopwatch primitives --------------------------------
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
