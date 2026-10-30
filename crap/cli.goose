// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// crap/cli.goose - Integrated G-CRAP CLI execution handler.
namespace crap;

import std;
import os;
import sys.bytes;
import sys.proc;
import crap.ast.model;
import crap.ast.analyzer;
import crap.compiler.bridge;
import crap.coverage.instrument;
import crap.coverage.profile;
import crap.metrics.crap;
import crap.report.formatter;
import crap.report.ratchet;
import sys.config;

fn print_crap_usage() {
    write_stdout("Usage: goose-lit crap <path|file.goose> [options]\n");
    write_stdout("       goose-lit gate <path|file.goose> [ceiling] [options]\n\n");
    write_stdout("Goose Change Risk Anti-Pattern (G-CRAP) and Safety Risk Radar.\n\n");
    write_stdout("Analysis & Execution Options:\n");
    write_stdout("  --gate [val]            Enforce G-CRAP risk gate ceiling (default 25.0, exits with 1 on violation)\n");
    write_stdout("  --cover <test.goose>    Instrument, run test suite, and capture branch coverage\n");
    write_stdout("  --bce-lines [file]      Import pre-captured goose --bce-lines output or auto-run\n");
    write_stdout("  --specs [file]          Import pre-captured goose --specs output or auto-run\n");
    write_stdout("  --cov <val|file>        Set simulated coverage (0.0..1.0) or load .gcrap-cov profile\n");
    write_stdout("  --lcov <file.info>      Load LCOV tracefile\n");
    write_stdout("  --default-cov <val>     Default coverage for static triage (0.0 to 1.0, default 0.0)\n");
    write_stdout("  --alpha <val>           Safety penalty weight for uncovered bce:keep (default 25.0)\n");
    write_stdout("  --beta <val>            Safety penalty weight for uncovered overflow ops (default 15.0)\n");
    write_stdout("  --threshold <val>       G-CRAP warning threshold (default 25.0)\n");
    write_stdout("  --include-tests         Include test suites in analysis (excluded by default)\n\n");
    write_stdout("Reporting & CI Ratchet:\n");
    write_stdout("  --format <fmt>          Report format: table (default), md, json, gcc, sarif\n");
    write_stdout("  --out <file>            Write output report to file\n");
    write_stdout("  --baseline <file>       Compare against baseline (default: .lit-baseline if present)\n");
    write_stdout("  --no-baseline           Disable automatic baseline comparison\n");
    write_stdout("  --save-baseline [file]  Save analysis as baseline snapshot (default: .lit-baseline)\n");
    write_stdout("  --delta <val>           G-CRAP regression tolerance for ratchet (default 5.0)\n");
    write_stdout("  --config <file>         Load custom configuration file (default: .litconfig)\n");
    write_stdout("  --help, -h              Print this help text\n\n");
}

fn resolve_crap_shim_path(out: u8[>..]&) -> bool {
    var env_val: u8[>..] = [];
    if env("GCRAP_SHIM_PATH", env_val) && env_val.len > 0 {
        if file_exists(env_val[..]) {
            normalize_slashes(env_val[..], out);
            return true;
        }
    }

    if file_exists("shim/proc.c") {
        out.append("shim/proc.c");
        return true;
    }

    if file_exists("../shim/proc.c") {
        out.append("../shim/proc.c");
        return true;
    }

    return false;
}

