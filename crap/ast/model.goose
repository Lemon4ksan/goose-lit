// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Data structures for AST functions, control-flow branch sites, and G-CRAP metrics.
namespace crap;

import std;
import sys.bytes;

// Branch site kinds
let BRANCH_FN_ENTRY:   u8 = 1;
let BRANCH_IF_THEN:    u8 = 2;
let BRANCH_IF_ELSE:    u8 = 3;
let BRANCH_GUARD_PASS: u8 = 4;
let BRANCH_GUARD_FAIL: u8 = 5;
let BRANCH_LOOP_BODY:  u8 = 6;
let BRANCH_LOOP_EXIT:  u8 = 7;
let BRANCH_MATCH_ARM:  u8 = 8;

// Branch semantic classification tags
let BRANCH_CLASS_DEFAULT:      u8 = 0;
let BRANCH_CLASS_GUARD_CHECK:  u8 = 1;
let BRANCH_CLASS_SPEC_MATCH:   u8 = 2;
let BRANCH_CLASS_BOUNDS_CHECK: u8 = 3;
let BRANCH_CLASS_DEFENSIVE:    u8 = 4;
let BRANCH_CLASS_IF_ELSE:      u8 = 5;

// Trust boundary classification
let TRUST_TRUSTED:   u8 = 0;
let TRUST_UNTRUSTED: u8 = 1;

// Analysis completion tri-state
let ANALYSIS_NOT_REQUESTED: u8 = 0;
let ANALYSIS_COMPLETE:      u8 = 1;
let ANALYSIS_FAILED:        u8 = 2;

// Diagnostic engineering archetypes
let ARCHETYPE_VERIFIED_DISPATCH: u8 = 1;
let ARCHETYPE_VERIFIED_FSM:      u8 = 1; // backwards compatibility alias
let ARCHETYPE_PANIC_HAZARD:      u8 = 2;
let ARCHETYPE_FUZZ_PRIORITY:     u8 = 3;
let ARCHETYPE_SAFE_PRIMITIVE:    u8 = 4;
let ARCHETYPE_DEAD_CODE_AUDIT:   u8 = 5;
let ARCHETYPE_LOW_PRIORITY:      u8 = 6;

struct BranchSite {
    branch_id:         i32  = 0,
    func_idx:          i32  = 0,
    kind:              u8   = 0,
    classification:    u8   = 0,
    parent_branch:     i32  = -1,
    depth:             i32  = 1,
    start_line:        i32  = 1,
    end_line:          i32  = 1,
    probe_byte_offset: i32  = -1,
    body_close_offset: i32  = -1,
    needs_synth_else:  bool = false,
    bce_keep:          i32  = 0,
    bce_elide:         i32  = 0,
    bce_inlined:       i32  = 0,
    trusted_bounds:    bool = false,
    ovf_ops:           i32  = 0,
    hits:              u64  = 0,
    covered:           bool = false,
}

struct CallSite {
    caller_idx:      i32 = -1,
    callee_name_off: i32 = 0,
    callee_name_len: i32 = 0,
    line:            i32 = 0,
}

struct FunctionInfo {
    func_idx:         i32 = 0,
    name_off:         i32 = 0,
    name_len:         i32 = 0,
    qual_off:         i32 = 0,
    qual_len:         i32 = 0,
    file_off:         i32 = 0,
    file_len:         i32 = 0,
    start_line:       i32 = 1,
    end_line:         i32 = 1,
    body_open_offset: i32 = 0,

    // Structural complexity
    cyclomatic_cc: i32 = 1,
    cognitive_cc:  i32 = 0,
    effective_cc:  i32 = 1,
    max_depth:     i32 = 0,
    match_blocks:  i32 = 0,
    match_arms:    i32 = 0,
    loops_count:   i32 = 0,
    guards_count:  i32 = 0,

    // Branch range in Workspace.branches
    first_branch:     i32 = 0,
    branch_count:     i32 = 0,
    covered_branches: i32 = 0,
    cov_branch:       f64 = 0.0,

    // Compiler safety invariants (--bce-lines & --specs)
    total_bce_keep:     i32  = 0,
    total_bce_elide:    i32  = 0,
    total_bce_inlined:  i32  = 0,
    uncovered_bce_keep: i32  = 0,
    total_ovf_ops:      i32  = 0,
    uncovered_ovf_ops:  i32  = 0,
    specs_count:        i32  = 0,
    max_spec_nodes:     i32  = 0,
    compiler_nest:      i32  = 0,
    has_noinline:       bool = false,

