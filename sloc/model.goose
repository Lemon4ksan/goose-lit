// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// sloc/model.goose - Data structures and constants for cycles-vs-SLOC analysis.
namespace lit;

import std;

// Pareto / ratchet verdict codes (ordered by severity precedence)
let SLOC_VERDICT_UNCHANGED:             u8 = 0;
let SLOC_VERDICT_PARETO_WIN:            u8 = 1;
let SLOC_VERDICT_PERF_WIN_BLOAT_WARN:   u8 = 2;
let SLOC_VERDICT_REGRESSION:            u8 = 3;
let SLOC_VERDICT_SLOC_WIN_PERF_REGRESS: u8 = 4;
let SLOC_VERDICT_GAMING_DETECTED:       u8 = 5;

// Diagnostic cycles/SLOC radar classes
let SLOC_RADAR_UNPROFILED: u8 = 0;
let SLOC_RADAR_COLD_BLOAT: u8 = 1;
let SLOC_RADAR_BALANCED:   u8 = 2;
let SLOC_RADAR_HOT_KERNEL: u8 = 3;

// Scope mapping kinds
let SLOC_SCOPE_BENCH: u8 = 1;
let SLOC_SCOPE_STAGE: u8 = 2;

fn sloc_verdict_name(v: u8) -> const u8[:] {
    if v == SLOC_VERDICT_PARETO_WIN { return "PARETO_WIN"; }
    if v == SLOC_VERDICT_PERF_WIN_BLOAT_WARN { return "PERF_WIN_BLOAT_WARN"; }
    if v == SLOC_VERDICT_REGRESSION { return "REGRESSION"; }
    if v == SLOC_VERDICT_SLOC_WIN_PERF_REGRESS { return "SLOC_WIN_PERF_REGRESS"; }
    if v == SLOC_VERDICT_GAMING_DETECTED { return "GAMING_DETECTED"; }
    return "UNCHANGED";
}

fn sloc_radar_name(r: u8) -> const u8[:] {
    if r == SLOC_RADAR_HOT_KERNEL { return "HOT_KERNEL"; }
    if r == SLOC_RADAR_BALANCED { return "BALANCED"; }
    if r == SLOC_RADAR_COLD_BLOAT { return "COLD_BLOAT"; }
    return "UNPROFILED";
}

struct FileSlocStats {
    path_off:                i32  = 0,
    path_len:                i32  = 0,
    raw_lines:               i64  = 0,
    sloc:                    i64  = 0,
    comment_lines:           i64  = 0,
    stmts:                   i64  = 0,
    tokens:                  i64  = 0,
    packing_x100:            i64  = 0,
    tok_density_x100:        i64  = 0,
    bce_kept:                i64  = -1,
    bce_elided:              i64  = 0,
    smell_u64_loop:          i64  = 0,
    smell_sat_loop:          i64  = 0,
    smell_val_copy_for:      i64  = 0,
    smell_manual_while:      i64  = 0,
    smell_multiret_inline:   i64  = 0,
    smells_total:            i64  = 0,
    packing_violation:       bool = false,
    packing_delta_violation: bool = false,
    tok_density_violation:   bool = false,
}

struct DirSlocStats {
    dir_off:       i32 = 0,
    dir_len:       i32 = 0,
    files:         i64 = 0,
    sloc:          i64 = 0,
    stmts:         i64 = 0,
    tokens:        i64 = 0,
    comment_lines: i64 = 0,
    smells_total:  i64 = 0,
}

struct DeadFnCandidate {
    file_off: i32 = 0,
    file_len: i32 = 0,
    name_off: i32 = 0,
    name_len: i32 = 0,
    line:     i32 = 0,
}

struct ScopeMapping {
    name_off:     i32 = 0,
    name_len:     i32 = 0,
    kind:         u8  = 0,
    prefixes_off: i32 = 0,
    prefixes_len: i32 = 0,
    bench_off:    i32 = 0,
    bench_len:    i32 = 0,
}

