// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// profile/cli.goose - Stage profiler & testing.B benchmark runner and benchstat comparator.
namespace lit;

import std;
import os;
import sys.bytes;
import sys.proc;
import sys.config;
import runner.lit_runner;

struct ProfileCliArgs {
    target:    const u8[:] = "",
    cc:        const u8[:] = "",
    filter:    const u8[:] = "",
    benchtime: const u8[:] = "",
    save_path: const u8[:] = "",
    comp_path: const u8[:] = "",
    json_path: const u8[:] = "",
    md_path:   const u8[:] = "",
}

struct ProfileRow {
    kind:       u8       = 0, // 1 = bench, 2 = stage
    case_name:  u8[..64] = [],
    stage_name: u8[..64] = [],
    cycles_x10: i64      = 0, // cycles * 10 for deterministic integer delta math
    scratch_b:  i64      = 0,
}

fn parse_decimal_x10(s: const u8[:]) -> i64 {
    let trimmed = crap::trim_ascii(s);
    guard trimmed.len > 0 else { return 0; }
    var neg = false;
    var i: i64 = 0;
    if trimmed[0] == '-' {
        neg = true;
        i = 1;
    }
    var int_part:   i64 = 0;
    var frac_digit: i64 = 0;
    var seen_dot = false;
    while i < trimmed.len {
        let c = trimmed[i];
        if c == '.' && !seen_dot {
            seen_dot = true;
            if i + 1 < trimmed.len && crap::is_ascii_digit(trimmed[i + 1]) {
                frac_digit = trimmed[i + 1] - '0';
            }
            break;
        }
        if crap::is_ascii_digit(c) {
            int_part = int_part * 10 + (c - '0');
        }
        i++;
    }
    let val = int_part * 10 + frac_digit;
    return if neg { 0 - val } else { val };
}

fn extract_tsv_col(line: const u8[:], col_idx: i64) -> const u8[:] {
    var cur_col: i64 = 0;
    var start:   i64 = 0;
    for i in line.len {
        if line[i] == '\t' {
            if cur_col == col_idx {
                return line[start..i];
            }
            cur_col += 1;
            start = i + 1;
        }
    }
    if cur_col == col_idx {
        return line[start..];
    }
    return "";
}

fn is_machine_tsv_line(line: const u8[:]) -> bool {
    return crap::slice_starts_with(line, "@LIT_BENCH\t") ||
        crap::slice_starts_with(line, "@LIT_STAGE\t");
}

fn parse_tsv_rows(raw: const u8[:], rows: ProfileRow[>..]&) {
    var start: i64 = 0;
    for i in raw.len {
        let is_end = i + 1 == raw.len;
        guard raw[i] == '\n' || is_end else { continue; }
        let end = if raw[i] == '\n' { i } else { raw.len };
        let line = crap::trim_ascii(raw[start..end]);
        start = i + 1;

        if crap::slice_starts_with(line, "@LIT_BENCH\t") {
            var r = ProfileRow { kind: 1, .. };
            let _ = crap::set_bounded(r.case_name, extract_tsv_col(line, 2));
            r.cycles_x10 = parse_decimal_x10(extract_tsv_col(line, 5));
            let sb, _ = crap::parse_i64_slice(extract_tsv_col(line, 8));
            r.scratch_b = sb;
            rows.push(r);
        } else if crap::slice_starts_with(line, "@LIT_STAGE\t") {
            var r = ProfileRow { kind: 2, .. };
            let _ = crap::set_bounded(r.case_name, extract_tsv_col(line, 1));
            let _ = crap::set_bounded(r.stage_name, extract_tsv_col(line, 2));
            r.cycles_x10 = parse_decimal_x10(extract_tsv_col(line, 4));
            let sb, _ = crap::parse_i64_slice(extract_tsv_col(line, 10));
            r.scratch_b = sb;
            rows.push(r);
        }
    }
}

