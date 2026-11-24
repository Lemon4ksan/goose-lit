// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// runner/lit_runner.goose - Test discovery, // RUN: directive execution, and substitution.
namespace lit;

import std;
import os;
import sys.bytes;
import sys.proc;
import sys.time;
import sys.config;

struct RunDirective {
    line_no:    i64        = 0,
    command:    u8[..2048] = [],
    overflowed: bool       = false,
}

var g_keep_artifacts: bool      = false;
var g_test_mode:      u8[..32]  = [];
var g_test_exec:      u8[..256] = [];

fn configure_runner_options(keep_artifacts: bool, test_mode: const u8[:], test_exec: const u8[:]) {
    g_keep_artifacts = keep_artifacts;
    crap::set_bounded(g_test_mode, test_mode);
    crap::set_bounded(g_test_exec, test_exec);
}

enum TestStatus {
    Pass,
    Fail,
    XFail,
    XPass,
    Unsupported,
    Timeout,
}

struct TestResult {
    file_path:   u8[..512]  = [],
    status:      TestStatus = TestStatus.Pass,
    passed:      bool       = true,
    total_runs:  i64        = 0,
    failed_runs: i64        = 0,
    duration_us: i64        = 0,
    diag:        u8[>..]    = [],
}

fn host_has_single_feature(feat: const u8[:]) -> bool {
    let f = crap::trim_ascii(feat);
    guard f.len > 0 else { return false; }
    let os_id = crap::native_host_os();
    let arch_id = crap::native_host_arch();

    if f == "windows" || f == "win32" || f == "win64" {
        return os_id == 1;
    }
    if f == "linux" {
        return os_id == 2;
    }
    if f == "macos" || f == "darwin" {
        return os_id == 3;
    }
    if f == "x86_64" || f == "amd64" || f == "x64" {
        return arch_id == 1;
    }
    if f == "aarch64" || f == "arm64" {
        return arch_id == 2;
    }
    if f == "gcc" {
        var cc_val: u8[>..] = [];
        if env("GOOSE_CC", cc_val) && cc_val.len > 0 {
            return crap::slice_contains(cc_val[..], "gcc");
        }
        return crap::native_has_executable("gcc") != 0;
    }
    if f == "clang" {
        var cc_val: u8[>..] = [];
        if env("GOOSE_CC", cc_val) && cc_val.len > 0 {
            return crap::slice_contains(cc_val[..], "clang");
        }
        return crap::native_has_executable("gcc") == 0 && crap::native_has_executable("clang") != 0;
    }
    if f == "goose" {
        return crap::native_has_executable("goose") != 0;
    }
    return false;
}

fn host_has_feature(feat: const u8[:]) -> bool {
    let list = crap::trim_ascii(feat);
    guard list.len > 0 else { return false; }
    var start: i64 = 0;
    let n = list.len;
    while start <= n {
        var end = n;
        for i in start..n {
            if list[i] == ',' {
                end = i;
                break;
            }
        }
        let item = crap::trim_ascii(list[start..end]);
        start = end + 1;
        if item.len > 0 && host_has_single_feature(item) {
            return true;
        }
    }
    return false;
}

fn host_has_all_features(feat: const u8[:]) -> bool {
    let list = crap::trim_ascii(feat);
    guard list.len > 0 else { return false; }
    var start:   i64 = 0;
    var checked: i64 = 0;
    let n = list.len;
    while start <= n {
        var end = n;
        for i in start..n {
            if list[i] == ',' {
                end = i;
                break;
            }
        }
        let item = crap::trim_ascii(list[start..end]);
        start = end + 1;
        if item.len > 0 {
            checked += 1;
            if !host_has_single_feature(item) {
                return false;
            }
        }
    }
    return checked > 0;
}

