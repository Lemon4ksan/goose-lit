// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Process execution and filesystem traversal bindings for goose-crap.
namespace crap;

import std;
import os;
import sys.bytes;
import sys.config;

extern fn native_exec_to_file(cmd: const u8[:], out_path: const u8[:]) -> i32 = "crap_exec_to_file";
extern fn native_exec_to_file_timeout(
    cmd:        const u8[:],
    out_path:   const u8[:],
    timeout_ms: i32,
) -> i32 = "crap_exec_to_file_timeout";
extern fn native_exec_argv_to_file(
    prog:       const u8[:],
    arg1:       const u8[:],
    arg2:       const u8[:],
    arg3:       const u8[:],
    out_path:   const u8[:],
    timeout_ms: i32,
) -> i32 = "crap_exec_argv_to_file";
extern fn native_last_exec_timed_out() -> i32 = "crap_last_exec_timed_out";
extern fn native_remove_tree(path: const u8[:]) -> i32 = "crap_remove_tree";
extern fn native_has_executable(prog: const u8[:]) -> i32 = "crap_has_executable";
extern fn native_setenv(key: const u8[:], val: const u8[:]) -> i32 = "crap_setenv";
extern fn native_host_os() -> i32 = "crap_host_os";
extern fn native_host_arch() -> i32 = "crap_host_arch";
extern fn native_cpu_count() -> i32 = "crap_cpu_count";
extern fn native_next_seq() -> u64 = "crap_next_seq";
extern fn native_work_reset() = "crap_work_reset";
extern fn native_work_claim(total: i32) -> i32 = "crap_work_claim";
extern fn native_atomic_set_stop(v: i32) = "crap_atomic_set_stop";
extern fn native_atomic_get_stop() -> i32 = "crap_atomic_get_stop";
extern fn native_file_mtime(path: const u8[:]) -> i64 = "crap_file_mtime";
extern fn native_file_size(path: const u8[:]) -> i64 = "crap_file_size";
extern fn native_exec_with_env_to_file(
    cmd:        const u8[:],
    env_key:    const u8[:],
    env_val:    const u8[:],
    out_path:   const u8[:],
    timeout_ms: i32,
) -> i32 = "crap_exec_with_env_to_file";
extern fn native_exec_in_dir_with_env(
    dir:        const u8[:],
    cmd:        const u8[:],
    env_key:    const u8[:],
    env_val:    const u8[:],
    out_path:   const u8[:],
    timeout_ms: i32,
) -> i32 = "crap_exec_in_dir_with_env";
extern fn native_abs_path(path: const u8[:], out: u8[:]) -> i64 = "crap_abs_path";
extern fn native_exec_argv_nul_to_file(
    argv_nul:   const u8[:],
    out_path:   const u8[:],
    timeout_ms: i32,
) -> i32 = "crap_exec_argv_nul_to_file";

fn resolve_abs_path(path: const u8[:], out: u8[>..]&) -> bool {
    guard path.len > 0 else { return false; }
    var buf: u8[4096] = [0; 4096];
    let n = native_abs_path(path, buf[..]);
    guard n > 0 && n <= buf.len else { return false; }
    out.append(buf[..n]);
    return true;
}

// Runs a program with NUL-delimited arguments directly (no shell) and captures output into `out`.
fn exec_argv_nul_capture(argv_nul: const u8[:], timeout_ms: i32, out: u8[>..]&) -> i32 {
    let seq = native_next_seq();
    ensure_lit_cache_dir();

    var tmp_path: u8[>..] = [];
    if is_dir(".lit/cache") {
        tmp_path.append(".lit/cache/.gcrap_cmd_");
    } else {
        tmp_path.append(".gcrap_cmd_");
    }
    append_u64(tmp_path, clock_ns() as u64);
    tmp_path.push('_');
    append_u64(tmp_path, seq);
    tmp_path.append(".tmp");

    let rc = native_exec_argv_nul_to_file(argv_nul, tmp_path[..], timeout_ms);
    if file_exists(tmp_path[..]) {
        read_file(tmp_path[..], out);
        delete_file(tmp_path[..]);
    }
    return rc;
}

