// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: goose %s | %FileCheck %s

import std;
import os;
import lit from "..";

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

    let clean: const u8[:] = "struct Item { val: i64 = 0 }\nfn good(xs: const u8[:], items: const Item[:]) -> i64 {\n    var acc: i64 = 0;\n    for i in xs.len {\n        acc += xs[i];\n    }\n    for &item in items {\n        acc += item.val;\n    }\n    return acc;\n}\n";

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

fn main() {
    test_sloc_and_guard_stmts();
    test_multiline_string_and_nested_comments();
    test_local_smells_detection();
    test_dead_fn_ignores_test_callers();
    test_sloc_map_and_crlf();
    test_correlate_bench_and_stages();
    print("SLOC_TEST: PASS");
}

// CHECK: SLOC_TEST: PASS
