// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// tests/swarm_page_fault_cycle2_test.goose
import std;
import cli from "..";

fn test_cycle2_finding1_guard_stack_and_match_parens(t: lit::T&) {
    let src_guards = """
        fn parse_pkt(buf: const u8[:]) -> u8 {
            guard buf.len >= 4 else { return 0; }
            guard buf[0] == 1 else { return 0; }
            if buf[1] == 2 {
                return buf[10];
            }
            return 0;
        }
        """;

    var pool:       u8[>..]                 = [];
    var functions:  crap::FunctionInfo[>..] = [];
    var branches:   crap::BranchSite[>..]   = [];
    var call_sites: crap::CallSite[>..]     = [];

    crap::analyze_goose_file_with_calls("pkt.goose", src_guards, pool, functions, branches, call_sites);
    lit::assert_eq(t, functions.len, 1);

    lit::assert_eq(t, branches[4].kind, crap::BRANCH_GUARD_PASS);
    lit::assert_eq(t, branches[4].depth, 2);
    lit::assert_eq(t, branches[5].kind, crap::BRANCH_IF_THEN);
    lit::assert_eq(t, branches[5].depth, 2);

    let bce_blob = "bce-line: pkt.goose:5: 0 elided, 1 kept\n";
    crap::apply_bce_lines_blob(bce_blob, pool[..], functions, branches);
    lit::assert_eq(t, branches[4].bce_keep, 0);
    lit::assert_eq(t, branches[5].bce_keep, 1);

    var many_guards_src: u8[>..] = [];
    many_guards_src.append("fn exhaust_stack(x: i32) -> i32 {\n");
    for i in 64 {
        many_guards_src.append("    guard x > 0;\n");
    }
    many_guards_src.append("    if x == 42 {\n        return 1;\n    }\n    return 0;\n}\n");

    var pool2:       u8[>..]                 = [];
    var functions2:  crap::FunctionInfo[>..] = [];
    var branches2:   crap::BranchSite[>..]   = [];
    var call_sites2: crap::CallSite[>..]     = [];
    crap::analyze_goose_file_with_calls("exhaust.goose", many_guards_src[..], pool2, functions2, branches2, call_sites2);

    let last_b = branches2[branches2.len - 1];
    lit::assert_eq(t, last_b.kind, crap::BRANCH_IF_ELSE);
    lit::assert_true(t, last_b.needs_synth_else);
    let if_then_b = branches2[branches2.len - 2];
    lit::assert_eq(t, if_then_b.kind, crap::BRANCH_IF_THEN);
    lit::assert_true(t, if_then_b.body_close_offset > 0);

    let paren_match_src = """
        fn eval_code(x: i32) -> i32 {
            return (match x {
                0 => 10,
                1 => 20,
                _ => 30,
            });
        }
        """;
    var pool3:       u8[>..]                 = [];
    var functions3:  crap::FunctionInfo[>..] = [];
    var branches3:   crap::BranchSite[>..]   = [];
    var call_sites3: crap::CallSite[>..]     = [];
    crap::analyze_goose_file_with_calls("pmatch.goose", paren_match_src, pool3, functions3, branches3, call_sites3);
    lit::assert_eq(t, branches3.len, 4);
    lit::assert_eq(t, branches3[1].depth, 2);
    lit::assert_eq(t, branches3[2].depth, 2);
    lit::assert_eq(t, branches3[3].depth, 2);
}

fn test_cycle2_finding2_callgraph_and_taint_bypass(t: lit::T&) {
    let src = """
        namespace safe_math;
        // crap:ignore
        fn helper(x: i32) -> i32 {
            return x + 1;
        }

        namespace app_core;
        fn helper(x: i32) -> i32 {
            return x * 2;
        }

        fn decode_generic<T>(val: T) -> i32 {
            return 1;
        }

        fn entry_point(wire_buf: const u8[:]) -> i32 {
            fn nested_local(y: i32) -> i32 {
                return y + 3;
            }
            let a = decode_generic<i32>(10);
            let b = helper(a);
            return nested_local(b);
        }
        """;

    var pool:       u8[>..]                 = [];
    var functions:  crap::FunctionInfo[>..] = [];
    var branches:   crap::BranchSite[>..]   = [];
    var call_sites: crap::CallSite[>..]     = [];

    crap::analyze_goose_file_with_calls("taint.goose", src, pool, functions, branches, call_sites);
    crap::propagate_trust_taint(functions, call_sites[..], pool[..]);

    lit::assert_eq(t, functions.len, 5);

    lit::assert_eq(t, functions[2].trust_class, crap::TRUST_UNTRUSTED);
    lit::assert_eq(t, functions[2].taint_depth, 1);

    lit::assert_eq(t, functions[1].trust_class, crap::TRUST_UNTRUSTED);
    lit::assert_eq(t, functions[1].taint_depth, 1);

    lit::assert_eq(t, functions[4].trust_class, crap::TRUST_UNTRUSTED);
    lit::assert_eq(t, functions[4].taint_depth, 1);

    lit::assert_false(t, crap::is_untrusted_path_or_ns("math/fraction.goose", "math"));
}

