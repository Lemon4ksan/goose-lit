// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: goose %s | %FileCheck %s
// RUN: %lit sloc --help | %FileCheck %s --prefix HELP
// RUN: %lit sloc %s --no-baseline --include-tests --smells --format json | %FileCheck %s --prefix JSON
// RUN: %lit sloc %s --no-baseline --include-tests --check-packing | %FileCheck %s --prefix PACK

// HELP: Usage: goose-lit sloc
// JSON: "verdict": "UNCHANGED"
// PACK: Verdict: UNCHANGED

import std;
import os;
import cli from "..";

fn test_sloc_and_guard_stmts() {
    let src: const u8[:] = "// leading comment\n\nextern fn ext_f(x: i64) = \"c_ext\";\nfn take_cb(cb: fn(i64), x: i64) -> bool {\n    // inline comment\n    guard x > 0 else { return false; }\n    let a = x + 1;\n    return a > 0;\n}\n";

    var pool: u8[>..] = [];
    var st = lit::FileSlocStats { .. };
    lit::scan_goose_sloc_src("sample/guard.goose", src, pool, st);

    assert(st.raw_lines == 9);
    assert(st.sloc == 6);
    assert(st.comment_lines == 2);
    // stmts: extern line has 1 ';', take_cb has 'fn'(1), guard line has 'guard'+';'(2, no 'else'),
    // let line has ';'(1), return line has ';'(1) => total 6
    assert(st.stmts == 6);
    assert(st.packing_x100 == 100);
    assert(st.smells_total == 0);
}

fn test_multiline_string_and_nested_comments() {
    let src: const u8[:] = "/* outer\n/* inner\n*/ still comment\n*/\nfn text() -> const u8[:] {\n    let s: const u8[:] = \"\"\"line1\nline2\nline3\"\"\";\n    return s;\n}\n";

    var pool: u8[>..] = [];
    var st = lit::FileSlocStats { .. };
    lit::scan_goose_sloc_src("sample/multi.goose", src, pool, st);

    assert(st.raw_lines == 10);
    assert(st.comment_lines == 4);
    assert(st.sloc == 6);
}

fn test_local_smells_detection() {
    let smelly: const u8[:] = "struct Item { val: i64 = 0 }\ninline fn pair_ret(v: i64) -> i64, bool {\n    return v, true;\n}\nfn bad(xs: const u8[:], items: const Item[:]) -> i64 {\n    var i: u64 = 0;\n    var acc: i64 = 0;\n    while i < xs.len {\n        acc = core::add_sat_i64(acc, 1);\n        i++;\n    }\n    for item in items {\n        acc += item.val;\n    }\n    return acc;\n}\n";

    var pool: u8[>..] = [];
    var st = lit::FileSlocStats { .. };
    lit::scan_goose_sloc_src("sample/smelly.goose", smelly, pool, st);

    assert(st.smell_u64_loop == 1);
    assert(st.smell_sat_loop == 1);
    assert(st.smell_val_copy_for == 1);
    assert(st.smell_manual_while == 1);
    assert(st.smell_multiret_inline == 1);
    assert(st.smells_total == 5);

    let clean: const u8[:] = "struct Item { val: i64 = 0 }\nfn good(xs: const u8[:], items: const Item[:]) -> i64 {\n    var arr: u64[4] = [0; 4];\n    var dyn_u: u64[>..] = [];\n    var acc: i64 = 0;\n    for i in xs.len {\n        acc += xs[i];\n    }\n    for &item in items {\n        acc += item.val;\n    }\n    return acc + (arr[0] as i64) + dyn_u.len;\n}\n";

    var clean_st = lit::FileSlocStats { .. };
    lit::scan_goose_sloc_src("sample/clean.goose", clean, pool, clean_st);
    assert(clean_st.smells_total == 0);
}

fn test_dead_fn_ignores_test_callers() {
    crap::ensure_lit_cache_dir();
    let root: const u8[:] = ".lit/cache/sloc_dead_test";
    let tdir: const u8[:] = ".lit/cache/sloc_dead_test/tests";
    let _ = make_dir(root);
    let _ = make_dir(tdir);

    let ship_path: const u8[:] = ".lit/cache/sloc_dead_test/mod.goose";
    let test_path: const u8[:] = ".lit/cache/sloc_dead_test/tests/mod_test.goose";
    let ship_src:  const u8[:] = "fn pub_api() -> i64 { return 1; }\nfn ufcs_helper(x: i64) -> i64 { return x; }\nfn orphan_fn() -> i64 { return 2; }\n";
    let test_src:  const u8[:] = "fn main() {\n    let a = pub_api();\n    let _ = a.ufcs_helper();\n}\n";
    assert(write_file(ship_path, ship_src));
    assert(write_file(test_path, test_src));

    var pool:      u8[>..]                   = [];
    var dead:      lit::DeadFnCandidate[>..] = [];
    var ship_blob: u8[>..]                   = [];
    ship_blob.append(ship_path);
    ship_blob.push('\n');
    lit::collect_repo_dead_fns(root, ship_blob[..], pool, dead);

    var saw_orphan = false;
    var saw_pub = false;
    var saw_ufcs = false;
    for &d in dead {
        let name = crap::pool_slice(pool[..], d.name_off, d.name_len);
        if name == "orphan_fn" { saw_orphan = true; }
        if name == "pub_api" { saw_pub = true; }
        if name == "ufcs_helper" { saw_ufcs = true; }
    }

    let _ = crap::native_remove_tree(root);
    assert(saw_orphan);
    assert(!saw_pub);
    assert(!saw_ufcs);
}

