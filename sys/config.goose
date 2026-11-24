// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// sys/config.goose - Configuration loader for goose-lit and G-CRAP.
// Parses flat key-value .litconfig files and manages baseline discovery.
namespace crap;

import std;
import os;
import sys.bytes;

struct LitConfig {
    baseline_buf:        u8[..256]  = [],
    tests_dir_buf:       u8[..256]  = [],
    src_dir_buf:         u8[..256]  = [],
    cc_buf:              u8[..256]  = [],
    cc_source_buf:       u8[..32]   = [],
    test_mode_buf:       u8[..32]   = [],
    test_exec_buf:       u8[..256]  = [],
    exclude_buf:         u8[..1024] = [],
    format_buf:          u8[..32]   = [],
    prefix_buf:          u8[..32]   = [],
    cov_profile_buf:     u8[..256]  = [],
    profile_target_buf:  u8[..256]  = [],
    fuzz_entry_buf:      u8[..256]  = [],
    fuzz_extra_c_buf:    u8[..1024] = [],
    fuzz_extra_libs_buf: u8[..256]  = [],
    gate_ceiling:        f64        = 25.0,
    has_gate_ceiling:    bool       = false,
    delta_threshold:     f64        = 5.0,
    has_delta:           bool       = false,
    timeout_sec:         i64        = 60,
    has_timeout:         bool       = false,
    jobs:                i64        = 0,
    has_jobs:            bool       = false,
    include_tests:       bool       = false,
    has_include_tests:   bool       = false,
    bce_enabled:         bool       = true,
    has_bce:             bool       = false,
    loaded:              bool       = false,
}

fn strip_config_value(raw: const u8[:]) -> const u8[:] {
    var in_dquote = false;
    var in_squote = false;
    var end = raw.len;
    for i in raw.len {
        let b = raw[i];
        if b == '"' && !in_squote {
            in_dquote = !in_dquote;
        } else if b == '\'' && !in_dquote {
            in_squote = !in_squote;
        } else if !in_dquote && !in_squote {
            if b == '#' || b == ';' {
                end = i;
                break;
            }
            if b == '/' && i + 1 < raw.len && raw[i + 1] == '/' {
                end = i;
                break;
            }
        }
    }
    var s = trim_ascii(raw[..end]);
    if s.len >= 2 && s[0] != '[' {
        if (s[0] == '"' && s[s.len - 1] == '"') || (s[0] == '\'' && s[s.len - 1] == '\'') {
            s = s[1..s.len - 1];
        }
    }
    return s;
}