var g_cache_dir_ready: bool = false;

// Cleans up any leftover .gcrap_cmd_*.tmp scratch files in .lit/cache/
fn clean_stale_cache() {
    guard is_dir(".lit/cache") else { return; }
    var entries: u8[>..] = [];
    guard list_dir(".lit/cache", entries) else { return; }
    var full_path: u8[>..] = [];
    var start:     i64     = 0;
    for i in entries.len {
        guard entries[i] == '\n' else { continue; }
        let name = trim_ascii(entries[start..i]);
        start = i + 1;
        if slice_starts_with(name, ".gcrap_cmd_") && slice_ends_with(name, ".tmp") {
            full_path.clear();
            full_path.append(".lit/cache/");
            full_path.append(name);
            delete_file(full_path[..]);
        }
    }
}

// Ensures the .lit/cache temporary directory exists.
fn ensure_lit_cache_dir() {
    if g_cache_dir_ready { return; }
    if !is_dir(".lit") {
        make_dir(".lit");
    }
    if !is_dir(".lit/cache") {
        make_dir(".lit/cache");
    }
    clean_stale_cache();
    g_cache_dir_ready = true;
}

// Runs an external command and captures its combined stdout/stderr into `out`.
// Returns the process exit status.
fn exec_capture(cmd: const u8[:], out: u8[>..]&) -> i32 {
    return exec_capture_timeout(cmd, 0, out);
}

// Runs an external command with an optional millisecond timeout and captures stdout/stderr into `out`.
fn exec_capture_timeout(cmd: const u8[:], timeout_ms: i32, out: u8[>..]&) -> i32 {
    let seq = native_next_seq();
    ensure_lit_cache_dir();

    var tmp_path: u8[>..] = [];
    if is_dir(".lit/cache") {
        tmp_path.append(".lit/cache/.gcrap_cmd_");
    } else {
        tmp_path.append(".gcrap_cmd_");
    }
    append_u64(tmp_path, clock_ns() as u64);
    tmp_path.push('_');
    append_u64(tmp_path, seq);
    tmp_path.append(".tmp");

    let rc = if timeout_ms > 0 {
        native_exec_to_file_timeout(cmd, tmp_path, timeout_ms)
    } else {
        native_exec_to_file(cmd, tmp_path)
    };
    if file_exists(tmp_path) {
        read_file(tmp_path, out);
        delete_file(tmp_path);
    }
    return rc;
}

// Runs a command inside `dir` with an isolated child env var and captures output into `out`.
fn exec_in_dir_with_env_capture(
    dir:        const u8[:],
    cmd:        const u8[:],
    env_key:    const u8[:],
    env_val:    const u8[:],
    timeout_ms: i32,
    out:        u8[>..]&,
) -> i32 {
    let seq = native_next_seq();
    ensure_lit_cache_dir();

    var tmp_path: u8[>..] = [];
    if is_dir(".lit/cache") {
        tmp_path.append(".lit/cache/.gcrap_cmd_");
    } else {
        tmp_path.append(".gcrap_cmd_");
    }
    append_u64(tmp_path, clock_ns() as u64);
    tmp_path.push('_');
    append_u64(tmp_path, seq);
    tmp_path.append(".tmp");

    let rc = native_exec_in_dir_with_env(dir, cmd, env_key, env_val, tmp_path, timeout_ms);
    if file_exists(tmp_path) {
        read_file(tmp_path, out);
        delete_file(tmp_path);
    }
    return rc;
}

// Runs a program with up to 3 arguments directly (no shell) and captures stdout/stderr into `out`.
fn exec_argv_capture(
    prog:       const u8[:],
    arg1:       const u8[:],
    arg2:       const u8[:],
    arg3:       const u8[:],
    timeout_ms: i32,
    out:        u8[>..]&,
) -> i32 {
    let seq = native_next_seq();
    ensure_lit_cache_dir();

    var tmp_path: u8[>..] = [];
    if is_dir(".lit/cache") {
        tmp_path.append(".lit/cache/.gcrap_cmd_");
    } else {
        tmp_path.append(".gcrap_cmd_");
    }
    append_u64(tmp_path, clock_ns() as u64);
    tmp_path.push('_');
    append_u64(tmp_path, seq);
    tmp_path.append(".tmp");

    let rc = native_exec_argv_to_file(prog, arg1, arg2, arg3, tmp_path, timeout_ms);
    if file_exists(tmp_path) {
        read_file(tmp_path, out);
        delete_file(tmp_path);
    }
    return rc;
}

