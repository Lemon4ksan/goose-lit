// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// sloc/cli.goose - CLI argument parser and orchestrator for `goose-lit sloc`.
namespace lit;

import std;
import os;
import sys.bytes;
import sys.proc;
import sys.config;
import crap.ast.model;
import sloc.model;
import sloc.scanner;
import sloc.correlate;
import sloc.baseline;
import sloc.report;

fn print_sloc_usage() {
    write_stdout("Usage: goose-lit sloc [path...] [options]\n\n");
    write_stdout("Cycles-vs-SLOC radar, anti-packing guard, compiler smell ratchet, and Pareto gate.\n\n");
    write_stdout("Options:\n");
    write_stdout("  --map <file>            Scope map (default from .litconfig sloc_map or .lit/sloc-map)\n");
    write_stdout("  --profile <tsv>         Correlate pre-captured @LIT_BENCH/@LIT_STAGE TSV (repeatable)\n");
    write_stdout("  --run-profile [bench]   Run `goose-lit profile` live (repeatable; bare runs mapped benches)\n");
    write_stdout("  --cc <compiler>         C compiler for --run-profile (relative paths resolved)\n");
    write_stdout("  --benchtime <ms>        Target duration per benchmark case\n");
    write_stdout("  --filter <pat>          Substring filter for benchmark cases\n");
    write_stdout("  --bce                   Attach `goose --bce-lines` across sloc_bce_entries\n");
    write_stdout("  --bce-entry <file>      Explicit entry point for --bce (repeatable)\n");
    write_stdout("  --exclude <prefix>      Exclude path prefix from SLOC scan (repeatable)\n");
    write_stdout("  --baseline <file>       Compare against baseline & enforce ratchet/Pareto gate\n");
    write_stdout("  --no-baseline           Disable automatic baseline loading\n");
    write_stdout("  --save-baseline [file]  Write snapshot to baseline (preserves prior cycles)\n");
    write_stdout("  --reset-cycles          Clear saved SCOPE cycle rows when saving baseline\n");
    write_stdout("  --sloc-delta <N>        Allowed net SLOC growth over baseline (default: 0)\n");
    write_stdout("  --cycle-noise <pct>     Allowed cycle jitter percentage (default: 5.0)\n");
    write_stdout("  --allow-hot-growth      Permit scope growth if norm_cl <= 0.90 (credits TOTAL)\n");
    write_stdout("  --check-packing         Reject files exceeding packing ceiling or packed delta\n");
    write_stdout("  --max-packing <val>     Max statements/SLOC ceiling (default: 1.35)\n");
    write_stdout("  --max-token-density <v> Optional tokens/SLOC ceiling (default: 0 = report only)\n");
    write_stdout("  --check-smells          Fail if local compiler smells increase above baseline\n");
    write_stdout("  --no-check-smells       Report local compiler smells without gating\n");
    write_stdout("  --check-format          Also verify `goose format --check` on scanned files\n");
    write_stdout("  --smells                Print per-file compiler smells & advisory dead_fn list\n");
    write_stdout("  --include-tests         Include tests/ when scanning\n");
    write_stdout("  --format <fmt>          table (default), md, json, tsv\n");
    write_stdout("  --out <file>            Write formatted report to file\n");
    write_stdout("  --config <file>         Custom .litconfig path\n");
    write_stdout("  --help, -h              Print this help text\n");
}

fn append_nl_grow(dst: u8[>..]&, item: const u8[:]) {
    guard item.len > 0 else { return; }
    dst.append(item);
    dst.push('\n');
}

fn is_valid_sloc_format(fmt: const u8[:]) -> bool {
    return fmt == "table" || fmt == "md" || fmt == "markdown" || fmt == "json" || fmt == "tsv";
}

fn is_bench_file_arg(arg_s: const u8[:]) -> bool {
    guard arg_s.len > 0 && !crap::slice_starts_with(arg_s, "-") else { return false; }
    return crap::slice_ends_with(arg_s, ".goose") || (file_exists(arg_s) && !is_dir(arg_s));
}