// Scans a source file for `// RUN: <command>` directives.
fn parse_run_directives(source: const u8[:], directives: RunDirective[>..]&) -> bool {
    var cursor:   i64 = 0;
    var line_num: i64 = 1;
    let n = source.len;

    while cursor < n {
        var next_nl = cursor;
        while next_nl < n && source[next_nl] != '\n' {
            next_nl += 1;
        }

        let line = crap::trim_ascii(source[cursor..next_nl]);
        cursor = next_nl + 1;

        if line.len >= 2 && line[0] == '/' && line[1] == '/' {
            let body = crap::trim_ascii(line[2..]);
            if crap::slice_starts_with(body, "RUN:") {
                let cmd_part = crap::trim_ascii(body[4..]);
                if cmd_part.len > 0 {
                    var d = RunDirective {
                        line_no:    line_num,
                        command:    [],
                        overflowed: cmd_part.len > 2048,
                    };
                    let copy_len = min(cmd_part.len, d.command.cap);
                    d.command.append(cmd_part[..copy_len]);
                    directives.push(d);
                }
            }
        }

        line_num += 1;
    }

    return directives.len > 0;
}

fn build_test_scratch_path(file_path: const u8[:], out: u8[>..]&) {
    crap::ensure_lit_cache_dir();
    let os_id = crap::native_host_os();
    if is_dir(".lit/cache") {
        if os_id == 1 {
            out.append(".lit\\cache\\");
        } else {
            out.append(".lit/cache/");
        }
        for b in file_path {
            if b == '/' || b == '\\' || b == ':' {
                out.push('_');
            } else {
                out.push(b);
            }
        }
        out.append(".tmp");
    } else {
        for b in file_path {
            if os_id == 1 && b == '/' {
                out.push('\\');
            } else {
                out.push(b);
            }
        }
        out.append(".tmp");
    }
}

fn cleanup_scratch_variants(base: const u8[:]) {
    if file_exists(base) || is_dir(base) {
        crap::native_remove_tree(base);
    }
    var buf: u8[>..] = [];
    buf.append(base);
    buf.append(".exe");
    if file_exists(buf[..]) {
        delete_file(buf[..]);
    }
    buf.clear();
    buf.append(base);
    buf.append(".pdb");
    if file_exists(buf[..]) {
        delete_file(buf[..]);
    }
    buf.clear();
    buf.append(base);
    buf.append(".dSYM");
    if file_exists(buf[..]) || is_dir(buf[..]) {
        crap::native_remove_tree(buf[..]);
    }
}

// Resolves a shim asset (`alloc_hook.h`, `prof_hook.h`, `fuzz_driver.c`)
// relative to the running `goose-lit` executable directory or its parent.
fn resolve_lit_shim_path(prog: const u8[:], shim_file: const u8[:], out: u8[>..]&) {
    let os_id = crap::native_host_os();
    let sep: u8 = if os_id == 1 { '\\' } else { '/' };

    var last_sep: i64 = -1;
    var k:        i64 = prog.len - 1;
    while k >= 0 {
        if prog[k] == '\\' || prog[k] == '/' {
            last_sep = k;
            break;
        }
        k--;
    }

    if last_sep > 0 {
        // 1. Check <prog_dir>/shim/<shim_file>
        var cand: u8[>..] = [];
        cand.append(prog[..last_sep]);
        cand.push(sep);
        cand.append("shim");
        cand.push(sep);
        cand.append(shim_file);
        if file_exists(cand[..]) {
            out.append(cand[..]);
            return;
        }

        // 2. Check <prog_dir>/../shim/<shim_file> (standard bin/goose-lit layout)
        var parent_sep: i64 = -1;
        var p:          i64 = last_sep - 1;
        while p >= 0 {
            if prog[p] == '\\' || prog[p] == '/' {
                parent_sep = p;
                break;
            }
            p--;
        }
        if parent_sep > 0 {
            cand.clear();
            cand.append(prog[..parent_sep]);
            cand.push(sep);
            cand.append("shim");
            cand.push(sep);
            cand.append(shim_file);
            if file_exists(cand[..]) {
                out.append(cand[..]);
                return;
            }
        }
    }

    // 3. Fallback to workspace-local shim/<shim_file>
    out.append("shim");
    out.push(sep);
    out.append(shim_file);
}