    // Trust model & flags
    trust_class:            u8   = 0,
    taint_depth:            i32  = -1,
    takes_wire_slice:       bool = false,
    is_generic:             bool = false,
    uninstantiated_generic: bool = false,
    ignored:                bool = false,

    // Calculated risk scores
    classic_crap:  f64 = 0.0,
    risk_struct:   f64 = 0.0,
    risk_safety:   f64 = 0.0,
    g_crap:        f64 = 0.0,
    fuzz_priority: f64 = 0.0,
    archetype:     u8  = 6,
}

struct RiskConfig {
    alpha_bce_keep:       f64  = 25.0,
    beta_ovf:             f64  = 15.0,
    untrusted_weight:     f64  = 1.5,
    classic_threshold:    f64  = 30.0,
    gcrap_threshold:      f64  = 25.0,
    has_coverage_profile: bool = false,
    bce_state:            u8   = 1,
}

fn default_risk_config() -> RiskConfig {
    return RiskConfig {
        alpha_bce_keep:       25.0,
        beta_ovf:             15.0,
        untrusted_weight:     1.5,
        classic_threshold:    30.0,
        gcrap_threshold:      25.0,
        has_coverage_profile: false,
        bce_state:            1,
    };
}

fn pool_add(pool: u8[>..]&, s: const u8[:]) -> i32, i32 {
    let off = pool.len as i32;
    pool.append(s);
    return off, s.len as i32;
}

fn pool_slice(pool: const u8[:], off: i32, length: i32) -> const u8[:] {
    guard off >= 0 && length >= 0 && off + length <= (pool.len as i32) else {
        return "";
    }
    let start: i64 = off;
    let end:   i64 = off + length;
    return pool[start..end];
}

fn branch_kind_name(kind: u8) -> const u8[:] {
    if kind == BRANCH_FN_ENTRY { return "fn_entry"; }
    if kind == BRANCH_IF_THEN { return "if_then"; }
    if kind == BRANCH_IF_ELSE { return "if_else"; }
    if kind == BRANCH_GUARD_PASS { return "guard_pass"; }
    if kind == BRANCH_GUARD_FAIL { return "guard_fail"; }
    if kind == BRANCH_LOOP_BODY { return "loop_body"; }
    if kind == BRANCH_LOOP_EXIT { return "loop_exit"; }
    if kind == BRANCH_MATCH_ARM { return "match_arm"; }
    return "branch";
}

fn branch_class_name(cls: u8) -> const u8[:] {
    if cls == BRANCH_CLASS_GUARD_CHECK { return "precondition_guard"; }
    if cls == BRANCH_CLASS_SPEC_MATCH { return "spec_match_arm"; }
    if cls == BRANCH_CLASS_BOUNDS_CHECK { return "bounds_check_hazard"; }
    if cls == BRANCH_CLASS_DEFENSIVE { return "defensive_invariant"; }
    if cls == BRANCH_CLASS_IF_ELSE { return "fallback_else"; }
    return "branch_path";
}

fn archetype_label(arch: u8) -> const u8[:] {
    if arch == ARCHETYPE_VERIFIED_DISPATCH {
        return "Verified dispatch / state table (high coverage; splitting discouraged)";
    }
    if arch == ARCHETYPE_PANIC_HAZARD {
        return "Runtime panic hazard (uncovered bce:keep)";
    }
    if arch == ARCHETYPE_FUZZ_PRIORITY {
        return "Priority #1 target for spec tests & fuzzing";
    }
    if arch == ARCHETYPE_SAFE_PRIMITIVE {
        return "Safe high-performance primitive";
    }
    if arch == ARCHETYPE_DEAD_CODE_AUDIT {
        return "Audit uncovered branches (dead code vs missing test vector)";
    }
    return "Low priority utility";
}

fn archetype_short(arch: u8) -> const u8[:] {
    if arch == ARCHETYPE_VERIFIED_DISPATCH { return "VERIFIED_DISPATCH"; }
    if arch == ARCHETYPE_PANIC_HAZARD { return "PANIC_HAZARD"; }
    if arch == ARCHETYPE_FUZZ_PRIORITY { return "FUZZ_TARGET"; }
    if arch == ARCHETYPE_SAFE_PRIMITIVE { return "SAFE_PRIM"; }
    if arch == ARCHETYPE_DEAD_CODE_AUDIT { return "AUDIT_BRANCH"; }
    return "LOW_PRIORITY";
}