fn is_baseline_file_arg(arg_s: const u8[:]) -> bool {
    guard arg_s.len > 0 && !crap::slice_starts_with(arg_s, "-") else { return false; }
    if arg_s == "." || arg_s == "./" || arg_s == ".\\" { return false; }
    if crap::slice_ends_with(arg_s, "/") || crap::slice_ends_with(arg_s, "\\") { return false; }
    if is_dir(arg_s) { return false; }
    return true;
}

fn parse_sloc_cli_args(
    all_args:          const (u8[:])[:],
    lit_cfg:           const crap::LitConfig&,
    cfg:               SlocCliArgs&,
    targets_blob:      u8[>..]&,
    profile_tsvs_blob: u8[>..]&,
    run_benches_blob:  u8[>..]&,
    bce_entries_blob:  u8[>..]&,
    show_help:         bool&,
) -> bool {
    cfg = SlocCliArgs { .. };
    targets_blob.clear();
    profile_tsvs_blob.clear();
    run_benches_blob.clear();
    bce_entries_blob.clear();
    show_help = false;
    let _ = crap::set_bounded(cfg.format, "table");

    if lit_cfg.sloc_map_buf.len > 0 {
        let _ = crap::set_bounded(cfg.map_path, lit_cfg.sloc_map_buf[..]);
    }
    if lit_cfg.sloc_exclude_buf.len > 0 {
        let _ = crap::set_bounded(cfg.exclude_blob, lit_cfg.sloc_exclude_buf[..]);
        cfg.has_custom_exclude = true;
    }
    if lit_cfg.sloc_bce_entries_buf.len > 0 {
        bce_entries_blob.append(lit_cfg.sloc_bce_entries_buf[..]);
    }
    if lit_cfg.cc_buf.len > 0 {
        let _ = crap::set_bounded(cfg.cc, lit_cfg.cc_buf[..]);
    }
    if lit_cfg.has_sloc_max_packing {
        cfg.max_packing = lit_cfg.sloc_max_packing;
    }
    if lit_cfg.has_sloc_max_delta {
        cfg.sloc_delta = lit_cfg.sloc_max_delta;
    }
    if lit_cfg.has_sloc_cycle_noise {
        cfg.cycle_noise = lit_cfg.sloc_cycle_noise;
    }

    var cli_exclude_given = false;
    var cli_bce_entry_given = false;
    var idx: i64 = 2;

    while idx < all_args.len {
        let a = all_args[idx];
        if a == "--help" || a == "-h" {
            show_help = true;
            return true;
        } else if a == "--map" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --map requires a file path\n");
                return false;
            }
            idx += 1;
            let _ = crap::set_bounded(cfg.map_path, all_args[idx]);
            cfg.explicit_map = true;
        } else if a == "--profile" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --profile requires a TSV path\n");
                return false;
            }
            idx += 1;
            append_nl_grow(profile_tsvs_blob, all_args[idx]);
        } else if a == "--run-profile" {
            if idx + 1 < all_args.len && is_bench_file_arg(all_args[idx + 1]) {
                idx += 1;
                append_nl_grow(run_benches_blob, all_args[idx]);
            } else {
                cfg.run_profile_all = true;
            }
        } else if a == "--cc" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --cc requires a compiler path\n");
                return false;
            }
            idx += 1;
            let _ = crap::set_bounded(cfg.cc, all_args[idx]);
        } else if a == "--benchtime" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --benchtime requires milliseconds\n");
                return false;
            }
            idx += 1;
            let _ = crap::set_bounded(cfg.benchtime, all_args[idx]);
        } else if a == "--filter" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --filter requires a substring\n");
                return false;
            }
            idx += 1;
            let _ = crap::set_bounded(cfg.filter, all_args[idx]);
        } else if a == "--bce" {
            cfg.bce_enabled = true;
        } else if a == "--bce-entry" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --bce-entry requires a file path\n");
                return false;
            }
            idx += 1;
            if !cli_bce_entry_given {
                bce_entries_blob.clear();
                cli_bce_entry_given = true;
            }
            cfg.bce_enabled = true;
            append_nl_grow(bce_entries_blob, all_args[idx]);
        } else if a == "--exclude" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --exclude requires a path prefix\n");
                return false;
            }
            idx += 1;
            cli_exclude_given = true;
            cfg.has_custom_exclude = true;
            crap::append_exclude_patterns(all_args[idx], cfg.exclude_blob);
        } else if a == "--baseline" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --baseline requires a file path\n");
                return false;
            }
            idx += 1;
            let _ = crap::set_bounded(cfg.baseline_path, all_args[idx]);
            cfg.explicit_baseline = true;
            cfg.no_baseline = false;
        } else if a == "--no-baseline" {
            cfg.no_baseline = true;
            cfg.explicit_baseline = false;
        } else if a == "--save-baseline" {
            cfg.save_baseline = true;
            if idx + 1 < all_args.len && is_baseline_file_arg(all_args[idx + 1]) {
                idx += 1;
                let _ = crap::set_bounded(cfg.save_baseline_path, all_args[idx]);
            }
        } else if a == "--reset-cycles" {
            cfg.reset_cycles = true;
        } else if a == "--sloc-delta" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --sloc-delta requires an integer\n");
                return false;
            }
            idx += 1;
            let v, ok = crap::parse_i64_slice(all_args[idx]);
            guard ok else {
                write_stdout("Error: invalid --sloc-delta value\n");
                return false;
            }
            cfg.sloc_delta = v;
        } else if a == "--cycle-noise" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --cycle-noise requires a percentage\n");
                return false;
            }
            idx += 1;
            let v, ok = crap::parse_f64_slice(all_args[idx]);
            guard ok && v >= 0.0 else {
                write_stdout("Error: invalid --cycle-noise value\n");
                return false;
            }
            cfg.cycle_noise = v;
        } else if a == "--allow-hot-growth" {
            cfg.allow_hot_growth = true;
        } else if a == "--check-packing" {
            cfg.check_packing = true;
        } else if a == "--max-packing" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --max-packing requires a float\n");
                return false;
            }
            idx += 1;
            let v, ok = crap::parse_f64_slice(all_args[idx]);
            guard ok && v > 0.0 else {
                write_stdout("Error: invalid --max-packing value\n");
                return false;
            }
            cfg.max_packing = v;
        } else if a == "--max-token-density" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --max-token-density requires a float\n");
                return false;
            }
            idx += 1;
            let v, ok = crap::parse_f64_slice(all_args[idx]);
            guard ok && v >= 0.0 else {
                write_stdout("Error: invalid --max-token-density value\n");
                return false;
            }
            cfg.max_token_density = v;
        } else if a == "--check-smells" {
            cfg.check_smells = true;
            cfg.explicit_smell_flag = true;
        } else if a == "--no-check-smells" {
            cfg.check_smells = false;
            cfg.explicit_smell_flag = true;
        } else if a == "--check-format" {
            cfg.check_format = true;
        } else if a == "--smells" {
            cfg.show_smells = true;
        } else if a == "--include-tests" {
            cfg.include_tests = true;
            if !cli_exclude_given {
                cfg.exclude_blob.clear();
                cfg.has_custom_exclude = false;
            }
        } else if a == "--format" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --format requires table, md, json, or tsv\n");
                return false;
            }
            idx += 1;
            guard is_valid_sloc_format(all_args[idx]) else {
                write_stdout("Error: invalid --format value: ");
                write_stdout(all_args[idx]);
                write_stdout("\n");
                return false;
            }
            let _ = crap::set_bounded(cfg.format, all_args[idx]);
        } else if a == "--out" {
            guard idx + 1 < all_args.len else {
                write_stdout("Error: --out requires a file path\n");
                return false;
            }
            idx += 1;
            let _ = crap::set_bounded(cfg.out_path, all_args[idx]);
        } else if a == "--config" {
            idx += 1;
        } else if crap::slice_starts_with(a, "-") {
            write_stdout("Error: unknown option for sloc: ");
            write_stdout(a);
            write_stdout("\n");
            return false;
        } else {
            var norm_t: u8[>..] = [];
            normalize_map_path(a, norm_t);
            if norm_t.len == 0 {
                norm_t.push('.');
            }
            append_nl_grow(targets_blob, norm_t[..]);
        }
        idx += 1;
    }

    if targets_blob.len == 0 {
        append_nl_grow(targets_blob, ".");
    }
    return true;
}

