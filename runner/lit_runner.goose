// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// runner/lit_runner.goose - Test discovery, // RUN: directive execution, and substitution.
namespace lit;

import std;
import os;
import core.bytes;
import core.proc;
import core.time;

struct RunDirective {
    line_no: i64       = 0,
    command: u8[..512] = [],
}

enum TestStatus {
    Pass,
    Fail,
    XFail,
    XPass,
    Unsupported,
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

fn host_has_feature(feat: const u8[:]) -> bool {
    let f = crap::trim_ascii(feat);
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
    if f == "gcc" || f == "clang" || f == "goose" {
        return true;
    }
    return false;
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
                        line_no: line_num,
                        command: [],
                    };
                    for b in cmd_part {
                        if d.command.len < d.command.cap {
                            d.command.push(b);
                        }
                    }
                    directives.push(d);
                }
            }
        }

        line_num += 1;
    }

    return directives.len > 0;
}

// Expands lit substitutions in a command line:
// %s -> file_path
// %S -> directory containing file_path
// %t -> temporary scratch file path
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
            let rem = cmd_to_sub[i..];
            if crap::slice_starts_with(rem, "%FileCheck") || crap::slice_starts_with(rem, "%filecheck") {
                out_cmd.push('"');
                out_cmd.append(prog[..]);
                out_cmd.push('"');
                out_cmd.append(" filecheck");
                i += 10;
                continue;
            } else if crap::slice_starts_with(rem, "%not") {
                out_cmd.push('"');
                out_cmd.append(prog[..]);
                out_cmd.push('"');
                out_cmd.append(" not ");
                i += 4;
                continue;
            } else if crap::slice_starts_with(rem, "%lit") {
                out_cmd.push('"');
                out_cmd.append(prog[..]);
                out_cmd.push('"');
                i += 4;
                continue;
            } else if i + 1 < n {
                let spec = cmd_to_sub[i + 1];
                if spec == 's' {
                    out_cmd.append(native_file[..]);
                    i += 2;
                    continue;
                } else if spec == 'S' {
                    out_cmd.append(dir_path[..]);
                    i += 2;
                    continue;
                } else if spec == 't' {
                    out_cmd.append(native_file[..]);
                    out_cmd.append(".tmp");
                    i += 2;
                    continue;
                }
            }
        }
        out_cmd.push(cmd_to_sub[i]);
        i += 1;
    }
}

// Executes all // RUN: directives in a single test file.
fn run_single_lit_test(
    file_path: const u8[:],
    verbose:   bool,
    res:       TestResult&,
) -> bool {
    res.file_path.clear();
    for b in file_path {
        if res.file_path.len < res.file_path.cap {
            res.file_path.push(b);
        }
    }
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
                if reqs.len > 0 && !host_has_feature(reqs) {
                    is_unsupported = true;
                }
            } else if crap::slice_starts_with(body, "UNSUPPORTED:") {
                let unsupp = crap::trim_ascii(body[12..]);
                if unsupp.len > 0 && host_has_feature(unsupp) {
                    is_unsupported = true;
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
        // Fallback default: if no // RUN: directive, perform goose check
        var def_dir = RunDirective {
            line_no: 1,
            command: [],
        };
        let def_cmd = "goose check %s";
        for b in def_cmd {
            if def_dir.command.len < def_dir.command.cap {
                def_dir.command.push(b);
            }
        }
        directives.push(def_dir);
    }

    var tmp_scratch: u8[>..] = [];
    crap::normalize_slashes(file_path, tmp_scratch);
    tmp_scratch.append(".tmp");
    if file_exists(tmp_scratch[..]) {
        delete_file(tmp_scratch[..]);
    }
    var tmp_exe: u8[>..] = [];
    tmp_exe.append(tmp_scratch[..]);
    tmp_exe.append(".exe");
    if file_exists(tmp_exe[..]) {
        delete_file(tmp_exe[..]);
    }

    let t0 = (monotonic_now().nanos as! i64) / 1000;

    for d in directives {
        res.total_runs += 1;
        var cmd: u8[>..] = [];
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

        var run_out: u8[>..] = [];
        let rc = crap::exec_capture(cmd[..], run_out);

        if rc != 0 {
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
        }
    }

    let t1 = (monotonic_now().nanos as! i64) / 1000;
    res.duration_us = t1 - t0;

    if file_exists(tmp_scratch[..]) {
        delete_file(tmp_scratch[..]);
    }
    if file_exists(tmp_exe[..]) {
        delete_file(tmp_exe[..]);
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
fn discover_test_files(dir_path: const u8[:], out_paths: u8[>..]&) -> i64 {
    var count: i64     = 0;
    var norm:  u8[>..] = [];
    crap::normalize_slashes(dir_path, norm);
    while norm.len > 1 && norm[norm.len - 1] == '/' {
        norm.pop();
    }

    guard is_dir(norm[..]) else {
        if file_exists(norm[..]) {
            out_paths.append(norm[..]);
            out_paths.push('\n');
            return 1;
        }
        return 0;
    }

    var dir_queue: u8[>..] = [];
    dir_queue.append(norm[..]);
    dir_queue.push('\n');

    var queue_cursor: i64 = 0;
    while queue_cursor < dir_queue.len {
        var next_nl: i64 = -1;
        for i in queue_cursor..dir_queue.len {
            if dir_queue[i] == '\n' {
                next_nl = i;
                break;
            }
        }
        guard next_nl >= 0 else { break; }

        let cur_dir = dir_queue[queue_cursor..next_nl];
        queue_cursor = next_nl + 1;

        var entries: u8[>..] = [];
        if list_dir(cur_dir, entries) {
            var line_start: i64 = 0;
            for j in entries.len {
                if entries[j] == '\n' {
                    let name = crap::trim_ascii(entries[line_start..j]);
                    line_start = j + 1;

                    guard name.len > 0 && name[0] != '.' &&
                          name != "vendor" && name != "scratch" && name != "bin" &&
                          name != "build" && name != "target" && name != "node_modules" else { continue; }

                    var child: u8[>..] = [];
                    child.append(cur_dir);
                    if !crap::slice_ends_with(cur_dir, "/") && !crap::slice_ends_with(cur_dir, "\\") {
                        child.push('/');
                    }
                    child.append(name);

                    if is_dir(child[..]) {
                        dir_queue.append(child[..]);
                        dir_queue.push('\n');
                    } else if crap::slice_ends_with(name, ".goose") || crap::slice_ends_with(name, ".lit") {
                        out_paths.append(child[..]);
                        out_paths.push('\n');
                        count += 1;
                    }
                }
            }
        }
    }

    return count;
}