fn test_cycle2_finding3_filecheck_dag_var_num_bugs(t: lit::T&) {
    let dag_out = "item: 10\nitem: 20\nitem: 30\n";
    let dag_rules = """
        // CHK-DAG: item: 20
        // CHK-DAG: item: 10
        // CHK: item: [[LAST:[0-9]+]]
        """;
    var diag_dag: u8[>..] = [];
    let ok_dag = lit::run_filecheck(dag_out, dag_rules, "CHK", diag_dag);
    lit::assert_true(t, ok_dag);

    let dag_same_out = "[First] Middle\n";
    let dag_same_rules = """
        // CHK-DAG: Middle
        // CHK-SAME: [First]
        """;
    var diag_ds: u8[>..] = [];
    let ok_ds = lit::run_filecheck(dag_same_out, dag_same_rules, "CHK", diag_ds);
    lit::assert_false(t, ok_ds);

    var tok_out: u8[>..] = [];
    tok_out.append("CAP=");
    for i in 260 { tok_out.push('X'); }
    tok_out.append("\nUSE=");
    for i in 260 { tok_out.push('X'); }
    tok_out.append("_END\n");

    let tok_rules = """
        // CHK: CAP=[[TOK:[A-Z]+]]
        // CHK: USE=[[TOK]]_END
        """;
    var diag_tok: u8[>..] = [];
    let ok_tok = lit::run_filecheck(tok_out[..], tok_rules, "CHK", diag_tok);
    lit::assert_true(t, ok_tok);

    let num_out = "init pn=10\nack pn=10999\nnext pn=11888\n";
    let num_rules = """
        // CHK: init pn=[[#PN:]]
        // CHK: ack pn=[[#PN]]
        // CHK: next pn=[[#PN + 1]]
        """;
    var diag_num: u8[>..] = [];
    let ok_num = lit::run_filecheck(num_out, num_rules, "CHK", diag_num);
    lit::assert_false(t, ok_num);
}

fn test_cycle2_finding4_sys_bytes_defects(t: lit::T&) {
    let v_nan, ok_nan = crap::parse_f64_slice("0e309");
    lit::assert_true(t, ok_nan);
    lit::assert_true(t, v_nan == 0.0);

    let v_under, ok_under = crap::parse_f64_slice("100000000000000000000e-310");
    lit::assert_true(t, ok_under);
    lit::assert_true(t, v_under > 0.0);

    var norm: u8[>..] = [];
    crap::normalize_path(".//foo.goose", norm);
    lit::assert_true(t, norm[..] == "foo.goose");
    lit::assert_true(t, crap::paths_match("src/./foo.goose", "src/foo.goose"));
    lit::assert_true(t, crap::paths_match("src//foo.goose", "src/foo.goose"));

    var f1_buf: u8[>..] = [];
    crap::append_f64_1(f1_buf, -0.001);
    lit::assert_true(t, f1_buf[..] == "0.0");

    var f2_buf: u8[>..] = [];
    crap::append_f64_2(f2_buf, -0.001);
    lit::assert_true(t, f2_buf[..] == "0.00");
}

fn main() {
    var runner = lit::new_runner("swarm_page_fault_cycle2", lit::Verbosity.Verbose);
    runner.run_case("cycle2_finding1_guard_stack_and_match_parens", test_cycle2_finding1_guard_stack_and_match_parens);
    runner.run_case("cycle2_finding2_callgraph_and_taint_bypass", test_cycle2_finding2_callgraph_and_taint_bypass);
    runner.run_case("cycle2_finding3_filecheck_dag_var_num_bugs", test_cycle2_finding3_filecheck_dag_var_num_bugs);
    runner.run_case("cycle2_finding4_sys_bytes_defects", test_cycle2_finding4_sys_bytes_defects);
    let ok = runner.finish();
    assert(ok);
}