fn test_sloc_map_and_crlf() {
    let raw_map: const u8[:] = "# comment line\r\nL0_GET | bench | http\\, wire\\ | bench\\server.goose\r\n*::http1.parse | stage | http/\r\n";
    var pool: u8[>..]                = [];
    var maps: lit::ScopeMapping[>..] = [];
    let count = lit::parse_sloc_map(raw_map, pool, maps);
    assert(count == 2);
    assert(crap::pool_slice(pool[..], maps[0].name_off, maps[0].name_len) == "L0_GET");
    assert(maps[0].kind == lit::SLOC_SCOPE_BENCH);
    assert(crap::pool_slice(pool[..], maps[0].prefixes_off, maps[0].prefixes_len) == "http/,wire/");
    assert(crap::pool_slice(pool[..], maps[0].bench_off, maps[0].bench_len) == "bench/server.goose");

    assert(crap::pool_slice(pool[..], maps[1].name_off, maps[1].name_len) == "*::http1.parse");
    assert(maps[1].kind == lit::SLOC_SCOPE_STAGE);
    assert(crap::pool_slice(pool[..], maps[1].prefixes_off, maps[1].prefixes_len) == "http/");
    assert(maps[1].bench_len == 0);
}

fn test_correlate_bench_and_stages() {
    let map_src: const u8[:] = "Hot_Case | bench | hot/\nBal_Case | bench | bal/\nCold_Case | bench | cold/\nMiss_Case | bench | miss/\nHot_Case::stage.a | stage | hot/\n*::stage.a | stage | hot/\n";
    var pool: u8[>..]                = [];
    var maps: lit::ScopeMapping[>..] = [];
    assert(lit::parse_sloc_map(map_src, pool, maps) == 6);

    var files: lit::FileSlocStats[>..] = [];
    let p_hot_o, p_hot_l = crap::pool_add(pool, "hot/k.goose");
    files.push(lit::FileSlocStats { path_off: p_hot_o, path_len: p_hot_l, sloc: 100, stmts: 80, .. });
    let p_bal_o, p_bal_l = crap::pool_add(pool, "bal/b.goose");
    files.push(lit::FileSlocStats { path_off: p_bal_o, path_len: p_bal_l, sloc: 200, stmts: 160, .. });
    let p_cold_o, p_cold_l = crap::pool_add(pool, "cold/c.goose");
    files.push(lit::FileSlocStats { path_off: p_cold_o, path_len: p_cold_l, sloc: 1000, stmts: 800, .. });
    let p_miss_o, p_miss_l = crap::pool_add(pool, "miss/m.goose");
    files.push(lit::FileSlocStats { path_off: p_miss_o, path_len: p_miss_l, sloc: 50, stmts: 40, .. });

    let tsv: const u8[:] = "@LIT_BENCH\tSuite\tHot_Case\t100\t10.0\t250.0\t100.0\t0\t0\t0\t0\t0\t-\r\n@LIT_BENCH\tSuite\tBal_Case\t100\t10.0\t100.0\t100.0\t0\t0\t0\t0\t0\t-\r\n@LIT_BENCH\tSuite\tCold_Case\t100\t10.0\t50.0\t100.0\t0\t0\t0\t0\t0\t-\r\n@LIT_STAGE\tHot_Case\tstage.a\t100\t40.0\t40.0\t40\t40\t100.0\t0\t0\t0\t0\r\n@LIT_STAGE\tOther_Case\tstage.a\t300\t80.0\t80.0\t80\t80\t100.0\t0\t0\t0\t0\r\n";
    var samples: lit::ProfileSample[>..] = [];
    assert(lit::parse_profile_tsv_samples(tsv, samples) == 5);

    var rows: lit::CycleSlocRow[>..] = [];
    lit::correlate_scopes(maps[..], pool[..], files[..], samples[..], "", false, rows);
    assert(rows.len == 6);

    // Hot_Case: C=250.0 (2500 x10), L=100 => cyc/SLOC = 2.50 (250 x100) => HOT_KERNEL, CL = 25000.0 (250000 x10)
    assert(rows[0].cycles_x10 == 2500);
    assert(rows[0].cyc_per_sloc_x100 == 250);
    assert(rows[0].cl_x10 == 250000);
    assert(rows[0].radar == lit::SLOC_RADAR_HOT_KERNEL);

    // Bal_Case: C=100.0, L=200 => cyc/SLOC = 0.50 (50 x100) => BALANCED
    assert(rows[1].cyc_per_sloc_x100 == 50);
    assert(rows[1].radar == lit::SLOC_RADAR_BALANCED);

    // Cold_Case: C=50.0, L=1000 => cyc/SLOC = 0.05 (5 x100) => COLD_BLOAT
    assert(rows[2].cyc_per_sloc_x100 == 5);
    assert(rows[2].radar == lit::SLOC_RADAR_COLD_BLOAT);

    // Miss_Case: C=0 => UNPROFILED
    assert(rows[3].cycles_x10 == 0);
    assert(rows[3].radar == lit::SLOC_RADAR_UNPROFILED);

    // Exact stage Hot_Case::stage.a => 40.0 cyc (400 x10)
    assert(rows[4].cycles_x10 == 400);
    assert(rows[4].cyc_per_sloc_x100 == 40);

    // Weighted wildcard *::stage.a => (100*40.0 + 300*80.0) / 400 = 70.0 cyc (700 x10)
    assert(rows[5].cycles_x10 == 700);
    assert(rows[5].cyc_per_sloc_x100 == 70);
}

