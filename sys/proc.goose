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
extern fn native_setenv(key: const u8[:], val: const u8[:]) -> i32 = "crap_setenv";
extern fn native_host_os() -> i32 = "crap_host_os";
extern fn native_host_arch() -> i32 = "crap_host_arch";
extern fn native_cpu_count() -> i32 = "crap_cpu_count";

var g_cmd_seq:         u64  = 0;
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
    g_cmd_seq += 1;
    ensure_lit_cache_dir();

    var tmp_path: u8[>..] = [];
    if is_dir(".lit/cache") {
        tmp_path.append(".lit/cache/.gcrap_cmd_");
    } else {
        tmp_path.append(".gcrap_cmd_");
    }
    append_u64(tmp_path, clock_ns() as u64);
    tmp_path.push('_');
    append_u64(tmp_path, g_cmd_seq);
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
            guard include_tests || !slice_ends_with(name, "_test.goose") else { continue; }
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
