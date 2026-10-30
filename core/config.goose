// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// core/config.goose - Configuration loader for goose-lit and G-CRAP.
// Parses flat key-value .litconfig files and manages baseline discovery.
namespace crap;

import std;
import os;
import core.bytes;

struct LitConfig {
    baseline_buf:      u8[..256] = [],
    tests_dir_buf:     u8[..256] = [],
    src_dir_buf:       u8[..256] = [],
    format_buf:        u8[..32]  = [],
    prefix_buf:        u8[..32]  = [],
    gate_ceiling:      f64       = 25.0,
    has_gate_ceiling:  bool      = false,
    default_cov:       f64       = 0.0,
    has_default_cov:   bool      = false,
    delta_threshold:   f64       = 5.0,
    has_delta:         bool      = false,
    include_tests:     bool      = false,
    has_include_tests: bool      = false,
    loaded:            bool      = false,
}

fn apply_path_setting(key: const u8[:], val: const u8[:], cfg: LitConfig&) -> bool {
    if key == "baseline" {
        cfg.baseline_buf.clear();
        cfg.baseline_buf.append(val);
        return true;
    }
    if key == "tests_dir" || key == "tests" || key == "test_dir" {
        cfg.tests_dir_buf.clear();
        cfg.tests_dir_buf.append(val);
        return true;
    }
    if key == "src_dir" || key == "target" || key == "src" {
        cfg.src_dir_buf.clear();
        cfg.src_dir_buf.append(val);
        return true;
    }
    return false;
}

fn apply_format_setting(key: const u8[:], val: const u8[:], cfg: LitConfig&) -> bool {
    if key == "format" {
        cfg.format_buf.clear();
        cfg.format_buf.append(val);
        return true;
    }
    if key == "prefix" {
        cfg.prefix_buf.clear();
        cfg.prefix_buf.append(val);
        return true;
    }
    return false;
}

fn apply_numeric_setting(key: const u8[:], val: const u8[:], cfg: LitConfig&) -> bool {
    if key == "ceiling" || key == "gate_ceiling" || key == "max_gcrap" {
        let fval, ok = parse_f64_slice(val);
        if ok {
            cfg.gate_ceiling = fval;
            cfg.has_gate_ceiling = true;
        }
        return true;
    }
    if key == "cov" || key == "coverage" || key == "default_cov" {
        let fval, ok = parse_f64_slice(val);
        if ok {
            cfg.default_cov = fval;
            cfg.has_default_cov = true;
        }
        return true;
    }
    if key == "delta" {
        let fval, ok = parse_f64_slice(val);
        if ok {
            cfg.delta_threshold = fval;
            cfg.has_delta = true;
        }
        return true;
    }
    return false;
}

fn apply_bool_setting(key: const u8[:], val: const u8[:], cfg: LitConfig&) -> bool {
    guard key == "include_tests" else { return false; }
    if val == "true" || val == "1" {
        cfg.include_tests = true;
        cfg.has_include_tests = true;
        return true;
    }
    if val == "false" || val == "0" {
        cfg.include_tests = false;
        cfg.has_include_tests = true;
        return true;
    }
    return false;
}

inline fn is_comment_or_empty(line: const u8[:]) -> bool {
    guard line.len > 0 else { return true; }
    if line[0] == '#' || line[0] == ';' { return true; }
    if line.len >= 2 && line[0] == '/' && line[1] == '/' { return true; }
    return false;
}

// crap:trusted
// crap:trusted-bounds
fn parse_config_line(line: const u8[:], cfg: LitConfig&) {
    guard !is_comment_or_empty(line) else { return; }

    let eq_idx = slice_index_of_byte(line, '=');
    guard eq_idx > 0 && eq_idx + 1 <= line.len else { return; }

    let key = trim_ascii(line[..eq_idx]);
    let val = trim_ascii(line[eq_idx + 1..]);
    guard key.len > 0 && val.len > 0 else { return; }

    if apply_path_setting(key, val, cfg) { return; }
    if apply_numeric_setting(key, val, cfg) { return; }
    if apply_format_setting(key, val, cfg) { return; }
    apply_bool_setting(key, val, cfg);
}

// crap:trusted
// crap:trusted-bounds
inline fn scan_next_line(content: const u8[:], pos: i64&) -> const u8[:] {
    let start = pos;
    let n = content.len;
    while pos < n && content[pos] != '\n' {
        pos += 1;
    }
    let line = trim_ascii(content[start..pos]);
    if pos < n && content[pos] == '\n' {
        pos += 1;
    }
    return line;
}

// crap:trusted
fn parse_config_content(content: const u8[:], cfg: LitConfig&) {
    var pos: i64 = 0;
    while pos < content.len {
        let line = scan_next_line(content, pos);
        if line.len > 0 {
            parse_config_line(line, cfg);
        }
    }
}

fn find_config_file(custom_path: const u8[:], out: u8[..256]&) -> bool {
    out.clear();
    if custom_path.len > 0 && file_exists(custom_path) {
        out.append(custom_path);
        return true;
    }
    if file_exists(".litconfig") {
        out.append(".litconfig");
        return true;
    }
    if file_exists("lit.conf") {
        out.append("lit.conf");
        return true;
    }
    if file_exists("../.litconfig") {
        out.append("../.litconfig");
        return true;
    }
    return false;
}

// crap:trusted
fn load_lit_config(custom_path: const u8[:], cfg: LitConfig&) -> bool {
    var path_buf: u8[..256] = [];
    guard find_config_file(custom_path, path_buf) else { return false; }

    var content: u8[>..] = [];
    guard read_file(path_buf[..], content) else { return false; }

    parse_config_content(content[..], cfg);
    cfg.loaded = true;
    return true;
}

fn resolve_baseline_path(configured_baseline: const u8[:], out: u8[..256]&) -> bool {
    out.clear();
    if configured_baseline.len > 0 && file_exists(configured_baseline) {
        out.append(configured_baseline);
        return true;
    }
    if file_exists(".lit/baseline") {
        out.append(".lit/baseline");
        return true;
    }
    if file_exists(".lit-baseline") {
        out.append(".lit-baseline");
        return true;
    }
    if file_exists("../.lit/baseline") {
        out.append("../.lit/baseline");
        return true;
    }
    if file_exists("../.lit-baseline") {
        out.append("../.lit-baseline");
        return true;
    }
    return false;
}

fn default_save_baseline_path(configured_baseline: const u8[:], out: u8[..256]&) {
    out.clear();
    if configured_baseline.len > 0 {
        out.append(configured_baseline);
    } else if is_dir(".lit") || make_dir(".lit") {
        out.append(".lit/baseline");
    } else {
        out.append(".lit-baseline");
    }
}
