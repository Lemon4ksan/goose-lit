// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// testkit/alloc.goose - Runtime allocation counter & zero-alloc assertion harness.
//
// Events counted while enabled: slice-pool span allocations
// (gs_slice_pool_place/regrow, gs_spans_alloc/regrow) when compiled with
// `--include %alloc_hook` (or `--include %prof_hook`), plus explicit
// `alloc_note` taps. `alloc_mark`/`alloc_growth` sample the bump watermark of
// the data stack owning `probe`.
namespace lit;

import std;

extern fn alloc_reset() = "lit_alloc_reset";
extern fn alloc_disable() = "lit_alloc_disable";
extern fn alloc_events() -> u64 = "lit_alloc_events";
extern fn alloc_bytes() -> u64 = "lit_alloc_bytes";
extern fn alloc_frees() -> u64 = "lit_alloc_frees";
extern fn alloc_note(bytes: i64) = "lit_alloc_note";
extern fn alloc_mark(probe: u8[>..]&) -> u64 = "lit_alloc_mark";
extern fn alloc_growth(probe: u8[>..]&, mark: u64) -> i64 = "lit_alloc_growth";

// Runs `F` inside a counting window and verifies zero pool allocation events
// and zero surviving data-stack growth on `probe`'s stack.
fn verify_zero_allocs<F: fn()>(probe: u8[>..]&, out_diag: u8[>..]&) -> bool {
    alloc_reset();
    let mark = alloc_mark(probe);
    F();
    let events = alloc_events();
    let bytes = alloc_bytes();
    let growth = alloc_growth(probe, mark);
    alloc_disable();

    if events != 0 || growth != 0 {
        out_diag.append("ZERO_ALLOC FAILED: pool_events=");
        format(out_diag, events, " pool_bytes=", bytes, " stack_growth=", growth, " B\n");
        return false;
    }

    out_diag.append("ZERO_ALLOC OK: 0 pool events, 0 B data-stack growth\n");
    return true;
}
