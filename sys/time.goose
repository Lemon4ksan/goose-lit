// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// High-resolution monotonic clock and stopwatch primitives for lit tests and benchmarks.
namespace lit;

import std;
import os;

struct Duration {
    nanos: i64 = 0,
}

fn as_micros(dur: Duration) -> i64 { return dur.nanos / 1000; }

struct MonotonicInstant {
    nanos: u64 = 0,
}

fn monotonic_now() -> MonotonicInstant {
    return MonotonicInstant { nanos: max(0, clock_ns()) as u64 };
}

struct Stopwatch {
    start_ns: i64 = 0,
}

fn stopwatch() -> Stopwatch {
    return Stopwatch { start_ns: clock_ns() };
}

fn elapsed(watch: const Stopwatch&) -> Duration {
    return Duration { nanos: clock_ns() - watch.start_ns };
}
