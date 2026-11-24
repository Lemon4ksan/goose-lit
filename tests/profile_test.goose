// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/profile_test.goose - Verifies stage profiler, %prof_hook interposition,
// testing.B bench suite, and `goose-lit profile` CLI with --save/--compare.
//
// RUN: %lit profile %s --cc gcc --benchtime 5 --save %t.tsv --compare %t.tsv | %FileCheck %s
// CHECK: Bench_Sum
// CHECK: Bench_Parent/Sub_Work
// CHECK: goose-lit Benchstat Delta

import std;
import lit from "..";

fn work_loop(iters: i64) -> i64 {
    var acc: i64 = 0;
    for i in iters {
        acc += i;
    }
    return acc;
}

fn main() {
    let c0 = lit::prof_rdtsc();
    let s = work_loop(256);
    let c1 = lit::prof_rdtsc();
    assert(c1 >= c0 && s > 0);

    var suite = lit::new_bench_suite("goose-lit Profile Test", 5);
    lit::bench(suite, "Bench_Sum") { b =>
        lit::bench_set_bytes(b, 64);
        var acc: i64 = 0;
        for _ in b.n {
            lit::prof_span("stage.sum") {
                acc += work_loop(32);
            };
        }
        assert(acc > 0);
    };

    lit::bench(suite, "Bench_Parent") { b =>
        lit::bench_run(b, "Sub_Work") { sb =>
            var acc: i64 = 0;
            for _ in sb.n {
                acc += work_loop(16);
            }
            assert(acc > 0);
        };
    };

    lit::finish_bench_suite(suite);
}
