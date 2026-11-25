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

fn main() {
    test_sloc_and_guard_stmts();
    test_multiline_string_and_nested_comments();
    test_local_smells_detection();
    test_dead_fn_ignores_test_callers();
    print("SLOC_TEST: PASS");
}

// CHECK: SLOC_TEST: PASS
