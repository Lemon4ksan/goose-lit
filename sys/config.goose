// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// sys/config.goose - Configuration loader for goose-lit and G-CRAP.
// Parses flat key-value .litconfig files and manages baseline discovery.
namespace crap;

import std;
import os;
import sys.bytes;

struct LitConfig {
    baseline_buf:      u8[..256]  = [],
    tests_dir_buf:     u8[..256]  = [],
    src_dir_buf:       u8[..256]  = [],
    cc_buf:            u8[..256]  = [],
    exclude_buf:       u8[..1024] = [],
    format_buf:        u8[..32]   = [],
    prefix_buf:        u8[..32]   = [],
    gate_ceiling:      f64        = 25.0,
    has_gate_ceiling:  bool       = false,
    default_cov:       f64        = 0.0,
    has_default_cov:   bool       = false,
    delta_threshold:   f64        = 5.0,
    has_delta:         bool       = false,
    timeout_sec:       i64        = 60,
    has_timeout:       bool       = false,
    include_tests:     bool       = false,
    has_include_tests: bool       = false,
    loaded:            bool       = false,
}

// crap:trusted
// crap:trusted-bounds
fn append_exclude_patterns(val: const u8[:], out: u8[..1024]&) {
    var start: i64 = 0;
    let n = val.len;
    while start <= n {
        var end = n;
        for i in start..n {
            if val[i] == ',' {
                end = i;
                break;
            }
        }
        var tok = trim_ascii(val[start..end]);
        start = end + 1;
        if tok.len >= 2 && tok[0] == '[' && tok[tok.len - 1] == ']' {
            tok = trim_ascii(tok[1..tok.len - 1]);
        }
        let is_dquote = tok.len >= 2 && tok[0] == '"' && tok[tok.len - 1] == '"';
        let is_squote = tok.len >= 2 && tok[0] == '\'' && tok[tok.len - 1] == '\'';
        if is_dquote || is_squote {
            tok = tok[1..tok.len - 1];
        }
        if slice_starts_with(tok, "./") || slice_starts_with(tok, ".\\") {
            tok = tok[2..];
        }
        guard tok.len > 0 && out.len + tok.len + 1 <= out.cap else { continue; }
        for b in tok {
            if b == '\\' { out.push('/'); } else { out.push(b); }
        }
        out.push('\n');
    }
}

// crap:trusted
// crap:trusted-bounds
fn is_excluded_path(path: const u8[:], exclude_blob: const u8[:]) -> bool {
    guard exclude_blob.len > 0 && path.len > 0 else { return false; }
    var norm: u8[..512] = [];
    var p = path;
    if slice_starts_with(p, "./") || slice_starts_with(p, ".\\") {
        p = p[2..];
    }
    for b in p {
        if norm.len < norm.cap {
            if b == '\\' { norm.push('/'); } else { norm.push(b); }
        }
    }
    let rel = norm[..];
    var start: i64 = 0;
    let n = exclude_blob.len;
    while start < n {
        var end = n;
        for i in start..n {
            if exclude_blob[i] == '\n' {
                end = i;
                break;
            }
        }
        let pat = trim_ascii(exclude_blob[start..end]);
        start = end + 1;
        if pat.len > 0 {
            if rel == pat { return true; }
            if slice_ends_with(pat, "/") {
                if slice_starts_with(rel, pat) || (rel.len + 1 == pat.len && slice_starts_with(pat, rel)) {
                    return true;
                }
            } else if rel.len > pat.len && slice_starts_with(rel, pat) && rel[pat.len] == '/' {
                return true;
            }
        }
    }
    return false;
}

fn apply_path_setting(key: const u8[:], val: const u8[:], cfg: LitConfig&) -> bool {
    if key == "baseline" {
        cfg.baseline_buf.clear();
        cfg.baseline_buf.append(val);
        return true;
    }
    if key == "exclude" {
        append_exclude_patterns(val, cfg.exclude_buf);
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
    if key == "goose_cc" || key == "cc" {
        cfg.cc_buf.clear();
        cfg.cc_buf.append(val);
        native_setenv("GOOSE_CC", val);
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
    if key == "timeout" || key == "timeout_sec" {
        let ival, ok = parse_i64_slice(val);
        if ok && ival > 0 {
            cfg.timeout_sec = ival;
            cfg.has_timeout = true;
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
    if custom_path.len > 0 && file_exists(custom_path) {
        out.clear();
        out.append(custom_path);
        return true;
    }
    if file_exists(".litconfig") {
        out.clear();
        out.append(".litconfig");
        return true;
    }
    if file_exists("lit.conf") {
        out.clear();
        out.append("lit.conf");
        return true;
    }
    if file_exists("../.litconfig") {
        out.clear();
        out.append("../.litconfig");
        return true;
    }
    return false;
}

// crap:trusted
fn load_lit_config(custom_path: const u8[:], cfg: LitConfig&) -> bool {
    var path_buf: u8[..256] = [];
    let found = find_config_file(custom_path, path_buf);
    if found {
        var content: u8[>..] = [];
        if read_file(path_buf[..], content) {
            parse_config_content(content[..], cfg);
            cfg.loaded = true;
        }
    }
    if native_host_os() == 1 && cfg.cc_buf.len == 0 {
        var cur_cc: u8[>..] = [];
        if !env("GOOSE_CC", cur_cc) || cur_cc.len == 0 {
            if file_exists("tools/gcc_noavx.cmd") {
                native_setenv("GOOSE_CC", "tools/gcc_noavx.cmd");
            } else if file_exists("tools/gcc_stack.bat") {
                native_setenv("GOOSE_CC", "tools/gcc_stack.bat");
            }
        }
    }
    return cfg.loaded;
}

fn resolve_baseline_path(configured_baseline: const u8[:], out: u8[..256]&) -> bool {
    if configured_baseline.len > 0 && file_exists(configured_baseline) {
        out.clear();
        out.append(configured_baseline);
        return true;
    }
    if file_exists(".lit/baseline") {
        out.clear();
        out.append(".lit/baseline");
        return true;
    }
    if file_exists(".lit-baseline") {
        out.clear();
        out.append(".lit-baseline");
        return true;
    }
    if file_exists("../.lit/baseline") {
        out.clear();
        out.append("../.lit/baseline");
        return true;
    }
    if file_exists("../.lit-baseline") {
        out.clear();
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
