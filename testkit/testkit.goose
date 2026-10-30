// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// testkit/testkit.goose - In-process lightweight test harness and sandbox for Goose.
// Leverages Goose thread_spawn_contained and balanced data-stack invariants.
namespace lit;

import std;
import sys.bytes;

// Evaluates whether a contained worker exited cleanly without traps or aborts.
// Returns true if clean, or false with the exact abort message in out_diag.
fn wait_contained_result(worker_id: i64, out_diag: u8[>..]&) -> bool {
    var why: u8[>..] = [];
    let ok = thread_wait(worker_id, why);
    if !ok {
        out_diag.append("CONTAINED_WORKER FAILED: worker aborted:\n  ");
        out_diag.append(why[..]);
        out_diag.append("\n");
        return false;
    }
    return true;
}

// Verifies that a contained worker ABORTED with the expected message substring.
fn expect_contained_abort(worker_id: i64, expected_substr: const u8[:], out_diag: u8[>..]&) -> bool {
    var why: u8[>..] = [];
    let ok = thread_wait(worker_id, why);
    if ok {
        out_diag.append("EXPECT_ABORT FAILED: contained worker completed without expected abort\n");
        return false;
    }

    if expected_substr.len > 0 && !crap::slice_contains(why[..], expected_substr) {
        out_diag.append("EXPECT_ABORT FAILED: aborted with '");
        out_diag.append(why[..]);
        out_diag.append("', but expected substring '");
        out_diag.append(expected_substr);
        out_diag.append("'\n");
        return false;
    }

    return true;
}

// Verifies that a data stack or growable buffer call is balanced (Spec §5.2, §13).
fn assert_balanced<A, F: fn(A&)>(array: A&, out_diag: u8[>..]&) -> bool {
    let mark = array.len;
    F(array);
    if array.len != mark {
        out_diag.append("ASSERT_BALANCED FAILED: expected len ");
        format(out_diag, mark, ", but ended with ");
        format(out_diag, array.len, "\n");
        return false;
    }
    return true;
}