fn print_human_and_collect_tsv(raw: const u8[:], tsv_out: u8[>..]&) {
    var start: i64 = 0;
    for i in raw.len {
        let is_end = i + 1 == raw.len;
        guard raw[i] == '\n' || is_end else { continue; }
        let end = if raw[i] == '\n' { i } else { raw.len };
        let line = crap::trim_ascii(raw[start..end]);
        start = i + 1;

        if is_machine_tsv_line(line) {
            tsv_out.append(line);
            tsv_out.push('\n');
        } else {
            write_stdout(line);
            write_stdout("\n");
        }
    }
}

fn print_benchstat_delta(base_raw: const u8[:], cur_raw: const u8[:]) {
    var base_rows: ProfileRow[>..] = [];
    var cur_rows:  ProfileRow[>..] = [];
    parse_tsv_rows(base_raw, base_rows);
    parse_tsv_rows(cur_raw, cur_rows);

    write_stdout("\n======================================================================================\n");
    write_stdout("  goose-lit Benchstat Delta (Baseline vs Current)\n");
    write_stdout("======================================================================================\n");

    var line_buf: u8[>..] = [];
    for &cur in cur_rows {
        for &base in base_rows {
            if base.kind != cur.kind || base.case_name[..] != cur.case_name[..] || base.stage_name[..] != cur.stage_name[..] {
                continue;
            }
            line_buf.clear();
            if cur.kind == 1 {
                line_buf.append("  ");
                line_buf.append(cur.case_name[..]);
            } else {
                line_buf.append("    -> ");
                line_buf.append(cur.stage_name[..]);
            }
            let diff_x10 = cur.cycles_x10 - base.cycles_x10;
            let pct_x10 = if base.cycles_x10 > 0 { (diff_x10 * 1000) / base.cycles_x10 } else { 0 };
            let scr_delta = cur.scratch_b - base.scratch_b;

            let b_mag = if base.cycles_x10 < 0 { 0 - base.cycles_x10 } else { base.cycles_x10 };
            let c_mag = if cur.cycles_x10 < 0 { 0 - cur.cycles_x10 } else { cur.cycles_x10 };
            let p_mag = if pct_x10 < 0 { 0 - pct_x10 } else { pct_x10 };

            line_buf.append(" | base=");
            format(line_buf, b_mag / 10, ".", b_mag % 10);
            line_buf.append(" cyc | cur=");
            format(line_buf, c_mag / 10, ".", c_mag % 10);
            line_buf.append(" cyc | delta=");
            line_buf.push(if pct_x10 < 0 { '-' } else { '+' });
            format(line_buf, p_mag / 10, ".", p_mag % 10, "% | scratch=");
            if scr_delta >= 0 { line_buf.push('+'); }
            format(line_buf, scr_delta, " B\n");
            write_stdout(line_buf[..]);
            break;
        }
    }
    write_stdout("======================================================================================\n");
}

fn parse_profile_cli_args(all_args: const (u8[:])[:], cfg: ProfileCliArgs&) -> bool {
    var idx: i64 = 2;
    while idx < all_args.len {
        let a = all_args[idx];
        if a == "--filter" && idx + 1 < all_args.len {
            idx++;
            cfg.filter = all_args[idx];
        } else if a == "--benchtime" && idx + 1 < all_args.len {
            idx++;
            cfg.benchtime = all_args[idx];
        } else if a == "--cc" && idx + 1 < all_args.len {
            idx++;
            cfg.cc = all_args[idx];
        } else if (a == "--save" || a == "--tsv") && idx + 1 < all_args.len {
            idx++;
            cfg.save_path = all_args[idx];
        } else if a == "--json" && idx + 1 < all_args.len {
            idx++;
            cfg.json_path = all_args[idx];
        } else if a == "--md" && idx + 1 < all_args.len {
            idx++;
            cfg.md_path = all_args[idx];
        } else if a == "--compare" && idx + 1 < all_args.len {
            idx++;
            cfg.comp_path = all_args[idx];
        } else if a == "--config" && idx + 1 < all_args.len {
            idx++;
        } else if crap::slice_starts_with(a, "-") {
            write_stdout("Error: unknown option for profile: ");
            write_stdout(a);
            write_stdout("\n");
            return false;
        } else if cfg.target.len == 0 {
            cfg.target = a;
        } else {
            write_stdout("Error: unexpected positional argument for profile: ");
            write_stdout(a);
            write_stdout("\n");
            return false;
        }
        idx++;
    }
    return true;
}

