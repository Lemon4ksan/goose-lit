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
import crap.coverage.profile;
import crap.metrics.crap;
import crap.report.formatter;
import crap.report.ratchet;
import sys.config;

fn fnv1a_hash_bytes(s: const u8[:]) -> u64 {
    var h: u64 = 14695981039346656037;
    for b in s {
        h = (h ^ b) * 1099511628211;
    }
    return h;
}

fn is_valid_format_mode(fmt: const u8[:]) -> bool {
    return fmt == "table" || fmt == "md" || fmt == "markdown" ||
           fmt == "json" || fmt == "gcc" || fmt == "sarif";
}

fn print_crap_usage() {
    write_stdout("Usage: goose-lit crap <path|file.goose> [options]\n");
    write_stdout("       goose-lit gate <path|file.goose> [ceiling] [options]\n\n");
    write_stdout("Goose Change Risk Anti-Pattern (G-CRAP) and Safety Risk Radar.\n\n");
    write_stdout("Analysis & Execution Options:\n");
    write_stdout("  --gate [val]            Enforce G-CRAP risk gate ceiling (default 25.0, exits with 1 on violation)\n");
    write_stdout("  --bce-lines [file]      Import pre-captured goose --bce-lines output or auto-run (enabled by default)\n");
    write_stdout("  --no-bce                Disable automatic goose --bce-lines compiler bridge\n");
    write_stdout("  --specs [file]          Import pre-captured goose --specs output or auto-run\n");
    write_stdout("  --cov <file>            Load real .gcrap-cov branch profile (generate with 'goose-lit cov')\n");
    write_stdout("  --lcov <file.info>      Load LCOV tracefile\n");
    write_stdout("  --require-cov           Fail with exit code 2 if no real coverage profile is loaded\n");
    write_stdout("  --alpha <val>           Safety penalty weight for uncovered bce:keep (default 25.0)\n");
    write_stdout("  --beta <val>            Safety penalty weight for uncovered overflow ops (default 15.0)\n");
    write_stdout("  --threshold <val>       G-CRAP warning threshold (default 25.0)\n");
    write_stdout("  --explain               Print branch-level line hotspot breakdown for G-CRAP and BCE\n");
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

// Analyzes deduplicated `.goose` file paths from `files_blob` into `pool`, `functions`, `branches`, `call_sites`.
// Records the exact analyzed paths in `analyzed_files_blob` (in analysis order).
fn analyze_files_blob(
    files_blob:          const u8[:],
    pool:                u8[>..]&,
    functions:           FunctionInfo[>..]&,
    branches:            BranchSite[>..]&,
    call_sites:          CallSite[>..]&,
    analyzed_files_blob: u8[>..]&,
) {
    var seen_hashes: u64[>..] = [];
    var seen_lens:   i64[>..] = [];
    var file_src:    u8[>..]  = [];
    var line_start:  i64      = 0;
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
            file_src.clear();
            if read_file(fpath, file_src) {
                let h = fnv1a_hash_bytes(file_src[..]);
                let flen = file_src.len;
                var is_dup = false;
                for hi in seen_hashes.len {
                    if seen_hashes[hi] == h && seen_lens[hi] == flen {
                        is_dup = true;
                        break;
                    }
                }
                if !is_dup {
                    seen_hashes.push(h);
                    seen_lens.push(flen);
                    analyzed_files_blob.append(fpath);
                    analyzed_files_blob.push('\n');
                    analyze_goose_file_with_calls(fpath, file_src, pool, functions, branches, call_sites);
                }
            }
        }
    }
}