// Expands lit substitutions in a command line:
// %s -> file_path
// %S -> directory containing file_path
// %t -> temporary scratch file path
// %alloc_hook -> path to goose-lit/shim/alloc_hook.h
// %prof_hook  -> path to goose-lit/shim/prof_hook.h
// %fuzz_driver -> path to goose-lit/shim/fuzz_driver.c
fn substitute_lit_command(
    raw_cmd:   const u8[:],
    file_path: const u8[:],
    out_cmd:   u8[>..]&,
) {
    let os_id = crap::native_host_os();
    var dir_path:    u8[>..] = [];
    var native_file: u8[>..] = [];
    for b in file_path {
        if os_id == 1 && b == '/' {
            native_file.push('\\');
        } else {
            native_file.push(b);
        }
    }

    var scratch_path: u8[>..] = [];
    build_test_scratch_path(file_path, scratch_path);

    var last_sep: i64 = -1;
    var idx:      i64 = native_file.len - 1;
    while idx >= 0 {
        if native_file[idx] == '\\' || native_file[idx] == '/' {
            last_sep = idx;
            break;
        }
        idx--;
    }

    if last_sep >= 0 {
        if last_sep == 0 {
            dir_path.push(native_file[0]);
        } else if last_sep == 2 && native_file.len >= 3 && native_file[1] == ':' {
            dir_path.append(native_file[..3]);
        } else {
            dir_path.append(native_file[..last_sep]);
        }
    } else {
        dir_path.push('.');
    }

    var prog: u8[>..] = [];
    arg(0, prog);
    if prog.len == 0 {
        prog.append("goose-lit");
    }

    var cmd_to_sub = raw_cmd;
    if crap::slice_starts_with(raw_cmd, "not ") {
        out_cmd.push('"');
        out_cmd.append(prog[..]);
        out_cmd.push('"');
        out_cmd.append(" not ");
        cmd_to_sub = raw_cmd[4..];
    }

    var i: i64 = 0;
    let n = cmd_to_sub.len;

    while i < n {
        if cmd_to_sub[i] == '%' {
            if i + 1 < n && cmd_to_sub[i + 1] == '%' {
                out_cmd.push('%');
                i += 2;
                continue;
            }
            if i + 1 < n && crap::is_ident_start(cmd_to_sub[i + 1]) {
                var j = i + 1;
                while j < n && crap::is_ident_cont(cmd_to_sub[j]) {
                    j += 1;
                }
                if j < n && cmd_to_sub[j] == '%' {
                    out_cmd.append(cmd_to_sub[i..j + 1]);
                    i = j + 1;
                    continue;
                }
                let tok = cmd_to_sub[i..j];
                if tok == "%FileCheck" || tok == "%filecheck" {
                    out_cmd.push('"');
                    out_cmd.append(prog[..]);
                    out_cmd.push('"');
                    out_cmd.append(" filecheck");
                    i = j;
                    continue;
                } else if tok == "%not" {
                    out_cmd.push('"');
                    out_cmd.append(prog[..]);
                    out_cmd.push('"');
                    out_cmd.append(" not");
                    i = j;
                    continue;
                } else if tok == "%lit" {
                    out_cmd.push('"');
                    out_cmd.append(prog[..]);
                    out_cmd.push('"');
                    i = j;
                    continue;
                } else if tok == "%s" {
                    out_cmd.append(native_file[..]);
                    i = j;
                    continue;
                } else if tok == "%S" {
                    out_cmd.append(dir_path[..]);
                    i = j;
                    continue;
                } else if tok == "%t" {
                    out_cmd.append(scratch_path[..]);
                    i = j;
                    continue;
                } else if tok == "%alloc_hook" {
                    resolve_lit_shim_path(prog[..], "alloc_hook.h", out_cmd);
                    i = j;
                    continue;
                } else if tok == "%prof_hook" {
                    resolve_lit_shim_path(prog[..], "prof_hook.h", out_cmd);
                    i = j;
                    continue;
                } else if tok == "%fuzz_driver" {
                    resolve_lit_shim_path(prog[..], "fuzz_driver.c", out_cmd);
                    i = j;
                    continue;
                } else if tok == "%cov_rt" {
                    resolve_lit_shim_path(prog[..], "cov_rt.h", out_cmd);
                    i = j;
                    continue;
                }
            }
        }
        out_cmd.push(cmd_to_sub[i]);
        i += 1;
    }
}