// crap:trusted
// crap:trusted-bounds
fn append_exclude_patterns(val: const u8[:], out: u8[..1024]&) {
    var v = trim_ascii(val);
    if v.len >= 2 && v[0] == '[' && v[v.len - 1] == ']' {
        v = trim_ascii(v[1..v.len - 1]);
    }
    var start: i64 = 0;
    let n = v.len;
    while start <= n {
        var end = n;
        for i in start..n {
            if v[i] == ',' {
                end = i;
                break;
            }
        }
        var tok = trim_ascii(v[start..end]);
        start = end + 1;
        if tok.len >= 2 && tok[0] == '[' && tok[tok.len - 1] == ']' {
            tok = trim_ascii(tok[1..tok.len - 1]);
        }
        let is_dquote = tok.len >= 2 && tok[0] == '"' && tok[tok.len - 1] == '"';
        let is_squote = tok.len >= 2 && tok[0] == '\'' && tok[tok.len - 1] == '\'';
        if is_dquote || is_squote {
            tok = tok[1..tok.len - 1];
        }
        while slice_starts_with(tok, "./") || slice_starts_with(tok, ".\\") {
            tok = tok[2..];
            while tok.len > 0 && (tok[0] == '/' || tok[0] == '\\') {
                tok = tok[1..];
            }
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
    var p = path;
    while slice_starts_with(p, "./") || slice_starts_with(p, ".\\") {
        p = p[2..];
        while p.len > 0 && (p[0] == '/' || p[0] == '\\') {
            p = p[1..];
        }
    }
    var norm: u8[>..] = [];
    for b in p {
        if b == '\\' { norm.push('/'); } else { norm.push(b); }
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
        set_bounded(cfg.baseline_buf, val);
        return true;
    }
    if key == "exclude" {
        append_exclude_patterns(val, cfg.exclude_buf);
        return true;
    }
    if key == "tests_dir" || key == "tests" || key == "test_dir" {
        set_bounded(cfg.tests_dir_buf, val);
        return true;
    }
    if key == "src_dir" || key == "target" || key == "src" {
        set_bounded(cfg.src_dir_buf, val);
        return true;
    }
    if key == "test_mode" {
        set_bounded(cfg.test_mode_buf, val);
        return true;
    }
    if key == "test_exec" {
        set_bounded(cfg.test_exec_buf, val);
        return true;
    }
    if key == "goose_cc" || key == "cc" {
        if set_bounded(cfg.cc_buf, val) {
            set_bounded(cfg.cc_source_buf, "config");
            native_setenv("GOOSE_CC", val);
        }
        return true;
    }
    if key == "cov_profile" {
        set_bounded(cfg.cov_profile_buf, val);
        return true;
    }
    if key == "profile_target" {
        set_bounded(cfg.profile_target_buf, val);
        return true;
    }
    if key == "fuzz_entry" {
        set_bounded(cfg.fuzz_entry_buf, val);
        return true;
    }
    if key == "fuzz_extra_c" {
        cfg.fuzz_extra_c_buf.clear();
        append_exclude_patterns(val, cfg.fuzz_extra_c_buf);
        return true;
    }
    let host_os = native_host_os();
    let is_os_libs = key == "fuzz_extra_libs" ||
        (host_os == 1 && key == "fuzz_extra_libs_windows") ||
        (host_os == 2 && key == "fuzz_extra_libs_linux") ||
        (host_os == 3 && key == "fuzz_extra_libs_macos");
    if is_os_libs {
        var tmp_libs: u8[..1024] = [];
        append_exclude_patterns(val, tmp_libs);
        let n = min(tmp_libs.len, cfg.fuzz_extra_libs_buf.cap);
        cfg.fuzz_extra_libs_buf.clear();
        if n > 0 {
            cfg.fuzz_extra_libs_buf.append(tmp_libs[..n]);
        }
        return true;
    }
    return false;
}

fn apply_format_setting(key: const u8[:], val: const u8[:], cfg: LitConfig&) -> bool {
    if key == "format" {
        set_bounded(cfg.format_buf, val);
        return true;
    }
    if key == "prefix" {
        set_bounded(cfg.prefix_buf, val);
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
    if key == "jobs" {
        let ival, ok = parse_i64_slice(val);
        if ok && ival > 0 {
            cfg.jobs = ival;
            cfg.has_jobs = true;
        }
        return true;
    }
    return false;
}

fn apply_bool_setting(key: const u8[:], val: const u8[:], cfg: LitConfig&) -> bool {
    if key == "include_tests" {
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
    if key == "bce" || key == "bce_lines" {
        if val == "true" || val == "1" {
            cfg.bce_enabled = true;
            cfg.has_bce = true;
            return true;
        }
        if val == "false" || val == "0" {
            cfg.bce_enabled = false;
            cfg.has_bce = true;
            return true;
        }
        return false;
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
    let val = strip_config_value(line[eq_idx + 1..]);
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
        return set_bounded(out, custom_path);
    }
    if file_exists(".litconfig") {
        return set_bounded(out, ".litconfig");
    }
    if file_exists("lit.conf") {
        return set_bounded(out, "lit.conf");
    }
    if file_exists("../.litconfig") {
        return set_bounded(out, "../.litconfig");
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
    if cfg.cc_buf.len == 0 {
        var cur_cc: u8[>..] = [];
        if env("GOOSE_CC", cur_cc) && cur_cc.len > 0 {
            set_bounded(cfg.cc_buf, cur_cc[..]);
            set_bounded(cfg.cc_source_buf, "env");
        } else if native_host_os() == 1 && native_has_executable("gcc") == 1 {
            set_bounded(cfg.cc_buf, "gcc");
            set_bounded(cfg.cc_source_buf, "default (PATH)");
            native_setenv("GOOSE_CC", "gcc");
        } else {
            set_bounded(cfg.cc_source_buf, "default");
        }
    }
    return cfg.loaded;
}

fn resolve_baseline_path(configured_baseline: const u8[:], out: u8[..256]&) -> bool {
    if configured_baseline.len > 0 && file_exists(configured_baseline) {
        return set_bounded(out, configured_baseline);
    }
    if file_exists(".lit/baseline") {
        return set_bounded(out, ".lit/baseline");
    }
    if file_exists(".lit-baseline") {
        return set_bounded(out, ".lit-baseline");
    }
    if file_exists("../.lit/baseline") {
        return set_bounded(out, "../.lit/baseline");
    }
    if file_exists("../.lit-baseline") {
        return set_bounded(out, "../.lit-baseline");
    }
    return false;
}

fn default_save_baseline_path(configured_baseline: const u8[:], out: u8[..256]&) {
    if configured_baseline.len > 0 && set_bounded(out, configured_baseline) {
        return;
    }
    if is_dir(".lit") || make_dir(".lit") {
        set_bounded(out, ".lit/baseline");
    } else {
        set_bounded(out, ".lit-baseline");
    }
}