fn run_crap_cli() -> i32 {
    let all_args = args();

    // 1. Scan for custom config file and load LitConfig
    var custom_config: const u8[:] = "";
    for ci in all_args.len {
        if all_args[ci] == "--config" && ci + 1 < all_args.len {
            custom_config = all_args[ci + 1];
            break;
        }
    }
    var lit_cfg = LitConfig { .. };
    load_lit_config(custom_config, lit_cfg);

    var target_arg_buf: u8[..256] = [];
    if lit_cfg.src_dir_buf.len > 0 {
        target_arg_buf.append(lit_cfg.src_dir_buf[..]);
    }
    var cover_test_files: u8[>..]     = [];
    var bce_file:         const u8[:] = "";
    var auto_bce = false;
    var specs_file: const u8[:] = "";
    var auto_specs = false;
    var cov_files:    u8[>..]     = [];
    var lcov_file:    const u8[:] = "";
    var out_file:     const u8[:] = "";
    var baseline_buf: u8[..256]   = [];
    if lit_cfg.baseline_buf.len > 0 {
        baseline_buf.append(lit_cfg.baseline_buf[..]);
    }
    var save_baseline_buf: u8[..256] = [];
    var format_buf:        u8[..32]  = [];
    if lit_cfg.format_buf.len > 0 {
        format_buf.append(lit_cfg.format_buf[..]);
    } else {
        format_buf.append("table");
    }
    var no_baseline = false;

    var cfg = default_risk_config();
    if lit_cfg.has_default_cov {
        cfg.default_cov = lit_cfg.default_cov;
    }
    var delta_threshold: f64 = if lit_cfg.has_delta { lit_cfg.delta_threshold } else { 5.0 };
    var include_tests = if lit_cfg.has_include_tests { lit_cfg.include_tests } else { false };
    var enforce_gate = false;
    var gate_ceiling: f64 = if lit_cfg.has_gate_ceiling { lit_cfg.gate_ceiling } else { 25.0 };

    if all_args.len > 1 && all_args[1] == "gate" {
        enforce_gate = true;
    }

    if all_args.len <= 2 && target_arg_buf.len == 0 {
        print_crap_usage();
        return 1;
    }

    var i: i64 = 2;
    while i < all_args.len {
        let arg = all_args[i];
        if arg == "--help" || arg == "-h" {
            print_crap_usage();
            return 0;
        } else if arg == "--gate" {
            enforce_gate = true;
            if i + 1 < all_args.len && !slice_starts_with(all_args[i + 1], "-") {
                let val, ok = parse_f64_slice(all_args[i + 1]);
                if ok {
                    gate_ceiling = val;
                    i++;
                }
            }
        } else if arg == "--include-tests" {
            include_tests = true;
        } else if arg == "--cover" && i + 1 < all_args.len {
            let cov_arg = all_args[i + 1];
            var seg_start: i64 = 0;
            for c_i in cov_arg.len {
                if cov_arg[c_i] == ',' {
                    guard seg_start <= c_i && c_i <= cov_arg.len else { break; }
                    let seg = trim_ascii(cov_arg[seg_start..c_i]);
                    if seg.len > 0 {
                        cover_test_files.append(seg);
                        cover_test_files.push('\n');
                    }
                    seg_start = c_i + 1;
                }
            }
            if seg_start <= cov_arg.len {
                let last_seg = trim_ascii(cov_arg[seg_start..]);
                if last_seg.len > 0 {
                    cover_test_files.append(last_seg);
                    cover_test_files.push('\n');
                }
            }
            i++;
        } else if arg == "--bce-lines" {
            if i + 1 < all_args.len && !slice_starts_with(all_args[i + 1], "--") {
                bce_file = all_args[i + 1];
                i++;
            } else {
                auto_bce = true;
            }
        } else if arg == "--specs" {
            if i + 1 < all_args.len && !slice_starts_with(all_args[i + 1], "--") {
                specs_file = all_args[i + 1];
                i++;
            } else {
                auto_specs = true;
            }
        } else if arg == "--cov" && i + 1 < all_args.len {
            let cov_val = all_args[i + 1];
            let val, ok = parse_f64_slice(cov_val);
            if ok && val >= 0.0 && val <= 1.0 {
                cfg.default_cov = val;
            } else {
                cov_files.append(cov_val);
                cov_files.push('\n');
                cfg.has_coverage_profile = true;
            }
            i++;
        } else if arg == "--lcov" && i + 1 < all_args.len {
            lcov_file = all_args[i + 1];
            cfg.has_coverage_profile = true;
            i++;
        } else if arg == "--format" && i + 1 < all_args.len {
            format_buf.clear();
            format_buf.append(all_args[i + 1]);
            i++;
        } else if arg == "--out" && i + 1 < all_args.len {
            out_file = all_args[i + 1];
            i++;
        } else if arg == "--config" && i + 1 < all_args.len {
            i++;
        } else if arg == "--no-baseline" {
            no_baseline = true;
            baseline_buf.clear();
        } else if arg == "--baseline" && i + 1 < all_args.len {
            baseline_buf.clear();
            baseline_buf.append(all_args[i + 1]);
            i++;
        } else if arg == "--save-baseline" {
            if i + 1 < all_args.len && !slice_starts_with(all_args[i + 1], "-") {
                save_baseline_buf.clear();
                save_baseline_buf.append(all_args[i + 1]);
                i++;
            } else {
                default_save_baseline_path(lit_cfg.baseline_buf[..], save_baseline_buf);
            }
        } else if arg == "--default-cov" && i + 1 < all_args.len {
            let val, ok = parse_f64_slice(all_args[i + 1]);
            if ok { cfg.default_cov = val; }
            i++;
        } else if arg == "--alpha" && i + 1 < all_args.len {
            let val, ok = parse_f64_slice(all_args[i + 1]);
            if ok { cfg.alpha_bce_keep = val; }
            i++;
        } else if arg == "--beta" && i + 1 < all_args.len {
            let val, ok = parse_f64_slice(all_args[i + 1]);
            if ok { cfg.beta_ovf = val; }
            i++;
        } else if arg == "--threshold" && i + 1 < all_args.len {
            let val, ok = parse_f64_slice(all_args[i + 1]);
            if ok { cfg.gcrap_threshold = val; }
            i++;
        } else if arg == "--delta" && i + 1 < all_args.len {
            let val, ok = parse_f64_slice(all_args[i + 1]);
            if ok { delta_threshold = val; }
            i++;
        } else if !slice_starts_with(arg, "-") {
            if target_arg_buf.len == 0 {
                target_arg_buf.append(arg);
            } else if enforce_gate {
                let val, ok = parse_f64_slice(arg);
                if ok {
                    gate_ceiling = val;
                }
            }
        }
        i++;
    }

    // Auto-resolve baseline snapshot if not explicitly specified, not disabled, and not saving
    if baseline_buf.len == 0 && !no_baseline && save_baseline_buf.len == 0 {
        resolve_baseline_path(lit_cfg.baseline_buf[..], baseline_buf);
    }

    let save_baseline_file_path: const u8[:] = save_baseline_buf[..];
    let baseline_file:           const u8[:] = baseline_buf[..];
    let format_mode:             const u8[:] = format_buf[..];
    let target_arg:              const u8[:] = target_arg_buf[..];

    var target_buf: u8[>..] = [];
    if target_arg.len > 0 {
        target_buf.append(target_arg);
    } else if cover_test_files.len > 0 {
        var first_test_nl: i64 = -1;
        for c_i in cover_test_files.len {
            if cover_test_files[c_i] == '\n' { first_test_nl = c_i; break; }
        }
        if first_test_nl > 0 {
            target_buf.append(cover_test_files[..first_test_nl]);
        }
    }
    let target_path: const u8[:] = target_buf[..];

    if target_path.len == 0 {
        write_stderr("Error: Missing target file or directory path.\n");
        print_crap_usage();
        return 1;
    }

    var files_blob: u8[>..] = [];
    collect_goose_files(target_path, include_tests, files_blob);

    if files_blob.len == 0 {
        write_stderr("Error: No .goose files found under: ");
        write_stderr(target_path);
        write_stderr("\n");
        return 1;
    }

    var pool:       u8[>..]           = [];
    var functions:  FunctionInfo[>..] = [];
    var branches:   BranchSite[>..]   = [];
    var call_sites: CallSite[>..]     = [];

    // 1. Analyze AST for each file
    var line_start: i64 = 0;
    while line_start < files_blob.len {
        var line_end = files_blob.len;
        for j in line_start..files_blob.len {
            if files_blob[j] == '\n' {
                line_end = j;
                break;
            }
        }
        guard line_start >= 0 && line_end <= files_blob.len && line_start <= line_end else { break; }
        let fpath = trim_ascii(files_blob[line_start..line_end]);
        line_start = line_end + 1;

        if fpath.len > 0 {
            var file_src: u8[>..] = [];
            if read_file(fpath, file_src) {
                analyze_goose_file_with_calls(fpath, file_src, pool, functions, branches, call_sites);
            }
        }
    }

    if functions.len == 0 {
        write_stderr("Notice: No functions found in target files.\n");
        return 0;
    }

    // 2. Propagate untrusted trust taint across interprocedural call graph
    propagate_trust_taint(functions, call_sites, pool);

    // 3. Load or run `--bce-lines`
    var bce_blob: u8[>..] = [];
    if bce_file.len > 0 {
        read_file(bce_file, bce_blob);
    } else if auto_bce {
        run_goose_bce_lines(target_path, bce_blob);
    }
    if bce_blob.len > 0 {
        apply_bce_lines_blob(bce_blob, pool, functions, branches);
    }

    // 4. Load or run `--specs`
    var specs_blob: u8[>..] = [];
    if specs_file.len > 0 {
        read_file(specs_file, specs_blob);
    } else if auto_specs {
        run_goose_specs(target_path, specs_blob);
    }
    if specs_blob.len > 0 {
        apply_specs_blob(specs_blob, pool, functions);
    }

    // 5. Load coverage profile from file if specified
    if cov_files.len > 0 {
        var cf_start: i64 = 0;
        while cf_start < cov_files.len {
            var cf_end = cov_files.len;
            for j in cf_start..cov_files.len {
                if cov_files[j] == '\n' { cf_end = j; break; }
            }
            guard cf_start >= 0 && cf_end <= cov_files.len && cf_start <= cf_end else { break; }
            let cfile = trim_ascii(cov_files[cf_start..cf_end]);
            cf_start = cf_end + 1;
            guard cfile.len > 0 else { continue; }
            load_gcrap_profile(cfile, branches);
        }
    } else if lcov_file.len > 0 {
        load_lcov_profile(lcov_file, pool, functions, branches);
    }

    // 6. Aggregate branch coverage and safety invariants
    aggregate_coverage_metrics(cfg, functions, branches);

    // 7. Compute Classic CRAP and G-CRAP
    compute_crap_metrics(cfg, functions, branches);

    // 8. Save baseline snapshot if requested
    if save_baseline_file_path.len > 0 {
        if save_baseline_file(save_baseline_file_path, target_path, pool, functions) {
            write_stdout("Saved baseline snapshot to: ");
            write_stdout(save_baseline_file_path);
            write_stdout("\n");
        }
    }

    // 9. Evaluate CI ratchet gate if requested
    if baseline_file.len > 0 {
        var ratchet_report: u8[>..] = [];
        let violations = check_ratchet_gate(baseline_file, pool, functions, delta_threshold, ratchet_report);
        write_stdout(ratchet_report[..]);
        if violations > 0 {
            return 1;
        }
    }

    // 10. Format output report
    var report_buf: u8[>..] = [];
    if format_mode == "md" || format_mode == "markdown" {
        render_markdown_report(pool, functions, branches, cfg, report_buf);
    } else if format_mode == "json" {
        render_json_report(pool, functions, branches, report_buf);
    } else if format_mode == "gcc" {
        render_gcc_diagnostics(pool, functions, branches, report_buf);
    } else if format_mode == "sarif" {
        render_sarif_report(pool, functions, branches, report_buf);
    } else {
        render_terminal_report(pool, functions, branches, cfg, report_buf);
    }

    if out_file.len > 0 {
        write_file(out_file, report_buf[..]);
        write_stdout("Report written to: ");
        write_stdout(out_file);
        write_stdout("\n");
    } else {
        write_stdout(report_buf[..]);
    }

    // 11. Evaluate hardware complexity gate if requested
    if enforce_gate {
        var gate_violations: i64     = 0;
        var gate_report:     u8[>..] = [];
        gate_report.append("\n=== Hardware Complexity Gate Evaluation ===\n");
        gate_report.append("Ceiling: G-CRAP <= ");
        append_f64_1(gate_report, gate_ceiling);
        gate_report.append(", EffCC <= 15, unproven_bce == 0\n\n");

        for fi in functions.len {
            guard !functions[fi].ignored else { continue; }
            let g_val = functions[fi].g_crap;
            let eff = functions[fi].effective_cc;
            let arch = functions[fi].archetype;
            let unproven = functions[fi].uncovered_bce_keep;

            var violated = false;
            var reason: u8[>..] = [];

            if g_val > gate_ceiling {
                violated = true;
                reason.append("G-CRAP ");
                append_f64_1(reason, g_val);
                reason.append(" > ");
                append_f64_1(reason, gate_ceiling);
            }
            if eff > 15 && arch != ARCHETYPE_VERIFIED_DISPATCH && arch != ARCHETYPE_SAFE_PRIMITIVE {
                if reason.len > 0 { reason.append("; "); }
                violated = true;
                reason.append("EffCC ");
                append_i64(reason, eff);
                reason.append(" > 15");
            }
            if arch == ARCHETYPE_PANIC_HAZARD || unproven > 0 {
                if reason.len > 0 { reason.append("; "); }
                violated = true;
                reason.append("PANIC_HAZARD (unproven_bce: ");
                append_i64(reason, unproven);
                reason.append(")");
            }

            if violated {
                gate_violations += 1;
                gate_report.append("  [REJECT] ");
                let fn_name = pool_slice(pool, functions[fi].qual_off, functions[fi].qual_len);
                gate_report.append(fn_name);
                gate_report.append(" (line ");
                append_i64(gate_report, functions[fi].start_line);
                gate_report.append("): ");
                gate_report.append(reason[..]);
                gate_report.append("\n");
            }
        }

        if gate_violations > 0 {
            gate_report.append("\nGATE REJECTED: ");
            append_i64(gate_report, gate_violations);
            gate_report.append(" functions violated risk gate thresholds.\n");
            write_stdout(gate_report[..]);
            return 1;
        } else {
            gate_report.append("GATE PASSED: All functions within risk thresholds.\n\n");
            write_stdout(gate_report[..]);
        }
    }

    return 0;
}