// Evaluates whether source content contains any FileCheck pattern directives.
// crap:trusted
// crap:trusted-bounds
fn has_filecheck_directives(src: const u8[:]) -> bool {
    guard src.len > 0 else { return false; }
    if crap::slice_contains(src, "// CHECK:") { return true; }
    if crap::slice_contains(src, "// CHECK-NEXT:") { return true; }
    if crap::slice_contains(src, "// CHECK-NOT:") { return true; }
    if crap::slice_contains(src, "// CHECK-DAG:") { return true; }
    if crap::slice_contains(src, "// CHECK-LABEL:") { return true; }
    if crap::slice_contains(src, "// CHECK-SAME:") { return true; }
    if crap::slice_contains(src, "// CHECK-EMPTY:") { return true; }
    return crap::slice_contains(src, "// CHECK-COUNT-");
}

// Evaluates whether source content declares an entry main function.
// crap:trusted
// crap:trusted-bounds
fn has_main_function(src: const u8[:]) -> bool {
    guard src.len > 0 else { return false; }
    return crap::slice_contains(src, "fn main(") || crap::slice_contains(src, "fn main (");
}

// Determines the default command string when a test file omits // RUN: directives.
// crap:trusted
// crap:trusted-bounds
fn default_run_command(file_path: const u8[:], src: const u8[:]) -> const u8[:] {
    if g_test_mode[..] == "check" {
        return "goose check %s";
    }
    if g_test_mode[..] == "build" {
        if has_filecheck_directives(src) {
            return "goose build --debug %s -o %t && %t | %FileCheck %s";
        }
        if has_main_function(src) || crap::slice_ends_with(file_path, "_test.goose") || crap::slice_ends_with(file_path, "test.goose") {
            return "goose build --debug %s -o %t && %t";
        }
        return "goose check %s";
    }
    if has_filecheck_directives(src) {
        return "goose %s | %FileCheck %s";
    }
    if has_main_function(src) || crap::slice_ends_with(file_path, "_test.goose") || crap::slice_ends_with(file_path, "test.goose") {
        return "goose %s";
    }
    return "goose check %s";
}

// Checks if a discovered file should be executed as a test.
// crap:trusted
// crap:trusted-bounds
fn is_test_candidate(path: const u8[:], name: const u8[:]) -> bool {
    guard name.len > 0 else { return false; }
    if crap::slice_ends_with(name, ".lit") { return true; }
    if name == "test.goose" { return true; }
    if crap::slice_ends_with(name, "_test.goose") { return true; }
    if crap::slice_starts_with(name, "test_") && crap::slice_ends_with(name, ".goose") { return true; }
    if crap::slice_ends_with(name, ".goose") {
        var content: u8[>..] = [];
        if read_file(path, content) {
            var dirs: RunDirective[>..] = [];
            if parse_run_directives(content[..], dirs) || has_filecheck_directives(content[..]) {
                return true;
            }
        }
    }
    return false;
}