fn targets_are_full_repo(targets_blob: const u8[:]) -> bool {
    var count: i64 = 0;
    var all_dot = true;
    var rem = targets_blob;
    while rem.len > 0 {
        let t, rest = crap::take_next_line(rem);
        rem = rest;
        guard t.len > 0 else { continue; }
        count += 1;
        if t != "." && t != "./" {
            all_dot = false;
        }
    }
    return count == 1 && all_dot;
}

fn collect_dedup_sloc_files(
    targets_blob:  const u8[:],
    include_tests: bool,
    exclude_blob:  const u8[:],
    out_blob:      u8[>..]&,
) {
    var raw_paths: u8[>..] = [];
    var t_rem = targets_blob;
    while t_rem.len > 0 {
        let target, t_rest = crap::take_next_line(t_rem);
        t_rem = t_rest;
        guard target.len > 0 else { continue; }
        raw_paths.clear();
        crap::collect_goose_files_filtered(target, include_tests, exclude_blob, raw_paths);

        var p_rem: const u8[:] = raw_paths[..];
        while p_rem.len > 0 {
            let fpath, p_rest = crap::take_next_line(p_rem);
            p_rem = p_rest;
            if fpath.len > 0 && !crap::blob_contains_line(out_blob[..], fpath) {
                out_blob.append(fpath);
                out_blob.push('\n');
            }
        }
    }
}