inline fn is_unit_test_filename(name: const u8[:]) -> bool {
    guard slice_ends_with(name, ".goose") else { return false; }
    return name == "test.goose" || slice_ends_with(name, "_test.goose") || slice_starts_with(name, "test_");
}

inline fn is_ignored_dir_entry(name: const u8[:]) -> bool {
    guard name.len > 0 && name[0] != '.' else { return true; }
    return name == "vendor" || name == "scratch" || name == "bin" ||
        name == "build" || name == "target" || name == "node_modules";
}

// crap:trusted
// crap:trusted-bounds
fn scan_dir_entries_filtered(
    cur_dir:        const u8[:],
    entries:        const u8[:],
    include_tests:  bool,
    exclude_blob:   const u8[:],
    dir_queue:      u8[>..]&,
    out_paths_blob: u8[>..]&,
    child:          u8[>..]&,
) {
    var line_start: i64 = 0;
    for j in entries.len {
        guard entries[j] == '\n' else { continue; }
        let name = entries[line_start..j];
        line_start = j + 1;
        guard !is_ignored_dir_entry(name) else { continue; }
        guard include_tests || (name != "tests" && name != "test") else { continue; }

        child.clear();
        let is_dot = cur_dir == "." || cur_dir == "./" || cur_dir == ".\\";
        if !is_dot && cur_dir.len > 0 {
            child.append(cur_dir);
            if !slice_ends_with(cur_dir, "/") && !slice_ends_with(cur_dir, "\\") {
                child.push('/');
            }
        }
        child.append(name);
        guard !is_excluded_path(child, exclude_blob) else { continue; }

        if is_dir(child) {
            dir_queue.append(child);
            dir_queue.push('\n');
        } else if slice_ends_with(name, ".goose") {
            guard include_tests || !is_unit_test_filename(name) else { continue; }
            out_paths_blob.append(child);
            out_paths_blob.push('\n');
        }
    }
}

// crap:trusted
// crap:trusted-bounds
fn collect_goose_files_filtered(
    root_path:      const u8[:],
    include_tests:  bool,
    exclude_blob:   const u8[:],
    out_paths_blob: u8[>..]&,
) {
    if file_exists(root_path) {
        if slice_ends_with(root_path, ".goose") && !is_excluded_path(root_path, exclude_blob) {
            var norm: u8[>..] = [];
            normalize_path(root_path, norm);
            out_paths_blob.append(norm);
            out_paths_blob.push('\n');
        }
        return;
    }
    guard is_dir(root_path) else { return; }

    var clean_root: u8[>..] = [];
    normalize_path(root_path, clean_root);
    let is_root_dot = clean_root.len == 0 || clean_root == ".";

    var dir_queue: u8[>..] = [];
    if is_root_dot {
        dir_queue.append(".");
    } else {
        dir_queue.append(clean_root);
    }
    dir_queue.push('\n');

    var entries:      u8[>..] = [];
    var child:        u8[>..] = [];
    var queue_cursor: i64     = 0;
    while queue_cursor < dir_queue.len {
        let rel_nl = slice_index_of_byte(dir_queue[queue_cursor..], '\n');
        guard rel_nl >= 0 else { break; }
        let next_nl = queue_cursor + rel_nl;

        let cur_dir = dir_queue[queue_cursor..next_nl];
        queue_cursor = next_nl + 1;

        entries.clear();
        guard list_dir(cur_dir, entries) else { continue; }
        scan_dir_entries_filtered(
            cur_dir,
            entries[..],
            include_tests,
            exclude_blob,
            dir_queue,
            out_paths_blob,
            child,
        );
    }
}