fn evaluate_gate_on_workspace(
    pool:                 const u8[:],
    functions:            const FunctionInfo[:],
    branches:             const BranchSite[:],
    baseline_file:        const u8[:],
    delta_threshold:      f64,
    gate_ceiling:         f64,
    has_coverage_profile: bool,
) -> i32 {
    var gate_violations: i64     = 0;
    var gate_report:     u8[>..] = [];
    gate_report.append("\n=== Hardware Complexity Gate Evaluation ===\n");
    gate_report.append("Ceiling: G-CRAP <= ");
    append_f64_1(gate_report, gate_ceiling);
    if has_coverage_profile {
        gate_report.append(", EffCC <= 15, unproven_bce == 0 (mode: real coverage)\n\n");
    } else {
        gate_report.append(" (static mode: EffCC <= 15, unproven_bce == 0; run 'goose-lit cov' for real G-CRAP)\n\n");
    }

    var reason: u8[>..] = [];
    for fi in functions.len {
        guard !functions[fi].ignored else { continue; }
        let g_val = functions[fi].g_crap;
        let eff = functions[fi].effective_cc;
        let arch = functions[fi].archetype;
        let unproven = functions[fi].uncovered_bce_keep;

        var violated = false;
        reason.clear();

        if has_coverage_profile && g_val > gate_ceiling {
            violated = true;
            reason.append("G-CRAP ");
            append_f64_1(reason, g_val);
            reason.append(" > ");
            append_f64_1(reason, gate_ceiling);
        }
        if eff > 15 && (!has_coverage_profile || (arch != ARCHETYPE_VERIFIED_DISPATCH && arch != ARCHETYPE_SAFE_PRIMITIVE)) {
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
            let fn_name = pool_slice(pool, functions[fi].qual_off, functions[fi].qual_len);
            let fn_file = pool_slice(pool, functions[fi].file_off, functions[fi].file_len);
            let is_base_ok = baseline_file.len > 0 &&
                is_grandfathered_in_baseline(baseline_file, pool, functions[fi], delta_threshold, has_coverage_profile);
            if is_base_ok {
                gate_report.append("  [BASELINE OK] ");
                gate_report.append(fn_name);
                gate_report.append(" (");
                gate_report.append(fn_file);
                gate_report.push(':');
                append_i64(gate_report, functions[fi].start_line);
                gate_report.append("): grandfathered within baseline delta\n");
            } else {
                gate_violations += 1;
                gate_report.append("  [REJECT] ");
                gate_report.append(fn_name);
                gate_report.append(" (");
                gate_report.append(fn_file);
                gate_report.push(':');
                append_i64(gate_report, functions[fi].start_line);
                gate_report.append("): ");
                gate_report.append(reason[..]);
                gate_report.append("\n");

                let first = functions[fi].first_branch;
                let count = functions[fi].branch_count;
                for bi in count {
                    let b_idx: i64 = first + bi;
                    if b_idx < branches.len {
                        let b = branches[b_idx];
                        if !b.covered && (b.bce_keep > 0 || b.ovf_ops > 0) {
                            gate_report.append("    -> lines ");
                            append_i64(gate_report, b.start_line);
                            gate_report.append("..");
                            append_i64(gate_report, b.end_line);
                            gate_report.append(" (");
                            gate_report.append(branch_kind_name(b.kind));
                            gate_report.append(", depth ");
                            append_i64(gate_report, b.depth);
                            gate_report.append("): bce_keep=");
                            append_i64(gate_report, b.bce_keep);
                            gate_report.append(", ovf_ops=");
                            append_i64(gate_report, b.ovf_ops);
                            gate_report.append("\n");
                        }
                    }
                }
            }
        }
    }

    if gate_violations > 0 {
        gate_report.append("\nGATE REJECTED: ");
        append_i64(gate_report, gate_violations);
        gate_report.append(" functions violated risk gate thresholds.\n");
        write_stdout(gate_report[..]);
        return 1;
    }
    gate_report.append("GATE PASSED: All functions within risk thresholds.\n\n");
    write_stdout(gate_report[..]);
    return 0;
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
    var target_paths_blob: u8[>..] = [];
    var explain_mode = false;
    var bce_file: const u8[:] = "";
    var auto_bce = if lit_cfg.has_bce { lit_cfg.bce_enabled } else { true };
    var allow_incomplete = false;
    var specs_file: const u8[:] = "";
    var auto_specs = false;
    var cov_explicit = false;
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
    var require_cov = false;

    var cfg = default_risk_config();
    var delta_threshold: f64 = if lit_cfg.has_delta { lit_cfg.delta_threshold } else { 5.0 };
    var include_tests = if lit_cfg.has_include_tests { lit_cfg.include_tests } else { false };
    var enforce_gate = false;
    var gate_ceiling: f64 = if lit_cfg.has_gate_ceiling { lit_cfg.gate_ceiling } else { 25.0 };

    if all_args.len > 1 && all_args[1] == "gate" {
        enforce_gate = true;
    }

    if all_args.len <= 2 && target_arg_buf.len == 0 {
        print_crap_usage();
        return 2;
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
        } else if arg == "--no-bce" {
            auto_bce = false;
            bce_file = "";
        } else if arg == "--allow-incomplete-analysis" {
            allow_incomplete = true;
        } else if arg == "--bce-lines" {
            if i + 1 < all_args.len && !slice_starts_with(all_args[i + 1], "-") && file_exists(all_args[i + 1]) && !is_dir(all_args[i + 1]) {
                bce_file = all_args[i + 1];
                auto_bce = false;
                i++;
            } else {
                auto_bce = true;
            }
        } else if arg == "--specs" {
            if i + 1 < all_args.len && !slice_starts_with(all_args[i + 1], "-") && file_exists(all_args[i + 1]) && !is_dir(all_args[i + 1]) {
                specs_file = all_args[i + 1];
                auto_specs = false;
                i++;
            } else {
                auto_specs = true;
            }
        } else if arg == "--cov" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --cov requires a .gcrap-cov profile path\n");
                return 2;
            }
            let cov_val = all_args[i + 1];
            let _, is_num = parse_f64_slice(cov_val);
            if is_num {
                write_stderr("Error: simulated numeric --cov is removed; pass a real .gcrap-cov file (generate via 'goose-lit cov') or omit --cov for static mode.\n");
                return 2;
            }
            guard file_exists(cov_val) else {
                write_stderr("Error: coverage profile file not found: ");
                write_stderr(cov_val);
                write_stderr("\n");
                return 2;
            }
            cov_files.append(cov_val);
            cov_files.push('\n');
            cfg.has_coverage_profile = true;
            cov_explicit = true;
            i++;
        } else if arg == "--require-cov" {
            require_cov = true;
        } else if arg == "--lcov" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --lcov requires a tracefile path\n");
                return 2;
            }
            lcov_file = all_args[i + 1];
            guard file_exists(lcov_file) else {
                write_stderr("Error: LCOV file not found: ");
                write_stderr(lcov_file);
                write_stderr("\n");
                return 2;
            }
            cfg.has_coverage_profile = true;
            cov_explicit = true;
            i++;
        } else if arg == "--format" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --format requires one of: table, md, json, gcc, sarif\n");
                return 2;
            }
            let fmt_arg = all_args[i + 1];
            guard is_valid_format_mode(fmt_arg) else {
                write_stderr("Error: invalid --format value (expected table, md, json, gcc, or sarif): ");
                write_stderr(fmt_arg);
                write_stderr("\n");
                return 2;
            }
            set_bounded(format_buf, fmt_arg);
            i++;
        } else if arg == "--out" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --out requires an output file path\n");
                return 2;
            }
            out_file = all_args[i + 1];
            i++;
        } else if arg == "--config" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --config requires a configuration file path\n");
                return 2;
            }
            i++;
        } else if arg == "--no-baseline" {
            no_baseline = true;
            baseline_buf.clear();
        } else if arg == "--baseline" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --baseline requires a baseline file path\n");
                return 2;
            }
            set_bounded(baseline_buf, all_args[i + 1]);
            i++;
        } else if arg == "--save-baseline" {
            if i + 1 < all_args.len && !slice_starts_with(all_args[i + 1], "-") {
                set_bounded(save_baseline_buf, all_args[i + 1]);
                i++;
            } else {
                default_save_baseline_path(lit_cfg.baseline_buf[..], save_baseline_buf);
            }
        } else if arg == "--default-cov" {
            write_stderr("Error: --default-cov is removed; use 'goose-lit cov' for real coverage profiles.\n");
            return 2;
        } else if arg == "--alpha" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --alpha requires a numeric weight\n");
                return 2;
            }
            let val, ok = parse_f64_slice(all_args[i + 1]);
            guard ok && val >= 0.0 else {
                write_stderr("Error: --alpha must be a non-negative number\n");
                return 2;
            }
            cfg.alpha_bce_keep = val;
            i++;
        } else if arg == "--beta" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --beta requires a numeric weight\n");
                return 2;
            }
            let val, ok = parse_f64_slice(all_args[i + 1]);
            guard ok && val >= 0.0 else {
                write_stderr("Error: --beta must be a non-negative number\n");
                return 2;
            }
            cfg.beta_ovf = val;
            i++;
        } else if arg == "--threshold" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --threshold requires a numeric value\n");
                return 2;
            }
            let val, ok = parse_f64_slice(all_args[i + 1]);
            guard ok && val >= 0.0 else {
                write_stderr("Error: --threshold must be a non-negative number\n");
                return 2;
            }
            cfg.gcrap_threshold = val;
            i++;
        } else if arg == "--explain" {
            explain_mode = true;
        } else if arg == "--delta" {
            guard i + 1 < all_args.len else {
                write_stderr("Error: --delta requires a numeric value\n");
                return 2;
            }
            let val, ok = parse_f64_slice(all_args[i + 1]);
            guard ok && val >= 0.0 else {
                write_stderr("Error: --delta must be a non-negative number\n");
                return 2;
            }
            delta_threshold = val;
            i++;
        } else if slice_starts_with(arg, "-") {
            write_stderr("Error: unknown option: ");
            write_stderr(arg);
            write_stderr("\n");
            return 2;
        } else {
            let val, ok = parse_f64_slice(arg);
            if enforce_gate && ok && target_paths_blob.len > 0 && !file_exists(arg) && !is_dir(arg) {
                gate_ceiling = val;
            } else {
                target_paths_blob.append(arg);
                target_paths_blob.push('\n');
                if target_arg_buf.len == 0 {
                    let copy_len = min(arg.len, target_arg_buf.cap);
                    target_arg_buf.append(arg[..copy_len]);
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
    let target_path:             const u8[:] = target_arg_buf[..];

    if target_path.len == 0 {
        write_stderr("Error: Missing target file or directory path.\n");
        print_crap_usage();
        return 2;
    }

    if !file_exists(target_path) && !is_dir(target_path) {
        write_stderr("Error: target path does not exist: ");
        write_stderr(target_path);
        write_stderr("\n");
        return 2;
    }

    var files_blob: u8[>..] = [];
    if target_paths_blob.len > 0 {
        var tp_start: i64 = 0;
        while tp_start < target_paths_blob.len {
            var tp_end = target_paths_blob.len;
            for j in tp_start..target_paths_blob.len {
                if target_paths_blob[j] == '\n' {
                    tp_end = j;
                    break;
                }
            }
            let t_item = trim_ascii(target_paths_blob[tp_start..tp_end]);
            tp_start = tp_end + 1;
            if t_item.len > 0 {
                if !file_exists(t_item) && !is_dir(t_item) {
                    write_stderr("Error: target path does not exist: ");
                    write_stderr(t_item);
                    write_stderr("\n");
                    return 2;
                }
                collect_goose_files_filtered(t_item, include_tests, lit_cfg.exclude_buf[..], files_blob);
            }
        }
    } else {
        collect_goose_files_filtered(target_path, include_tests, lit_cfg.exclude_buf[..], files_blob);
    }

    if files_blob.len == 0 {
        write_stderr("Error: No .goose files found under: ");
        write_stderr(target_path);
        write_stderr("\n");
        return 2;
    }

    var pool:                u8[>..]           = [];
    var functions:           FunctionInfo[>..] = [];
    var branches:            BranchSite[>..]   = [];
    var call_sites:          CallSite[>..]     = [];
    var analyzed_files_blob: u8[>..]           = [];

    // 1. Analyze AST for each file (deduplicating identical mirrored copies by FNV-1a content hash + length)
    analyze_files_blob(files_blob[..], pool, functions, branches, call_sites, analyzed_files_blob);

    if functions.len == 0 {
        write_stderr("Notice: No functions found in target files.\n");
        return 0;
    }

    // 2. Propagate untrusted trust taint across interprocedural call graph
    propagate_trust_taint(functions, call_sites, pool);

    // 3. Load or run `--bce-lines`
    var bce_blob: u8[>..] = [];
    if bce_file.len > 0 {
        if read_file(bce_file, bce_blob) {
            cfg.bce_state = ANALYSIS_COMPLETE;
        } else {
            cfg.bce_state = ANALYSIS_FAILED;
        }
    } else if auto_bce {
        let bce_rc = run_goose_bce_lines(target_path, bce_blob);
        if bce_rc == 0 || bce_blob.len > 0 {
            cfg.bce_state = ANALYSIS_COMPLETE;
        } else {
            cfg.bce_state = ANALYSIS_FAILED;
            if enforce_gate && !allow_incomplete {
                write_stderr("Warning: goose --bce-lines compiler check failed; safety analysis is incomplete.\n");
            }
        }
    } else {
        cfg.bce_state = ANALYSIS_NOT_REQUESTED;
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

    // Auto-load real coverage profile from `.litconfig` (`cov_profile`) when not overridden
    if !cov_explicit && lit_cfg.cov_profile_buf.len > 0 && file_exists(lit_cfg.cov_profile_buf[..]) {
        cov_files.append(lit_cfg.cov_profile_buf[..]);
        cov_files.push('\n');
        cfg.has_coverage_profile = true;
    }
    if require_cov && !cfg.has_coverage_profile {
        write_stderr("Error: --require-cov specified but no real coverage profile was loaded (run 'goose-lit cov' first).\n");
        return 2;
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
            if slice_ends_with(cfile, ".info") || slice_ends_with(cfile, ".lcov") {
                load_lcov_profile(cfile, pool, functions, branches);
            } else {
                load_gcrap_profile(cfile, branches);
            }
        }
    } else if lcov_file.len > 0 {
        load_lcov_profile(lcov_file, pool, functions, branches);
    }

    // 6. Aggregate branch coverage and safety invariants
    aggregate_coverage_metrics(cfg, functions, branches);

    // 7. Compute Classic CRAP and G-CRAP
    compute_crap_metrics(cfg, functions, branches);

    let is_machine_stdout = (out_file.len == 0) &&
        (format_mode == "json" || format_mode == "sarif" || format_mode == "gcc");

    // 8. Save baseline snapshot if requested
    if save_baseline_file_path.len > 0 {
        if save_baseline_file(
            save_baseline_file_path,
            target_path,
            pool,
            functions,
            cfg.has_coverage_profile,
        ) {
            if is_machine_stdout {
                write_stderr("Saved baseline snapshot to: ");
                write_stderr(save_baseline_file_path);
                write_stderr("\n");
            } else {
                write_stdout("Saved baseline snapshot to: ");
                write_stdout(save_baseline_file_path);
                write_stdout("\n");
            }
        }
    }

    // 9. Evaluate CI ratchet gate if requested (in radar mode)
    var ratchet_failed = false;
    if baseline_file.len > 0 && !enforce_gate {
        var ratchet_report: u8[>..] = [];
        let violations = check_ratchet_gate(
            baseline_file,
            pool,
            functions,
            delta_threshold,
            cfg.has_coverage_profile,
            ratchet_report,
        );
        if is_machine_stdout {
            write_stderr(ratchet_report[..]);
        } else {
            write_stdout(ratchet_report[..]);
        }
        if violations > 0 {
            if !is_machine_stdout {
                return 1;
            }
            ratchet_failed = true;
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
    if ratchet_failed {
        return 1;
    }

    // 11. Branch-level hotspot explanation if requested
    if explain_mode && !enforce_gate {
        var explain_buf: u8[>..] = [];
        explain_buf.append("\n=== G-CRAP Branch Hotspot Breakdown ===\n");
        for fi in functions.len {
            guard !functions[fi].ignored else { continue; }
            if functions[fi].g_crap >= 5.0 || functions[fi].uncovered_bce_keep > 0 || functions[fi].total_ovf_ops > 0 {
                let fn_name = pool_slice(pool, functions[fi].qual_off, functions[fi].qual_len);
                let fn_file = pool_slice(pool, functions[fi].file_off, functions[fi].file_len);
                explain_buf.append("  ");
                explain_buf.append(fn_file);
                explain_buf.push(':');
                append_i64(explain_buf, functions[fi].start_line);
                explain_buf.append(" ");
                explain_buf.append(fn_name);
                explain_buf.append(" (G-CRAP ");
                append_f64_1(explain_buf, functions[fi].g_crap);
                explain_buf.append(", EffCC ");
                append_i64(explain_buf, functions[fi].effective_cc);
                explain_buf.append("):\n");
                let first = functions[fi].first_branch;
                let count = functions[fi].branch_count;
                for bi in count {
                    let b_idx: i64 = first + bi;
                    if b_idx < branches.len {
                        let b = branches[b_idx];
                        if !b.covered && (b.bce_keep > 0 || b.ovf_ops > 0) {
                            explain_buf.append("    -> lines ");
                            append_i64(explain_buf, b.start_line);
                            explain_buf.append("..");
                            append_i64(explain_buf, b.end_line);
                            explain_buf.append(" (");
                            explain_buf.append(branch_kind_name(b.kind));
                            explain_buf.append(", depth ");
                            append_i64(explain_buf, b.depth);
                            explain_buf.append("): bce_keep=");
                            append_i64(explain_buf, b.bce_keep);
                            explain_buf.append(", ovf_ops=");
                            append_i64(explain_buf, b.ovf_ops);
                            explain_buf.append("\n");
                        }
                    }
                }
            }
        }
        write_stdout(explain_buf[..]);
    }

    // 12. Evaluate hardware complexity gate if requested
    if enforce_gate {
        return evaluate_gate_on_workspace(
            pool[..],
            functions[..],
            branches[..],
            baseline_file,
            delta_threshold,
            gate_ceiling,
            cfg.has_coverage_profile,
        );
    }

    return 0;
}