fn test_baseline_roundtrip_and_cycle_preserve() {
    var pool:   u8[>..]                 = [];
    var files:  lit::FileSlocStats[>..] = [];
    var dirs:   lit::DirSlocStats[>..]  = [];
    var scopes: lit::CycleSlocRow[>..]  = [];

    let po, pl = crap::pool_add(pool, "http/parser.goose");
    files.push(lit::FileSlocStats {
        path_off:      po,
        path_len:      pl,
        sloc:          100,
        stmts:         90,
        tokens:        600,
        comment_lines: 10,
        packing_x100:  90,
        bce_kept:      2,
        smells_total:  1,
        ..
    });
    let doff, dlen = crap::pool_add(pool, "http");
    dirs.push(lit::DirSlocStats {
        dir_off:       doff,
        dir_len:       dlen,
        files:         1,
        sloc:          100,
        stmts:         90,
        tokens:        600,
        comment_lines: 10,
        smells_total:  1,
    });
    let so, sl = crap::pool_add(pool, "L0_GET");
    scopes.push(lit::CycleSlocRow {
        name_off:          so,
        name_len:          sl,
        kind:              lit::SLOC_SCOPE_BENCH,
        files:             1,
        sloc:              100,
        stmts:             90,
        cycles_x10:        9500,
        cyc_per_sloc_x100: 950,
        cl_x10:            950000,
        radar:             lit::SLOC_RADAR_HOT_KERNEL,
        ..
    });

    var empty_prev = lit::SlocBaseline { .. };
    var empty_prev_scopes: lit::SlocBaselineScope[>..] = [];
    var saved:             u8[>..]                     = [];
    lit::serialize_sloc_baseline(
        pool[..],
        files[..],
        dirs[..],
        scopes[..],
        true,
        empty_prev,
        "",
        empty_prev_scopes[..],
        false,
        saved,
    );

    var bpool: u8[>..] = [];
    var base = lit::SlocBaseline { .. };
    var bfiles:  lit::SlocBaselineFile[>..]  = [];
    var bscopes: lit::SlocBaselineScope[>..] = [];
    assert(lit::parse_sloc_baseline(saved[..], bpool, base, bfiles, bscopes));
    assert(base.loaded && base.bce_measured);
    assert(base.total_sloc == 100 && base.total_bce_kept == 2 && base.total_smells == 1);
    assert(bfiles.len == 1 && bfiles[0].bce_kept == 2);
    assert(bscopes.len == 1 && bscopes[0].cycles_x10 == 9500);

    // Static re-save with preserve_cycles=true keeps prior SCOPE cycles
    var empty_scopes: lit::CycleSlocRow[>..] = [];
    var saved_pres:   u8[>..]                = [];
    lit::serialize_sloc_baseline(
        pool[..],
        files[..],
        dirs[..],
        empty_scopes[..],
        false,
        base,
        bpool[..],
        bscopes[..],
        true,
        saved_pres,
    );
    var bpool2: u8[>..] = [];
    var base2 = lit::SlocBaseline { .. };
    var bfiles2:  lit::SlocBaselineFile[>..]  = [];
    var bscopes2: lit::SlocBaselineScope[>..] = [];
    assert(lit::parse_sloc_baseline(saved_pres[..], bpool2, base2, bfiles2, bscopes2));
    assert(!base2.bce_measured);
    assert(bscopes2.len == 1 && bscopes2[0].cycles_x10 == 9500);

    // Static re-save with preserve_cycles=false (--reset-cycles) clears SCOPE cycles
    var saved_reset: u8[>..] = [];
    lit::serialize_sloc_baseline(
        pool[..],
        files[..],
        dirs[..],
        empty_scopes[..],
        false,
        base,
        bpool[..],
        bscopes[..],
        false,
        saved_reset,
    );
    var bpool3: u8[>..] = [];
    var base3 = lit::SlocBaseline { .. };
    var bfiles3:  lit::SlocBaselineFile[>..]  = [];
    var bscopes3: lit::SlocBaselineScope[>..] = [];
    assert(lit::parse_sloc_baseline(saved_reset[..], bpool3, base3, bfiles3, bscopes3));
    assert(bscopes3.len == 0);
}

