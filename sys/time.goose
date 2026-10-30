// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// High-resolution monotonic clock, duration arithmetic, and stopwatch utilities.
namespace lit;

import std;
import os;

const NANOSECOND:  i64 = 1;
const MICROSECOND: i64 = 1000 * NANOSECOND;
const MILLISECOND: i64 = 1000 * MICROSECOND;
const SECOND:      i64 = 1000 * MILLISECOND;
const MINUTE:      i64 = 60 * SECOND;
const HOUR:        i64 = 60 * MINUTE;
const DAY:         i64 = 24 * HOUR;

struct Duration {
    nanos: i64 = 0,
}

fn nanos(n: i64) -> Duration { return Duration { nanos: n }; }
fn micros(m: i64) -> Duration { return Duration { nanos: m * MICROSECOND }; }
fn millis(m: i64) -> Duration { return Duration { nanos: m * MILLISECOND }; }
fn secs(s: i64) -> Duration { return Duration { nanos: s * SECOND }; }
fn mins(m: i64) -> Duration { return Duration { nanos: m * MINUTE }; }
fn hours(h: i64) -> Duration { return Duration { nanos: h * HOUR }; }

fn as_nanos(dur: Duration) -> i64 { return dur.nanos; }
fn as_micros(dur: Duration) -> i64 { return dur.nanos / MICROSECOND; }
fn as_millis(dur: Duration) -> i64 { return dur.nanos / MILLISECOND; }
fn as_secs(dur: Duration) -> i64 { return dur.nanos / SECOND; }
fn as_secs_f64(dur: Duration) -> f64 { return dur.nanos / 1000000000.0; }

fn add(d1: Duration, d2: Duration) -> Duration { return d1 + d2; }
fn sub(d1: Duration, d2: Duration) -> Duration { return d1 - d2; }
fn mul(d: Duration, factor: i64) -> Duration { return d * factor; }
fn div(d: Duration, factor: i64) -> Duration { return d / factor; }

struct MonotonicInstant {
    nanos: u64 = 0,
}

fn monotonic_now() -> MonotonicInstant {
    let raw_ns = clock_ns();
    return MonotonicInstant { nanos: if raw_ns > 0 { raw_ns as u64 } else { 0 } };
}

fn new_monotonic_instant(nanos_val: u64) -> MonotonicInstant {
    return MonotonicInstant { nanos: nanos_val };
}

fn as_nanos(inst: MonotonicInstant) -> u64 {
    return inst.nanos;
}

fn duration_since(now_inst: MonotonicInstant, anchor: MonotonicInstant) -> Duration {
    if now_inst.nanos <= anchor.nanos {
        return Duration { nanos: 0 };
    }
    let diff = now_inst.nanos - anchor.nanos;
    let max_i64 = 9223372036854775807 as u64;
    let clamped = if diff > max_i64 { max_i64 } else { diff };
    return Duration { nanos: clamped as i64 };
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

fn restart(watch: Stopwatch&) -> Duration {
    let now_ns = clock_ns();
    let elapsed_dur = Duration { nanos: now_ns - watch.start_ns };
    watch.start_ns = now_ns;
    return elapsed_dur;
}