// Executes all // RUN: directives in a single test file.
fn run_single_lit_test_with_timeout(
    file_path:           const u8[:],
    verbose:             bool,
    default_timeout_sec: i64,
    res:                 TestResult&,
) -> bool {
    res.file_path.clear();
    let copy_len = min(file_path.len, res.file_path.cap);
    res.file_path.append(file_path[..copy_len]);
    res.passed = true;
    res.total_runs = 0;
    res.failed_runs = 0;
    res.diag.clear();

    if !file_exists(file_path) {
        res.passed = false;
        res.diag.append("File not found: ");
        res.diag.append(file_path);
        res.diag.append("\n");
        return false;
    }

    var src: u8[>..] = [];
    if !read_file(file_path, src) || src.len == 0 {
        res.passed = false;
        res.diag.append("Failed to read file or file is empty: ");
        res.diag.append(file_path);
        res.diag.append("\n");
        return false;
    }

    var is_xfail = false;
    var is_unsupported = false;
    var timeout_sec = default_timeout_sec;

    var cur: i64 = 0;
    let sn = src.len;
    while cur < sn {
        var next_nl = cur;
        while next_nl < sn && src[next_nl] != '\n' { next_nl += 1; }
        let line = crap::trim_ascii(src[cur..next_nl]);
        cur = next_nl + 1;
        if line.len >= 2 && line[0] == '/' && line[1] == '/' {
            let body = crap::trim_ascii(line[2..]);
            if crap::slice_starts_with(body, "XFAIL:") {
                let targets = crap::trim_ascii(body[6..]);
                if targets == "*" || host_has_feature(targets) {
                    is_xfail = true;
                }
            } else if crap::slice_starts_with(body, "REQUIRES:") {
                let reqs = crap::trim_ascii(body[9..]);
                if reqs.len > 0 && !host_has_all_features(reqs) {
                    is_unsupported = true;
                }
            } else if crap::slice_starts_with(body, "UNSUPPORTED:") {
                let unsupp = crap::trim_ascii(body[12..]);
                if unsupp.len > 0 && host_has_feature(unsupp) {
                    is_unsupported = true;
                }
            } else if crap::slice_starts_with(body, "TIMEOUT:") {
                let t_str = crap::trim_ascii(body[8..]);
                let t_val, ok = crap::parse_i64_slice(t_str);
                if ok && t_val > 0 {
                    timeout_sec = t_val;
                }
            }
        }
    }

    if is_unsupported {
        res.status = TestStatus.Unsupported;
        res.passed = true;
        return true;
    }

    var directives: RunDirective[>..] = [];
    if !parse_run_directives(src[..], directives) {
        var def_dir = RunDirective {
            line_no: 1,
            command: [],
        };
        if g_test_exec.len > 0 {
            def_dir.command.append(g_test_exec[..]);
            if has_filecheck_directives(src[..]) && !crap::slice_contains(g_test_exec[..], "%FileCheck") {
                def_dir.command.append(" | %FileCheck %s");
            }
        } else {
            let def_cmd = default_run_command(file_path, src[..]);
            let def_len = min(def_cmd.len, def_dir.command.cap);
            def_dir.command.append(def_cmd[..def_len]);
        }
        directives.push(def_dir);
    }

    var cache_scratch: u8[>..] = [];
    build_test_scratch_path(file_path, cache_scratch);
    cleanup_scratch_variants(cache_scratch[..]);

    var local_scratch: u8[>..] = [];
    crap::normalize_slashes(file_path, local_scratch);
    local_scratch.append(".tmp");
    cleanup_scratch_variants(local_scratch[..]);

    let t0 = (monotonic_now().nanos as! i64) / 1000;
    var timed_out = false;
    let clamped_sec = min(timeout_sec, 2147483);
    let timeout_ms: i32 = if clamped_sec > 0 { (clamped_sec * 1000) as! i32 } else { 0 };
    var cmd:     u8[>..] = [];
    var run_out: u8[>..] = [];

    for d in directives {
        res.total_runs += 1;
        if d.overflowed {
            res.passed = false;
            res.failed_runs += 1;
            res.diag.append("RUN DIRECTIVE TOO LONG (> 2048 bytes) at line ");
            var l_b: u8[..32] = [];
            format(l_b, d.line_no);
            res.diag.append(l_b[..]);
            res.diag.append("\n");
            break;
        }
        cmd.clear();
        substitute_lit_command(d.command[..], file_path, cmd);

        if verbose {
            write_stdout("  [RUN line ");
            var num_b: u8[..32] = [];
            format(num_b, d.line_no);
            write_stdout(num_b[..]);
            write_stdout("] ");
            write_stdout(cmd[..]);
            write_stdout("\n");
        }

        run_out.clear();
        let rc = crap::exec_capture_timeout(cmd[..], timeout_ms, run_out);

        if rc == 124 && timeout_ms > 0 && crap::native_last_exec_timed_out() != 0 {
            timed_out = true;
            res.passed = false;
            res.failed_runs += 1;
            res.diag.append("COMMAND TIMED OUT (> ");
            var t_b: u8[..32] = [];
            format(t_b, timeout_sec);
            res.diag.append(t_b[..]);
            res.diag.append("s) at line ");
            var l_b: u8[..32] = [];
            format(l_b, d.line_no);
            res.diag.append(l_b[..]);
            res.diag.append(":\n  $ ");
            res.diag.append(cmd[..]);
            res.diag.append("\n");
            break;
        } else if rc != 0 {
            res.passed = false;
            res.failed_runs += 1;
            res.diag.append("COMMAND FAILED (exit ");
            var num_b: u8[..32] = [];
            format(num_b, rc as! i64);
            res.diag.append(num_b[..]);
            res.diag.append(") at line ");
            var l_b: u8[..32] = [];
            format(l_b, d.line_no);
            res.diag.append(l_b[..]);
            res.diag.append(":\n  $ ");
            res.diag.append(cmd[..]);
            res.diag.append("\n");
            if run_out.len > 0 {
                res.diag.append("Output:\n");
                res.diag.append(run_out[..]);
                res.diag.append("\n");
            }
            break;
        }
    }

    let t1 = (monotonic_now().nanos as! i64) / 1000;
    res.duration_us = t1 - t0;

    if !g_keep_artifacts {
        cleanup_scratch_variants(cache_scratch[..]);
        cleanup_scratch_variants(local_scratch[..]);
    }

    if timed_out {
        res.status = TestStatus.Timeout;
        res.passed = false;
        return false;
    }

    let all_passed = (res.failed_runs == 0);
    if all_passed {
        if is_xfail {
            res.status = TestStatus.XPass;
            res.passed = false;
            res.diag.append("UNEXPECTED PASS: test marked XFAIL passed unexpectedly\n");
        } else {
            res.status = TestStatus.Pass;
            res.passed = true;
        }
    } else {
        if is_xfail {
            res.status = TestStatus.XFail;
            res.passed = true;
        } else {
            res.status = TestStatus.Fail;
            res.passed = false;
        }
    }

    return res.passed;
}