fn test_packing_small_file_and_delta_gaming() {
    var cfg = lit::SlocCliArgs { check_packing: true, max_packing: 1.35, .. };
    var pool: u8[>..] = [];
    var empty_base = lit::SlocBaseline { .. };
    var empty_bfiles:  lit::SlocBaselineFile[>..]  = [];
    var empty_bscopes: lit::SlocBaselineScope[>..] = [];
    var empty_scopes:  lit::CycleSlocRow[>..]      = [];
    var empty_maps:    lit::ScopeMapping[>..]      = [];

    // 1. Small file (sloc < 10) with high packing is exempt from absolute ceiling
    var f_small: lit::FileSlocStats[>..] = [];
    let p1o, p1l = crap::pool_add(pool, "stub.goose");
    f_small.push(lit::FileSlocStats { path_off: p1o, path_len: p1l, sloc: 5, stmts: 9, packing_x100: 180, .. });
    var res1 = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg, pool[..], empty_maps[..], f_small, empty_scopes, empty_base, "", empty_bfiles[..], empty_bscopes[..], false, 0, res1);
    assert(res1.verdict == lit::SLOC_VERDICT_UNCHANGED && res1.exit_code == 0);

    // 2. Normal file (sloc >= 10) with packing 1.50 > 1.35 triggers GAMING_DETECTED
    var f_big: lit::FileSlocStats[>..] = [];
    let p2o, p2l = crap::pool_add(pool, "packed.goose");
    f_big.push(lit::FileSlocStats { path_off: p2o, path_len: p2l, sloc: 15, stmts: 23, packing_x100: 153, .. });
    var res2 = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg, pool[..], empty_maps[..], f_big, empty_scopes, empty_base, "", empty_bfiles[..], empty_bscopes[..], false, 0, res2);
    assert(res2.verdict == lit::SLOC_VERDICT_GAMING_DETECTED && res2.exit_code == 1);

    // 3. Delta-packing gaming: sloc dropped 50->40, stmts stayed 50, packing jumped 1.00->1.25 (+0.25 > +0.15)
    var bpool: u8[>..] = [];
    let bpo, bpl = crap::pool_add(bpool, "gamed.goose");
    var base = lit::SlocBaseline { loaded: true, total_files: 1, total_sloc: 50, total_stmts: 50, .. };
    var bfiles: lit::SlocBaselineFile[>..] = [];
    bfiles.push(lit::SlocBaselineFile { path_off: bpo, path_len: bpl, sloc: 50, stmts: 50, packing_x100: 100, .. });

    var f_gamed: lit::FileSlocStats[>..] = [];
    let p3o, p3l = crap::pool_add(pool, "gamed.goose");
    f_gamed.push(lit::FileSlocStats { path_off: p3o, path_len: p3l, sloc: 40, stmts: 50, packing_x100: 125, .. });
    var res3 = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg, pool[..], empty_maps[..], f_gamed, empty_scopes, base, bpool[..], bfiles[..], empty_bscopes[..], false, 0, res3);
    assert(res3.verdict == lit::SLOC_VERDICT_GAMING_DETECTED && res3.exit_code == 1);
}

fn test_unmeasured_bce_and_zero_cycle_scope() {
    var pool:       u8[>..]                = [];
    var empty_maps: lit::ScopeMapping[>..] = [];
    let po, pl = crap::pool_add(pool, "a.goose");
    let so, sl = crap::pool_add(pool, "S1");

    var bpool: u8[>..] = [];
    let bpo, bpl = crap::pool_add(bpool, "a.goose");
    let bso, bsl = crap::pool_add(bpool, "S1");

    var base = lit::SlocBaseline { loaded: true, bce_measured: false, total_files: 1, total_sloc: 100, total_bce_kept: -1, .. };
    var bfiles: lit::SlocBaselineFile[>..] = [];
    bfiles.push(lit::SlocBaselineFile { path_off: bpo, path_len: bpl, sloc: 100, stmts: 80, packing_x100: 80, bce_kept: -1, .. });
    var bscopes: lit::SlocBaselineScope[>..] = [];
    bscopes.push(lit::SlocBaselineScope { name_off: bso, name_len: bsl, kind: lit::SLOC_SCOPE_BENCH, sloc: 100, cycles_x10: 0, .. });

    var files: lit::FileSlocStats[>..] = [];
    files.push(lit::FileSlocStats { path_off: po, path_len: pl, sloc: 100, stmts: 80, packing_x100: 80, bce_kept: 3, .. });
    var scopes: lit::CycleSlocRow[>..] = [];
    scopes.push(lit::CycleSlocRow { name_off: so, name_len: sl, kind: lit::SLOC_SCOPE_BENCH, sloc: 100, cycles_x10: 5000, .. });

    var cfg = lit::SlocCliArgs { bce_enabled: true, .. };
    var res = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg, pool[..], empty_maps[..], files, scopes, base, bpool[..], bfiles[..], bscopes[..], false, 0, res);
    assert(res.exit_code == 0);
    assert(res.audit.bce_skipped_unmeasured);

    // Now mark baseline bce_measured=true with bce_kept=1 -> current bce_kept=3 must fail GAMING_DETECTED
    base.bce_measured = true;
    base.total_bce_kept = 1;
    bfiles[0].bce_kept = 1;
    var res2 = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg, pool[..], empty_maps[..], files, scopes, base, bpool[..], bfiles[..], bscopes[..], false, 0, res2);
    assert(res2.verdict == lit::SLOC_VERDICT_GAMING_DETECTED && res2.exit_code == 1);
}