fn export_profile_json(tsv_raw: const u8[:], json_path: const u8[:]) -> bool {
    var out: u8[>..] = [];
    out.append("{\n  \"cases\": [\n");
    var first_case = true;
    var rem = tsv_raw;
    while rem.len > 0 {
        let line, rest = crap::take_next_line(rem);
        rem = rest;
        if crap::slice_starts_with(line, "@LIT_BENCH\t") {
            if !first_case { out.append(",\n"); }
            first_case = false;
            out.append("    {\"suite\": \"");
            crap::append_json_escaped(out, extract_tsv_col(line, 1));
            out.append("\", \"case\": \"");
            crap::append_json_escaped(out, extract_tsv_col(line, 2));
            out.append("\", \"n\": ");
            out.append(extract_tsv_col(line, 3));
            out.append(", \"ns_per_op\": ");
            out.append(extract_tsv_col(line, 4));
            out.append(", \"cycles_per_op\": ");
            out.append(extract_tsv_col(line, 5));
            out.append(", \"mb_per_s\": ");
            out.append(extract_tsv_col(line, 6));
            out.append(", \"net_bytes_per_op\": ");
            out.append(extract_tsv_col(line, 7));
            out.append(", \"scratch_bytes_per_op\": ");
            out.append(extract_tsv_col(line, 8));
            out.append(", \"peak_bytes\": ");
            out.append(extract_tsv_col(line, 9));
            out.append(", \"pool_allocs_per_op\": ");
            out.append(extract_tsv_col(line, 10));
            out.push('}');
        }
    }
    out.append("\n  ]\n}\n");
    return write_file(json_path, out[..]);
}

fn export_profile_markdown(tsv_raw: const u8[:], md_path: const u8[:]) -> bool {
    var out: u8[>..] = [];
    out.append("# goose-lit Stage Profile Report\n\n");
    out.append("## Benchmark Overview\n\n");
    out.append("| Case | Iters (`N`) | `ns/op` | `cycles/op` | `MB/s` | `net B/op` | `scratch B/op` | `peak B` | `allocs/op` |\n");
    out.append("| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n");
    var rem = tsv_raw;
    while rem.len > 0 {
        let line, rest = crap::take_next_line(rem);
        rem = rest;
        if crap::slice_starts_with(line, "@LIT_BENCH\t") {
            out.append("| `");
            out.append(extract_tsv_col(line, 2));
            out.append("` | ");
            out.append(extract_tsv_col(line, 3));
            out.append(" | ");
            out.append(extract_tsv_col(line, 4));
            out.append(" | ");
            out.append(extract_tsv_col(line, 5));
            out.append(" | ");
            out.append(extract_tsv_col(line, 6));
            out.append(" | ");
            out.append(extract_tsv_col(line, 7));
            out.append(" | ");
            out.append(extract_tsv_col(line, 8));
            out.append(" | ");
            out.append(extract_tsv_col(line, 9));
            out.append(" | ");
            out.append(extract_tsv_col(line, 10));
            out.append(" |\n");
        }
    }
    return write_file(md_path, out[..]);
}