fn collect_default_bce_entries(targets_blob: const u8[:], out_entries: u8[>..]&) {
    if !targets_are_full_repo(targets_blob) {
        out_entries.append(targets_blob);
        return;
    }
    var entries: u8[>..] = [];
    guard list_dir(".", entries) else { return; }
    var e_rem: const u8[:] = entries[..];
    while e_rem.len > 0 {
        let name, rest = crap::take_next_line(e_rem);
        e_rem = rest;
        let ok = crap::slice_ends_with(name, ".goose") &&
            !crap::slice_ends_with(name, "_test.goose") &&
            !crap::slice_starts_with(name, "test_");
        if ok {
            out_entries.append(name);
            out_entries.push('\n');
        }
    }
}

fn handle_sloc_cli(all_args: const (u8[:])[:], lit_cfg: const crap::LitConfig&) -> i32 {
    var cfg = SlocCliArgs { .. };
    var targets_blob:      u8[>..] = [];
    var profile_tsvs_blob: u8[>..] = [];
    var run_benches_blob:  u8[>..] = [];
    var bce_entries_blob:  u8[>..] = [];
    var show_help = false;
    guard parse_sloc_cli_args(
        all_args,
        lit_cfg,
        cfg,
        targets_blob,
        profile_tsvs_blob,
        run_benches_blob,
        bce_entries_blob,
        show_help,
    ) else { return 2; }
    if show_help {
        print_sloc_usage();
        return 0;
    }

    // Validate explicitly provided --map and --baseline paths early
    var map_file: u8[..256] = [];
    if cfg.map_path.len > 0 {
        let _ = crap::set_bounded(map_file, cfg.map_path[..]);
    } else if file_exists(".lit/sloc-map") {
        let _ = crap::set_bounded(map_file, ".lit/sloc-map");
    }
    if cfg.explicit_map && (map_file.len == 0 || !file_exists(map_file[..])) {
        write_stdout("Error: scope map file not found: ");
        write_stdout(cfg.map_path[..]);
        write_stdout("\n");
        return 2;
    }
    if cfg.explicit_baseline && !cfg.save_baseline && !file_exists(cfg.baseline_path[..]) {
        write_stdout("Error: baseline file not found: ");
        write_stdout(cfg.baseline_path[..]);
        write_stdout("\n");
        return 2;
    }

    let is_partial = !targets_are_full_repo(targets_blob[..]);
    var files_blob: u8[>..] = [];
    collect_dedup_sloc_files(targets_blob[..], cfg.include_tests, cfg.exclude_blob[..], files_blob);

    var pool:  u8[>..]            = [];
    var files: FileSlocStats[>..] = [];
    var dirs:  DirSlocStats[>..]  = [];
    scan_sloc_files(files_blob[..], pool, files, dirs);

    var dead_fns: DeadFnCandidate[>..] = [];
    if cfg.show_smells {
        collect_repo_dead_fns(".", files_blob[..], pool, dead_fns);
    }

    var bce_measured = false;
    if cfg.bce_enabled {
        var bce_entries: u8[>..] = [];
        if bce_entries_blob.len > 0 {
            bce_entries.append(bce_entries_blob[..]);
        } else {
            collect_default_bce_entries(targets_blob[..], bce_entries);
        }
        bce_measured = attach_multi_entry_bce(bce_entries[..], pool[..], files);
    }

    var format_fails: i64     = 0;
    var format_bad:   u8[>..] = [];
    if cfg.check_format {
        format_fails = check_goose_format_files(files_blob[..], format_bad);
    }

    // Load scope map
    var maps: ScopeMapping[>..] = [];
    if map_file.len > 0 && file_exists(map_file[..]) {
        var map_raw: u8[>..] = [];
        if !read_file(map_file[..], map_raw) {
            if cfg.explicit_map {
                write_stdout("Error: failed to read scope map: ");
                write_stdout(map_file[..]);
                write_stdout("\n");
                return 2;
            }
        } else {
            let _ = parse_sloc_map(map_raw[..], pool, maps);
        }
    }

    // Collect profile TSV samples (from --profile and/or --run-profile)
    var tsv_all: u8[>..]     = [];
    var one_tsv: u8[>..]     = [];
    var p_rem:   const u8[:] = profile_tsvs_blob[..];
    while p_rem.len > 0 {
        let tsv_p, rest = crap::take_next_line(p_rem);
        p_rem = rest;
        guard tsv_p.len > 0 else { continue; }
        one_tsv.clear();
        guard read_file(tsv_p, one_tsv) else {
            write_stdout("Error: failed to read profile TSV: ");
            write_stdout(tsv_p);
            write_stdout("\n");
            return 1;
        }
        tsv_all.append(one_tsv[..]);
        tsv_all.push('\n');
    }

    if cfg.run_profile_all || run_benches_blob.len > 0 {
        var benches: u8[>..] = [];
        if run_benches_blob.len > 0 {
            benches.append(run_benches_blob[..]);
        } else {
            collect_unique_map_benches(maps[..], pool[..], benches);
            if benches.len == 0 && lit_cfg.profile_target_buf.len > 0 {
                benches.append(lit_cfg.profile_target_buf[..]);
                benches.push('\n');
            }
        }
        guard benches.len > 0 else {
            write_stdout("Error: --run-profile found no benchmark file in args, --map, or .litconfig profile_target\n");
            return 2;
        }
        let prc = run_profile_benchmarks(benches[..], cfg.cc[..], cfg.benchtime[..], cfg.filter[..], tsv_all);
        if prc != 0 {
            return prc;
        }
    }

    var samples: ProfileSample[>..] = [];
    if tsv_all.len > 0 {
        let _ = parse_profile_tsv_samples(tsv_all[..], samples);
    }

    // Load baseline (for ratchet evaluation and/or preserving prior SCOPE cycles on save)
    var base_pool: u8[>..] = [];
    var base = SlocBaseline { .. };
    var base_files:  SlocBaselineFile[>..]  = [];
    var base_scopes: SlocBaselineScope[>..] = [];

    var resolved_base: u8[..256] = [];
    if !cfg.no_baseline {
        if cfg.baseline_path.len > 0 {
            let _ = crap::set_bounded(resolved_base, cfg.baseline_path[..]);
        } else {
            let _ = crap::resolve_sloc_baseline_path(lit_cfg.sloc_baseline_buf[..], resolved_base);
        }
    } else if cfg.save_baseline {
        if cfg.save_baseline_path.len > 0 && file_exists(cfg.save_baseline_path[..]) {
            let _ = crap::set_bounded(resolved_base, cfg.save_baseline_path[..]);
        } else {
            let _ = crap::resolve_sloc_baseline_path(lit_cfg.sloc_baseline_buf[..], resolved_base);
        }
    }

    if resolved_base.len > 0 && file_exists(resolved_base[..]) {
        var b_raw: u8[>..] = [];
        if !read_file(resolved_base[..], b_raw) || !parse_sloc_baseline(b_raw[..], base_pool, base, base_files, base_scopes) {
            if cfg.explicit_baseline && !cfg.save_baseline {
                write_stdout("Error: failed to parse baseline file: ");
                write_stdout(resolved_base[..]);
                write_stdout("\n");
                return 2;
            }
        }
    }

    var scopes: CycleSlocRow[>..] = [];
    if maps.len > 0 {
        correlate_scopes(maps[..], pool[..], files[..], samples[..], targets_blob[..], is_partial, scopes);
    }

    var gate_res = SlocGateResult { .. };
    if cfg.save_baseline {
        // Still enforce packing/format anti-gaming before saving a baseline
        var empty_b = SlocBaseline { .. };
        var empty_bf: SlocBaselineFile[>..]  = [];
        var empty_bs: SlocBaselineScope[>..] = [];
        evaluate_sloc_gate(cfg, pool[..], maps[..], files, scopes, empty_b, "", empty_bf[..], empty_bs[..], is_partial, format_fails, gate_res);
        if gate_res.exit_code == 0 {
            var save_dst: u8[..256] = [];
            if cfg.save_baseline_path.len > 0 {
                let _ = crap::set_bounded(save_dst, cfg.save_baseline_path[..]);
            } else {
                crap::default_save_sloc_baseline_path(lit_cfg.sloc_baseline_buf[..], save_dst);
            }
            let preserve_cycles = !cfg.reset_cycles;
            var serialized: u8[>..] = [];
            serialize_sloc_baseline(
                pool[..],
                files[..],
                dirs[..],
                scopes[..],
                bce_measured,
                base,
                base_pool[..],
                base_scopes[..],
                preserve_cycles,
                serialized,
            );
            guard write_file(save_dst[..], serialized[..]) else {
                write_stdout("Error: failed to write baseline to ");
                write_stdout(save_dst[..]);
                write_stdout("\n");
                return 1;
            }
            if cfg.format[..] == "table" || cfg.format[..] == "md" || cfg.format[..] == "markdown" {
                write_stdout("Saved sloc baseline to ");
                write_stdout(save_dst[..]);
                write_stdout("\n");
            }
        }
    } else {
        evaluate_sloc_gate(cfg, pool[..], maps[..], files, scopes, base, base_pool[..], base_files[..], base_scopes[..], is_partial, format_fails, gate_res);
    }

    var report: u8[>..] = [];
    if cfg.format[..] == "json" {
        format_sloc_report_json(cfg, pool[..], files[..], dirs[..], dead_fns[..], scopes[..], gate_res, report);
    } else if cfg.format[..] == "md" || cfg.format[..] == "markdown" {
        format_sloc_report_md(cfg, pool[..], files[..], dirs[..], dead_fns[..], scopes[..], gate_res, report);
    } else if cfg.format[..] == "tsv" {
        format_sloc_report_tsv(cfg, pool[..], files[..], dirs[..], dead_fns[..], scopes[..], gate_res, report);
    } else {
        format_sloc_report_table(cfg, pool[..], files[..], dirs[..], dead_fns[..], scopes[..], gate_res, report);
    }

    if cfg.out_path.len > 0 {
        guard write_file(cfg.out_path[..], report[..]) else {
            write_stdout("Error: failed to write report to ");
            write_stdout(cfg.out_path[..]);
            write_stdout("\n");
            return 1;
        }
    } else {
        write_stdout(report[..]);
    }
    return gate_res.exit_code;
}