fn test_dedup_and_hot_growth_credit() {
    var pool:       u8[>..]                = [];
    var empty_maps: lit::ScopeMapping[>..] = [];
    let p1o, p1l = crap::pool_add(pool, "core/a.goose");
    let p2o, p2l = crap::pool_add(pool, "tls/b.goose");
    let so, sl = crap::pool_add(pool, "Core_Hot");

    var bpool: u8[>..] = [];
    let bp1o, bp1l = crap::pool_add(bpool, "core/a.goose");
    let bp2o, bp2l = crap::pool_add(bpool, "tls/b.goose");
    let bso, bsl = crap::pool_add(bpool, "Core_Hot");

    var base = lit::SlocBaseline { loaded: true, total_files: 2, total_sloc: 300, total_stmts: 240, .. };
    var bfiles: lit::SlocBaselineFile[>..] = [];
    bfiles.push(lit::SlocBaselineFile { path_off: bp1o, path_len: bp1l, sloc: 100, stmts: 80, packing_x100: 80, .. });
    bfiles.push(lit::SlocBaselineFile { path_off: bp2o, path_len: bp2l, sloc: 200, stmts: 160, packing_x100: 80, .. });
    var bscopes: lit::SlocBaselineScope[>..] = [];
    bscopes.push(lit::SlocBaselineScope { name_off: bso, name_len: bsl, kind: lit::SLOC_SCOPE_BENCH, sloc: 100, cycles_x10: 10000, .. });

    // 1. Static cross-module dedup: core/a grows +20, tls/b drops -100 => total 220 <= 300 => PARETO_WIN
    var files1: lit::FileSlocStats[>..] = [];
    files1.push(lit::FileSlocStats { path_off: p1o, path_len: p1l, sloc: 120, stmts: 96, packing_x100: 80, .. });
    files1.push(lit::FileSlocStats { path_off: p2o, path_len: p2l, sloc: 100, stmts: 80, packing_x100: 80, .. });
    var scopes1: lit::CycleSlocRow[>..] = [];
    scopes1.push(lit::CycleSlocRow { name_off: so, name_len: sl, kind: lit::SLOC_SCOPE_BENCH, sloc: 120, cycles_x10: 0, .. });
    var cfg1 = lit::SlocCliArgs { sloc_delta: 0, .. };
    var res1 = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg1, pool[..], empty_maps[..], files1, scopes1, base, bpool[..], bfiles[..], bscopes[..], false, 0, res1);
    assert(res1.verdict == lit::SLOC_VERDICT_PARETO_WIN && res1.exit_code == 0);

    // 2. --allow-hot-growth: Core_Hot grows +6 (100->106) while cycles drop 1000->700 (norm_cl = 0.742 <= 0.90)
    var files2: lit::FileSlocStats[>..] = [];
    files2.push(lit::FileSlocStats { path_off: p1o, path_len: p1l, sloc: 106, stmts: 85, packing_x100: 80, .. });
    files2.push(lit::FileSlocStats { path_off: p2o, path_len: p2l, sloc: 200, stmts: 160, packing_x100: 80, .. });
    var scopes2: lit::CycleSlocRow[>..] = [];
    scopes2.push(lit::CycleSlocRow { name_off: so, name_len: sl, kind: lit::SLOC_SCOPE_BENCH, sloc: 106, cycles_x10: 7000, .. });
    var cfg2 = lit::SlocCliArgs { allow_hot_growth: true, cycle_noise: 5.0, .. };
    var res2 = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg2, pool[..], empty_maps[..], files2, scopes2, base, bpool[..], bfiles[..], bscopes[..], false, 0, res2);
    assert(res2.exit_code == 0);
    assert(res2.audit.hot_growth_credit_sum == 6);

    // 3. Unrelated file adds +5 on top of credited +6 => total 311 > 300 + 6 => REGRESSION
    files2[1].sloc = 205;
    var res3 = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg2, pool[..], empty_maps[..], files2, scopes2, base, bpool[..], bfiles[..], bscopes[..], false, 0, res3);
    assert(res3.verdict == lit::SLOC_VERDICT_REGRESSION && res3.exit_code == 1);
}