// Discovers all test files under a directory tree using an iterative BFS queue.
// crap:trusted
// crap:trusted-bounds
fn discover_test_files_filtered(
    dir_path:     const u8[:],
    exclude_blob: const u8[:],
    out_paths:    u8[>..]&,
) -> i64 {
    var count: i64     = 0;
    var norm:  u8[>..] = [];
    crap::normalize_slashes(dir_path, norm);
    while norm.len > 1 && norm[norm.len - 1] == '/' {
        norm.pop();
    }

    guard is_dir(norm[..]) else {
        if file_exists(norm[..]) && !crap::is_excluded_path(norm[..], exclude_blob) {
            out_paths.append(norm[..]);
            out_paths.push('\n');
            return 1;
        }
        return 0;
    }

    var dir_queue: u8[>..] = [];
    dir_queue.append(norm[..]);
    dir_queue.push('\n');

    var entries:      u8[>..] = [];
    var child:        u8[>..] = [];
    var queue_cursor: i64     = 0;
    while queue_cursor < dir_queue.len {
        let rel_nl = crap::slice_index_of_byte(dir_queue[queue_cursor..], '\n');
        guard rel_nl >= 0 else { break; }
        let next_nl = queue_cursor + rel_nl;

        let cur_dir = dir_queue[queue_cursor..next_nl];
        queue_cursor = next_nl + 1;

        entries.clear();
        guard list_dir(cur_dir, entries) else { continue; }
        var line_start: i64 = 0;
        for j in entries.len {
            guard entries[j] == '\n' else { continue; }
            let name = crap::trim_ascii(entries[line_start..j]);
            line_start = j + 1;

            guard !crap::is_ignored_dir_entry(name) else { continue; }

            child.clear();
            child.append(cur_dir);
            if !crap::slice_ends_with(cur_dir, "/") && !crap::slice_ends_with(cur_dir, "\\") {
                child.push('/');
            }
            child.append(name);

            guard !crap::is_excluded_path(child[..], exclude_blob) else { continue; }

            if is_dir(child[..]) {
                dir_queue.append(child[..]);
                dir_queue.push('\n');
            } else if is_test_candidate(child[..], name) {
                out_paths.append(child[..]);
                out_paths.push('\n');
                count += 1;
            }
        }
    }

    return count;
}
