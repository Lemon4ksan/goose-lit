// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Process execution and filesystem traversal bindings for goose-crap.
namespace crap;

import std;
import os;
import core.bytes;

extern fn native_exec_to_file(cmd: const u8[:], out_path: const u8[:]) -> i32 = "crap_exec_to_file";
extern fn native_cov_hit(id: i32) = "crap_cov_hit";
extern fn native_cov_reset() = "crap_cov_reset";
extern fn native_cov_get(id: i32) -> i64 = "crap_cov_get";
extern fn native_cov_dump(path: const u8[:]) -> i32 = "crap_cov_dump";

// Runs an external command and captures its combined stdout/stderr into `out`.
// Returns the process exit status.
fn exec_capture(cmd: const u8[:], out: u8[>..]&) -> i32 {
    var tmp_path: u8[>..] = [];
    tmp_path.append(".gcrap_cmd_");
    append_u64(tmp_path, (clock_ns() as u64) & 0xFFFFFF);
    tmp_path.append(".tmp");

    let rc = native_exec_to_file(cmd, tmp_path);
    if file_exists(tmp_path) {
        read_file(tmp_path, out);
        delete_file(tmp_path);
    }
    return rc;
}

// Iterative file collection that avoids recursive frame allocation (§7.8).
// Appends newline-separated paths of all matching `.goose` files into `out_paths_blob`.
fn collect_goose_files(root_path: const u8[:], include_tests: bool, out_paths_blob: u8[>..]&) {
    if file_exists(root_path) {
        if slice_ends_with(root_path, ".goose") {
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
                    let name = entries[line_start..j];
                    line_start = j + 1;
                    if name.len > 0 && name[0] != '.' &&
                       name != "vendor" && name != "scratch" && name != "bin" &&
                       name != "build" && name != "target" && name != "node_modules" {
                        if !include_tests && (name == "tests" || name == "test") {
                            continue;
                        }
                        var child: u8[>..] = [];
                        let is_dot = cur_dir == "." || cur_dir == "./" || cur_dir == ".\\";
                        if !is_dot && cur_dir.len > 0 {
                            child.append(cur_dir);
                            if !slice_ends_with(cur_dir, "/") && !slice_ends_with(cur_dir, "\\") {
                                child.push('/');
                            }
                        }
                        child.append(name);

                        if is_dir(child) {
                            dir_queue.append(child);
                            dir_queue.push('\n');
                        } else if slice_ends_with(name, ".goose") {
                            if !include_tests && slice_ends_with(name, "_test.goose") {
                                continue;
                            }
                            out_paths_blob.append(child);
                            out_paths_blob.push('\n');
                        }
                    }
                }
            }
        }
    }
}