fn test_pareto_verdicts_and_reports() {
    var pool:       u8[>..]                = [];
    var empty_maps: lit::ScopeMapping[>..] = [];
    let po, pl = crap::pool_add(pool, "http/a.goose");
    let doff, dlen = crap::pool_add(pool, "http");
    let so, sl = crap::pool_add(pool, "L0");

    var bpool: u8[>..] = [];
    let bpo, bpl = crap::pool_add(bpool, "http/a.goose");
    let bso, bsl = crap::pool_add(bpool, "L0");

    var base = lit::SlocBaseline { loaded: true, total_files: 1, total_sloc: 100, total_stmts: 80, total_smells: 1, .. };
    var bfiles: lit::SlocBaselineFile[>..] = [];
    bfiles.push(lit::SlocBaselineFile { path_off: bpo, path_len: bpl, sloc: 100, stmts: 80, packing_x100: 80, smells_total: 1, .. });
    var bscopes: lit::SlocBaselineScope[>..] = [];
    bscopes.push(lit::SlocBaselineScope { name_off: bso, name_len: bsl, kind: lit::SLOC_SCOPE_BENCH, sloc: 100, cycles_x10: 10000, .. });

    // SLOC_WIN_PERF_REGRESS: L 100->80, C 1000->1200 (+20% > 5% noise)
    var files: lit::FileSlocStats[>..] = [];
    files.push(lit::FileSlocStats { path_off: po, path_len: pl, sloc: 80, stmts: 64, packing_x100: 80, smells_total: 1, .. });
    var dirs: lit::DirSlocStats[>..] = [];
    dirs.push(lit::DirSlocStats { dir_off: doff, dir_len: dlen, files: 1, sloc: 80, stmts: 64, smells_total: 1, .. });
    var scopes: lit::CycleSlocRow[>..] = [];
    scopes.push(lit::CycleSlocRow { name_off: so, name_len: sl, kind: lit::SLOC_SCOPE_BENCH, files: 1, sloc: 80, stmts: 64, cycles_x10: 12000, cyc_per_sloc_x100: 1500, cl_x10: 960000, radar: lit::SLOC_RADAR_HOT_KERNEL, .. });

    var cfg = lit::SlocCliArgs { cycle_noise: 5.0, check_smells: true, .. };
    var res = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg, pool[..], empty_maps[..], files, scopes, base, bpool[..], bfiles[..], bscopes[..], false, 0, res);
    assert(res.verdict == lit::SLOC_VERDICT_SLOC_WIN_PERF_REGRESS && res.exit_code == 1);

    // PARETO_WIN: L 100->80, C 1000->800
    scopes[0].cycles_x10 = 8000;
    var res_win = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg, pool[..], empty_maps[..], files, scopes, base, bpool[..], bfiles[..], bscopes[..], false, 0, res_win);
    assert(res_win.verdict == lit::SLOC_VERDICT_PARETO_WIN && res_win.exit_code == 0);

    // Local smell ratchet failure: smells 1 -> 2
    files[0].smells_total = 2;
    var res_sm = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg, pool[..], empty_maps[..], files, scopes, base, bpool[..], bfiles[..], bscopes[..], false, 0, res_sm);
    assert(res_sm.verdict == lit::SLOC_VERDICT_REGRESSION && res_sm.exit_code == 1);

    // Report formatters produce valid structured output
    var dead:    lit::DeadFnCandidate[>..] = [];
    var out_tbl: u8[>..]                   = [];
    var out_md:  u8[>..]                   = [];
    var out_js:  u8[>..]                   = [];
    var out_tsv: u8[>..]                   = [];
    lit::format_sloc_report_table(cfg, pool[..], files[..], dirs[..], dead[..], scopes[..], res_win, out_tbl);
    lit::format_sloc_report_md(cfg, pool[..], files[..], dirs[..], dead[..], scopes[..], res_win, out_md);
    lit::format_sloc_report_json(cfg, pool[..], files[..], dirs[..], dead[..], scopes[..], res_win, out_js);
    lit::format_sloc_report_tsv(cfg, pool[..], files[..], dirs[..], dead[..], scopes[..], res_win, out_tsv);
    assert(crap::slice_contains(out_tbl[..], "PARETO_WIN"));
    assert(crap::slice_contains(out_md[..], "| Scope |"));
    assert(crap::slice_contains(out_js[..], "\"verdict\": \"PARETO_WIN\""));
    assert(crap::slice_contains(out_tsv[..], "SCOPE\tL0\t"));
}

fn push_mut_arg(pool: u8[>..]&, argv: u8[:][>..]&, s: const u8[:]) {
    let st = pool.len;
    pool.append(s);
    argv.push(pool[st..]);
}