fn handle_profile_cli(all_args: const (u8[:])[:], lit_cfg: const crap::LitConfig&) -> i32 {
    var cfg = ProfileCliArgs { .. };
    if lit_cfg.cc_buf.len > 0 {
        cfg.cc = lit_cfg.cc_buf[..];
    }
    guard parse_profile_cli_args(all_args, cfg) else { return 2; }
    if cfg.target.len == 0 && lit_cfg.profile_target_buf.len > 0 {
        cfg.target = lit_cfg.profile_target_buf[..];
    }
    if cfg.target.len == 0 {
        write_stdout("Usage: goose-lit profile [bench.goose] [--filter <pat>] [--benchtime <ms>] [--cc <cc>] [--save <file>] [--json <file>] [--md <file>] [--compare <file>]\n");
        return 2;
    }
    guard file_exists(cfg.target) else {
        write_stdout("Error: benchmark file not found: ");
        write_stdout(cfg.target);
        write_stdout("\n");
        return 1;
    }

    crap::ensure_lit_cache_dir();
    var exe_out: u8[>..] = [];
    exe_out.append(".lit/cache/lit_profile_bench_");
    format(exe_out, clock_ns() as u64, "_", crap::native_next_seq());
    if crap::native_host_os() == 1 {
        exe_out.append(".exe");
    }
    defer if file_exists(exe_out[..]) { delete_file(exe_out[..]); };

    var prog: u8[>..] = [];
    arg(0, prog);
    var hook_h: u8[>..] = [];
    resolve_lit_shim_path(prog[..], "prof_hook.h", hook_h);

    var b_cmd: u8[>..] = [];
    b_cmd.append("goose build -O2");
    if cfg.cc.len > 0 {
        var resolved_cc: u8[>..] = [];
        let has_sep = crap::slice_index_of_byte(cfg.cc, '/') >= 0 || crap::slice_index_of_byte(cfg.cc, '\\') >= 0;
        let cc_arg = if has_sep && crap::resolve_abs_path(cfg.cc, resolved_cc) {
            resolved_cc[..]
        } else {
            cfg.cc
        };
        b_cmd.append(" --cc ");
        append_quoted(b_cmd, cc_arg);
    }
    b_cmd.append(" --include ");
    append_quoted(b_cmd, hook_h[..]);
    b_cmd.append(" -o ");
    append_quoted(b_cmd, exe_out[..]);
    b_cmd.push(' ');
    append_quoted(b_cmd, cfg.target);

    var out: u8[>..] = [];
    if crap::exec_capture(b_cmd[..], out) != 0 {
        write_stdout("Error: benchmark build failed:\n");
        write_stdout(out[..]);
        return 1;
    }

    if cfg.filter.len > 0 {
        let _ = crap::native_setenv("LIT_BENCH_FILTER", cfg.filter);
    }
    if cfg.benchtime.len > 0 {
        let _ = crap::native_setenv("LIT_BENCH_TARGET_MS", cfg.benchtime);
    }

    out.clear();
    var r_cmd: u8[>..] = [];
    append_quoted(r_cmd, exe_out[..]);
    let rc = crap::exec_capture(r_cmd[..], out);
    if rc != 0 {
        write_stdout(out[..]);
        return rc;
    }

    var tsv_data: u8[>..] = [];
    print_human_and_collect_tsv(out[..], tsv_data);

    if cfg.save_path.len > 0 {
        if !write_file(cfg.save_path, tsv_data[..]) {
            write_stdout("Error: failed to save profile report to ");
            write_stdout(cfg.save_path);
            write_stdout("\n");
            return 1;
        }
    }
    if cfg.json_path.len > 0 {
        if !export_profile_json(tsv_data[..], cfg.json_path) {
            write_stdout("Error: failed to save JSON profile report to ");
            write_stdout(cfg.json_path);
            write_stdout("\n");
            return 1;
        }
    }
    if cfg.md_path.len > 0 {
        if !export_profile_markdown(tsv_data[..], cfg.md_path) {
            write_stdout("Error: failed to save Markdown profile report to ");
            write_stdout(cfg.md_path);
            write_stdout("\n");
            return 1;
        }
    }

    if cfg.comp_path.len > 0 {
        var base_raw: u8[>..] = [];
        guard read_file(cfg.comp_path, base_raw) else {
            write_stdout("Error: failed to read baseline file ");
            write_stdout(cfg.comp_path);
            write_stdout("\n");
            return 1;
        }
        print_benchstat_delta(base_raw[..], tsv_data[..]);
    }
    return 0;
}