struct ProfileSample {
    kind:       u8       = 0, // 1 = bench, 2 = stage
    case_name:  u8[..96] = [],
    stage_name: u8[..96] = [],
    calls:      i64      = 0,
    cycles_x10: i64      = 0,
    scratch_b:  i64      = 0,
}

struct CycleSlocRow {
    map_idx:             i32 = -1,
    name_off:            i32 = 0,
    name_len:            i32 = 0,
    kind:                u8  = 0,
    files:               i64 = 0,
    sloc:                i64 = 0,
    stmts:               i64 = 0,
    cycles_x10:          i64 = 0,
    cyc_per_sloc_x100:   i64 = 0,
    cyc_per_stmt_x100:   i64 = 0,
    cl_x10:              i64 = 0,
    radar:               u8  = 0,
    base_sloc:           i64 = 0,
    base_cycles_x10:     i64 = 0,
    norm_cl_x1000:       i64 = 0,
    verdict:             u8  = 0,
    hot_growth_credited: i64 = 0,
}

struct SlocBaselineFile {
    path_off:      i32 = 0,
    path_len:      i32 = 0,
    sloc:          i64 = 0,
    stmts:         i64 = 0,
    tokens:        i64 = 0,
    comment_lines: i64 = 0,
    packing_x100:  i64 = 0,
    bce_kept:      i64 = -1,
    smells_total:  i64 = 0,
}

struct SlocBaselineScope {
    name_off:          i32 = 0,
    name_len:          i32 = 0,
    kind:              u8  = 0,
    sloc:              i64 = 0,
    stmts:             i64 = 0,
    cycles_x10:        i64 = 0,
    cyc_per_sloc_x100: i64 = 0,
    cl_x10:            i64 = 0,
}

struct SlocBaseline {
    loaded:         bool = false,
    bce_measured:   bool = false,
    total_files:    i64  = 0,
    total_sloc:     i64  = 0,
    total_stmts:    i64  = 0,
    total_tokens:   i64  = 0,
    total_comments: i64  = 0,
    total_bce_kept: i64  = -1,
    total_smells:   i64  = 0,
}

struct SlocAuditDelta {
    has_baseline:           bool = false,
    base_sloc:              i64  = 0,
    cur_sloc:               i64  = 0,
    delta_sloc:             i64  = 0,
    delta_stmts:            i64  = 0,
    delta_tokens:           i64  = 0,
    delta_comments:         i64  = 0,
    delta_smells:           i64  = 0,
    delta_bce_kept:         i64  = 0,
    bce_compared:           bool = false,
    bce_skipped_unmeasured: bool = false,
    packing_violations:     i64  = 0,
    format_violations:      i64  = 0,
    hot_growth_credit_sum:  i64  = 0,
}

struct SlocGateResult {
    verdict:   u8             = 0,
    exit_code: i32            = 0,
    audit:     SlocAuditDelta = SlocAuditDelta { .. },
    reason:    u8[..512]      = [],
}

struct SlocCliArgs {
    map_path:            u8[..256]  = [],
    explicit_map:        bool       = false,
    run_profile_all:     bool       = false,
    cc:                  u8[..256]  = [],
    benchtime:           u8[..32]   = [],
    filter:              u8[..128]  = [],
    bce_enabled:         bool       = false,
    exclude_blob:        u8[..1024] = [],
    has_custom_exclude:  bool       = false,
    baseline_path:       u8[..256]  = [],
    explicit_baseline:   bool       = false,
    no_baseline:         bool       = false,
    save_baseline:       bool       = false,
    save_baseline_path:  u8[..256]  = [],
    reset_cycles:        bool       = false,
    sloc_delta:          i64        = 0,
    cycle_noise:         f64        = 5.0,
    allow_hot_growth:    bool       = false,
    check_packing:       bool       = false,
    max_packing:         f64        = 1.35,
    max_token_density:   f64        = 0.0,
    check_smells:        bool       = true,
    explicit_smell_flag: bool       = false,
    check_format:        bool       = false,
    show_smells:         bool       = false,
    include_tests:       bool       = false,
    format:              u8[..32]   = [],
    out_path:            u8[..256]  = [],
}