fn test_review_fixes_red_green() {
    // Finding #1: overlapping hot scopes must NOT double-credit shared files to TOTAL
    var pool: u8[>..]                = [];
    var maps: lit::ScopeMapping[>..] = [];
    let map_raw: const u8[:] = "S_A | bench | http/,server/\nS_B | bench | http/\n";
    assert(lit::parse_sloc_map(map_raw, pool, maps) == 2);

    let p1o, p1l = crap::pool_add(pool, "http/a.goose");
    let p2o, p2l = crap::pool_add(pool, "tls/b.goose");
    var files: lit::FileSlocStats[>..] = [];
    files.push(lit::FileSlocStats { path_off: p1o, path_len: p1l, sloc: 110, stmts: 88, packing_x100: 80, .. });
    files.push(lit::FileSlocStats { path_off: p2o, path_len: p2l, sloc: 210, stmts: 168, packing_x100: 80, .. });

    var samples: lit::ProfileSample[>..] = [];
    var s1 = lit::ProfileSample { kind: lit::SLOC_SCOPE_BENCH, cycles_x10: 6000, .. };
    let _ = crap::set_bounded(s1.case_name, "S_A");
    samples.push(s1);
    var s2 = lit::ProfileSample { kind: lit::SLOC_SCOPE_BENCH, cycles_x10: 6000, .. };
    let _ = crap::set_bounded(s2.case_name, "S_B");
    samples.push(s2);

    var scopes: lit::CycleSlocRow[>..] = [];
    lit::correlate_scopes(maps[..], pool[..], files[..], samples[..], "", false, scopes);
    assert(scopes.len == 2);

    var bpool: u8[>..] = [];
    let bp1o, bp1l = crap::pool_add(bpool, "http/a.goose");
    let bp2o, bp2l = crap::pool_add(bpool, "tls/b.goose");
    let bs1o, bs1l = crap::pool_add(bpool, "S_A");
    let bs2o, bs2l = crap::pool_add(bpool, "S_B");
    var base = lit::SlocBaseline { loaded: true, total_files: 2, total_sloc: 300, total_stmts: 240, .. };
    var bfiles: lit::SlocBaselineFile[>..] = [];
    bfiles.push(lit::SlocBaselineFile { path_off: bp1o, path_len: bp1l, sloc: 100, stmts: 80, packing_x100: 80, .. });
    bfiles.push(lit::SlocBaselineFile { path_off: bp2o, path_len: bp2l, sloc: 200, stmts: 160, packing_x100: 80, .. });
    var bscopes: lit::SlocBaselineScope[>..] = [];
    bscopes.push(lit::SlocBaselineScope { name_off: bs1o, name_len: bs1l, kind: lit::SLOC_SCOPE_BENCH, sloc: 100, cycles_x10: 10000, .. });
    bscopes.push(lit::SlocBaselineScope { name_off: bs2o, name_len: bs2l, kind: lit::SLOC_SCOPE_BENCH, sloc: 100, cycles_x10: 10000, .. });

    var cfg = lit::SlocCliArgs { allow_hot_growth: true, cycle_noise: 5.0, .. };
    var res = lit::SlocGateResult { .. };
    lit::evaluate_sloc_gate(cfg, pool[..], maps[..], files, scopes, base, bpool[..], bfiles[..], bscopes[..], false, 0, res);
    // Unique exempted growth in http/a.goose is +10 (NOT +20), so +10 unrelated bloat in tls/b.goose MUST fail REGRESSION
    assert(res.audit.hot_growth_credit_sum == 10);
    assert(res.verdict == lit::SLOC_VERDICT_REGRESSION && res.exit_code == 1);

    // Finding #2: shell-free argv execution helper works with zero shell parsing
    var argv_nul: u8[>..] = [];
    argv_nul.append("goose");
    argv_nul.push(0);
    argv_nul.append("--version");
    argv_nul.push(0);
    var v_out: u8[>..] = [];
    let v_rc = crap::exec_argv_nul_capture(argv_nul[..], 0, v_out);
    assert(v_rc == 0 && v_out.len > 0);

    // Finding #5, #7, #11: greedy flags, >2048B targets, and ./http/ normalization
    var lit_cfg = crap::LitConfig { .. };
    var arg_pool: u8[>..] = [];
    var c1 = lit::SlocCliArgs { .. };
    var targets1: u8[>..] = [];
    var tsvs1:    u8[>..] = [];
    var benches1: u8[>..] = [];
    var bces1:    u8[>..] = [];
    var show_h = false;
    var args1: u8[:][>..] = [];
    push_mut_arg(arg_pool, args1, "goose-lit");
    push_mut_arg(arg_pool, args1, "sloc");
    push_mut_arg(arg_pool, args1, "--run-profile");
    push_mut_arg(arg_pool, args1, "--save-baseline");
    push_mut_arg(arg_pool, args1, "./http/");
    assert(lit::parse_sloc_cli_args(args1[..], lit_cfg, c1, targets1, tsvs1, benches1, bces1, show_h));
    assert(c1.run_profile_all && benches1.len == 0);
    assert(c1.save_baseline && c1.save_baseline_path.len == 0);
    assert(targets1[..] == "http/\n");
    assert(lit::path_matches_scope_prefix("http", "http/"));

    // >2048 bytes of positional target paths must not truncate
    var args_many: u8[:][>..] = [];
    push_mut_arg(arg_pool, args_many, "goose-lit");
    push_mut_arg(arg_pool, args_many, "sloc");
    for _ in 100 {
        push_mut_arg(arg_pool, args_many, "very/long/package/module/file_name_padding.goose");
    }
    var c2 = lit::SlocCliArgs { .. };
    var targets2: u8[>..] = [];
    var tsvs2:    u8[>..] = [];
    var benches2: u8[>..] = [];
    var bces2:    u8[>..] = [];
    assert(lit::parse_sloc_cli_args(args_many[..], lit_cfg, c2, targets2, tsvs2, benches2, bces2, show_h));
    assert(targets2.len > 4000);

    // Finding #3: explicit missing --baseline / --map returns non-zero
    var args_bad_base: u8[:][>..] = [];
    push_mut_arg(arg_pool, args_bad_base, "goose-lit");
    push_mut_arg(arg_pool, args_bad_base, "sloc");
    push_mut_arg(arg_pool, args_bad_base, "tests/sloc_test.goose");
    push_mut_arg(arg_pool, args_bad_base, "--include-tests");
    push_mut_arg(arg_pool, args_bad_base, "--baseline");
    push_mut_arg(arg_pool, args_bad_base, ".lit/nonexistent_sloc_baseline_file");
    assert(lit::handle_sloc_cli(args_bad_base[..], lit_cfg) != 0);

    var args_bad_map: u8[:][>..] = [];
    push_mut_arg(arg_pool, args_bad_map, "goose-lit");
    push_mut_arg(arg_pool, args_bad_map, "sloc");
    push_mut_arg(arg_pool, args_bad_map, "tests/sloc_test.goose");
    push_mut_arg(arg_pool, args_bad_map, "--include-tests");
    push_mut_arg(arg_pool, args_bad_map, "--no-baseline");
    push_mut_arg(arg_pool, args_bad_map, "--map");
    push_mut_arg(arg_pool, args_bad_map, ".lit/nonexistent_sloc_map_file");
    assert(lit::handle_sloc_cli(args_bad_map[..], lit_cfg) != 0);

    // Finding #6: filtered --save-baseline with --profile must preserve unmeasured scope cycles
    crap::ensure_lit_cache_dir();
    let f6_dir: const u8[:] = ".lit/cache/sloc_f6_test";
    let _ = make_dir(f6_dir);
    let f6_src:  const u8[:] = ".lit/cache/sloc_f6_test/mod.goose";
    let f6_map:  const u8[:] = ".lit/cache/sloc_f6_test/sloc.map";
    let f6_base: const u8[:] = ".lit/cache/sloc_f6_test/sloc.base";
    let f6_tsv:  const u8[:] = ".lit/cache/sloc_f6_test/one.tsv";
    assert(write_file(f6_src, "fn ok_fn() -> i64 { return 1; }\n"));
    assert(write_file(f6_map, "Scope_A | bench | .lit/cache/sloc_f6_test/\nScope_B | bench | .lit/cache/sloc_f6_test/\n"));
    assert(write_file(f6_base, "# goose-sloc baseline v1 bce_measured=0\nTOTAL 1 1 2 10 0 -1 0\nSCOPE Scope_A bench 1 2 1000 10000 1000\nSCOPE Scope_B bench 1 2 2500 25000 2500\n"));
    assert(write_file(f6_tsv, "@LIT_BENCH\tS\tScope_A\t10\t1.0\t120.0\t0\t0\t0\t0\t0\t0\t-\n"));

    var args_f6: u8[:][>..] = [];
    push_mut_arg(arg_pool, args_f6, "goose-lit");
    push_mut_arg(arg_pool, args_f6, "sloc");
    push_mut_arg(arg_pool, args_f6, f6_dir);
    push_mut_arg(arg_pool, args_f6, "--include-tests");
    push_mut_arg(arg_pool, args_f6, "--map");
    push_mut_arg(arg_pool, args_f6, f6_map);
    push_mut_arg(arg_pool, args_f6, "--profile");
    push_mut_arg(arg_pool, args_f6, f6_tsv);
    push_mut_arg(arg_pool, args_f6, "--baseline");
    push_mut_arg(arg_pool, args_f6, f6_base);
    push_mut_arg(arg_pool, args_f6, "--save-baseline");
    push_mut_arg(arg_pool, args_f6, f6_base);
    assert(lit::handle_sloc_cli(args_f6[..], lit_cfg) == 0);

    var saved_f6: u8[>..] = [];
    assert(read_file(f6_base, saved_f6));
    let _ = crap::native_remove_tree(f6_dir);
    assert(crap::slice_contains(saved_f6[..], "SCOPE Scope_A bench 1 2 1200 "));
    assert(crap::slice_contains(saved_f6[..], "SCOPE Scope_B bench 1 2 2500 "));
}

fn main() {
    test_sloc_and_guard_stmts();
    test_multiline_string_and_nested_comments();
    test_local_smells_detection();
    test_dead_fn_ignores_test_callers();
    test_sloc_map_and_crlf();
    test_correlate_bench_and_stages();
    test_baseline_roundtrip_and_cycle_preserve();
    test_packing_small_file_and_delta_gaming();
    test_unmeasured_bce_and_zero_cycle_scope();
    test_dedup_and_hot_growth_credit();
    test_pareto_verdicts_and_reports();
    test_review_fixes_red_green();
    print("SLOC_TEST: PASS");
}

// CHECK: SLOC_TEST: PASS
