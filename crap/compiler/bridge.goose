// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Goose compiler diagnostic bridge: parses and maps `--bce-lines` and `--specs` data.
namespace crap;

import std;
import os;
import sys.bytes;
import sys.proc;
import crap.ast.model;

// Identifies the primary .goose entry-point file when given a package directory.
fn resolve_package_entry_point(target_path: const u8[:], resolved_out: u8[>..]&) -> bool {
    var clean_path: u8[>..] = [];
    normalize_slashes(target_path, clean_path);
    if clean_path.len == 0 {
        clean_path.push('.');
    }

    while clean_path.len > 1 && clean_path[clean_path.len - 1] == '/' {
        clean_path.pop();
    }

    let p: const u8[:] = clean_path[..];

    if file_exists(p) && slice_ends_with(p, ".goose") {
        resolved_out.append(p);
        return true;
    }

    guard is_dir(p) else {
        resolved_out.append(p);
        return false;
    }

    let last_slash = slice_last_index_of_byte(p, '/');
    let dir_name = if last_slash >= 0 { p[last_slash + 1..] } else { p };

    // 1. Try <dir>/<dir_name>.goose
    var c1: u8[>..] = [];
    c1.append(p);
    c1.push('/');
    c1.append(dir_name);
    c1.append(".goose");
    if file_exists(c1) {
        resolved_out.append(c1);
        return true;
    }

    // 2. Try <dir>/main.goose
    var c2: u8[>..] = [];
    c2.append(p);
    c2.append("/main.goose");
    if file_exists(c2) {
        resolved_out.append(c2);
        return true;
    }

    // 3. Try <dir>/lib.goose
    var c3: u8[>..] = [];
    c3.append(p);
    c3.append("/lib.goose");
    if file_exists(c3) {
        resolved_out.append(c3);
        return true;
    }

    // 4. Try <dir>/mod.goose
    var c4: u8[>..] = [];
    c4.append(p);
    c4.append("/mod.goose");
    if file_exists(c4) {
        resolved_out.append(c4);
        return true;
    }

    // 5. Fallback: scan directory for first non-test .goose file
    var entries: u8[>..] = [];
    if list_dir(p, entries) {
        var line_start: i64 = 0;
        for j in entries.len {
            guard entries[j] == '\n' else { continue; }
            let name = entries[line_start..j];
            line_start = j + 1;
            let is_non_test_goose = slice_ends_with(name, ".goose") &&
                !slice_ends_with(name, "_test.goose") &&
                !slice_starts_with(name, "test_");
            if is_non_test_goose {
                resolved_out.append(p);
                resolved_out.push('/');
                resolved_out.append(name);
                return true;
            }
        }
    }

    resolved_out.append(p);
    return false;
}

fn append_compiler_options(cmd: u8[>..]&) {
    var goose_cc: u8[>..] = [];
    if !env("GOOSE_CC", goose_cc) {
        var os_env: u8[>..] = [];
        let is_win = env("OS", os_env) || file_exists("C:\\Windows");
        if is_win {
            cmd.append(" --cc gcc");
        }
    }
}

fn bce_cache_key_hex(entry: const u8[:], mtime: i64, size: i64, out: u8[>..]&) {
    var raw: u8[>..] = [];
    raw.append(entry);
    raw.push(':');
    append_i64(raw, mtime);
    raw.push(':');
    append_i64(raw, size);

    var h: u64 = 14695981039346656037;
    for b in raw {
        h = (h ^ b) * 1099511628211;
    }
    let hex_chars: const u8[:] = "0123456789abcdef";
    var sh: i64 = 60;
    while sh >= 0 {
        let nib = ((h >> (sh as u64)) & 0xF) as i64;
        out.push(hex_chars[nib]);
        sh -= 4;
    }
}

// Executes `goose --bce-lines --check` on target and captures diagnostic output without shell invocation.
// Caches output by `(entry, mtime, size)` in `.lit/cache/bce_<hex>.txt` unless `GCRAP_NO_CACHE` is set.
fn run_goose_bce_lines(target_path: const u8[:], out: u8[>..]&) -> i32 {
    var entry: u8[>..] = [];
    resolve_package_entry_point(target_path, entry);

    var no_cache_val: u8[>..] = [];
    let use_cache = !env("GCRAP_NO_CACHE", no_cache_val) || no_cache_val.len == 0;
    let mtime = native_file_mtime(entry[..]);
    let fsize = native_file_size(entry[..]);

    var cache_path: u8[>..] = [];
    if use_cache && mtime >= 0 && fsize >= 0 {
        ensure_lit_cache_dir();
        cache_path.append(".lit/cache/bce_");
        bce_cache_key_hex(entry[..], mtime, fsize, cache_path);
        cache_path.append(".txt");
        if file_exists(cache_path[..]) && read_file(cache_path[..], out) {
            return 0;
        }
    }

    let rc = exec_argv_capture("goose", "--bce-lines", "--check", entry[..], 0, out);
    if rc == 0 && cache_path.len > 0 && out.len > 0 {
        let _ = write_file(cache_path[..], out[..]);
    }
    return rc;
}

// Executes `goose --specs --check` on target and captures specialization output without shell invocation.
fn run_goose_specs(target_path: const u8[:], out: u8[>..]&) -> i32 {
    var entry: u8[>..] = [];
    resolve_package_entry_point(target_path, entry);
    return exec_argv_capture("goose", "--specs", "--check", entry[..], 0, out);
}

// Parses one bce-line record: "bce-line: <file>:<line>: <elided> elided, <kept> kept"
fn parse_bce_line(
    raw_line:     const u8[:],
    file_out:     u8[>..]&,
    line_num_out: i32&,
    elided_out:   i32&,
    kept_out:     i32&,
) -> bool {
    var t = trim_ascii(raw_line);
    if t.len >= 3 && t[0] == 0xEF && t[1] == 0xBB && t[2] == 0xBF {
        t = t[3..];
    }
    guard slice_starts_with(t, "bce-line:") else { return false; }
    let rest = trim_ascii(t[9..]);

    // Format: <file>:<line>: <elided> elided, <kept> kept
    // Note on Windows: file may contain a drive letter colon followed by '/' or '\' (e.g. C:/... or ./C:/...)
    var first_colon:  i64 = -1;
    var second_colon: i64 = -1;

    for i in rest.len {
        if rest[i] == ':' {
            if i + 1 < rest.len && (rest[i + 1] == '/' || rest[i + 1] == '\\') {
                continue;
            }
            if first_colon < 0 {
                first_colon = i;
            } else if second_colon < 0 {
                second_colon = i;
                break;
            }
        }
    }

    guard first_colon > 0 && second_colon > first_colon else { return false; }

    let file_part = trim_ascii(rest[..first_colon]);
    let line_part = trim_ascii(rest[first_colon + 1..second_colon]);
    let counts_part = trim_ascii(rest[second_colon + 1..]);

    let lnum, ok_l = parse_i64_slice(line_part);
    guard ok_l else { return false; }

    // Parse "<elided> elided, <kept> kept"
    let elided_idx = slice_index_of(counts_part, "elided");
    guard elided_idx > 0 else { return false; }
    let elided_num_str = trim_ascii(counts_part[..elided_idx]);
    let elided_val, ok_e = parse_i64_slice(elided_num_str);
    guard ok_e else { return false; }

    var kept_val: i64 = 0;
    let comma_idx = slice_index_of(counts_part, ",");
    if comma_idx > 0 {
        let after_comma = trim_ascii(counts_part[comma_idx + 1..]);
        let kept_idx = slice_index_of(after_comma, "kept");
        if kept_idx > 0 {
            let kept_num_str = trim_ascii(after_comma[..kept_idx]);
            let kv, ok_k = parse_i64_slice(kept_num_str);
            if ok_k {
                kept_val = kv;
            }
        }
    }

    file_out.append(file_part);
    line_num_out = lnum as i32;
    elided_out = elided_val as i32;
    kept_out = kept_val as i32;
    return true;
}

// Maps parsed `--bce-lines` records directly onto functions and branches.
fn apply_bce_lines_blob(
    output_blob: const u8[:],
    pool:        const u8[:],
    functions:   FunctionInfo[>..]&,
    branches:    BranchSite[>..]&,
) {
    var line_start: i64 = 0;
    let n = output_blob.len;
    var file_buf: u8[>..] = [];

    while line_start < n {
        var line_end = n;
        for i in line_start..n {
            if output_blob[i] == '\n' {
                line_end = i;
                break;
            }
        }

        let raw_line = output_blob[line_start..line_end];
        line_start = line_end + 1;

        file_buf.clear();
        var line_num: i32 = 0;
        var elided:   i32 = 0;
        var kept:     i32 = 0;

        if parse_bce_line(raw_line, file_buf, line_num, elided, kept) {
            // Find matching function
            for fi in functions.len {
                let fn_file = pool_slice(pool, functions[fi].file_off, functions[fi].file_len);
                if paths_match(fn_file, file_buf) {
                    let st = functions[fi].start_line;
                    let en = functions[fi].end_line;
                    if line_num >= st && line_num <= en {
                        // Find the innermost branch site covering this line (narrowest line span, then highest depth)
                        let f_first = functions[fi].first_branch;
                        let f_count = functions[fi].branch_count;
                        var matched_bid: i64 = -1;
                        var best_span:   i32 = 2147483647;
                        var best_depth:  i32 = -1;

                        for bi in f_count {
                            let idx: i64 = f_first + bi;
                            if idx < branches.len {
                                let b_start = branches[idx].start_line;
                                let b_end = branches[idx].end_line;
                                if line_num >= b_start && line_num <= b_end {
                                    let b_span = b_end - b_start;
                                    let b_depth = branches[idx].depth;
                                    if matched_bid < 0 || b_span < best_span || (b_span == best_span && b_depth >= best_depth) {
                                        matched_bid = idx;
                                        best_span = b_span;
                                        best_depth = b_depth;
                                    }
                                }
                            }
                        }

                        if matched_bid >= 0 {
                            if branches[matched_bid].trusted_bounds {
                                branches[matched_bid].bce_elide += (elided + kept);
                                branches[matched_bid].classification = BRANCH_CLASS_DEFENSIVE;
                                functions[fi].total_bce_elide += (elided + kept);
                            } else {
                                branches[matched_bid].bce_elide += elided;
                                branches[matched_bid].bce_keep += kept;
                                if branches[matched_bid].bce_keep > 0 {
                                    branches[matched_bid].classification = BRANCH_CLASS_BOUNDS_CHECK;
                                }
                                functions[fi].total_bce_elide += elided;
                                functions[fi].total_bce_keep += kept;
                            }
                        }
                        break;
                    }
                }
            }
        }
    }
}

// Parses and maps `goose --specs --check` output records onto functions.
fn apply_specs_blob(
    output_blob: const u8[:],
    pool:        const u8[:],
    functions:   FunctionInfo[>..]&,
) {
    var line_start: i64 = 0;
    let n = output_blob.len;

    var cur_nodes: i32 = 0;
    var cur_nest:  i32 = 0;
    var cur_noinline = false;
    var pending_spec = false;

    while line_start < n {
        var line_end = n;
        for i in line_start..n {
            if output_blob[i] == '\n' {
                line_end = i;
                break;
            }
        }

        let raw_line = trim_ascii(output_blob[line_start..line_end]);
        line_start = line_end + 1;

        if slice_starts_with(raw_line, "// spec ") {
            pending_spec = true;
            cur_nodes = 0;
            cur_nest = 0;
            cur_noinline = slice_contains(raw_line, "noinline");

            let nodes_idx = slice_index_of(raw_line, "nodes ");
            if nodes_idx > 0 {
                let rest = raw_line[nodes_idx + 6..];
                let comma_idx = slice_index_of_byte(rest, ',');
                let num_str = if comma_idx > 0 { rest[..comma_idx] } else { rest };
                let val, ok = parse_i64_slice(num_str);
                if ok { cur_nodes = val as i32; }
            }

            let nest_idx = slice_index_of(raw_line, "nest ");
            if nest_idx > 0 {
                let rest = raw_line[nest_idx + 5..];
                let comma_idx = slice_index_of_byte(rest, ',');
                let num_str = if comma_idx > 0 { rest[..comma_idx] } else { rest };
                let val, ok = parse_i64_slice(num_str);
                if ok { cur_nest = val as i32; }
            }
            continue;
        }

        // Match function signature following `// spec ...`
        // Handles function qualifiers (inline fn, recursive fn, checkfree fn, etc. per Goose ref §17 / spec §7)
        if pending_spec && (slice_starts_with(raw_line, "fn ") || slice_contains(raw_line, " fn ")) {
            pending_spec = false;
            let fn_offset = if slice_starts_with(raw_line, "fn ") {
                3
            } else {
                let fn_pos = slice_index_of(raw_line, " fn ");
                if fn_pos >= 0 { fn_pos + 4 } else { 0 }
            };
            guard fn_offset > 0 && fn_offset < raw_line.len else { continue; }
            let after_fn = trim_ascii(raw_line[fn_offset..]);
            let paren_idx = slice_index_of_byte(after_fn, '(');
            guard paren_idx > 0 else { continue; }
            var sig_name = trim_ascii(after_fn[..paren_idx]);

            // Strip generic specialization parameters if present: foo<i64> -> foo (Goose ref §18 / spec §7.1)
            let lt_idx = slice_index_of_byte(sig_name, '<');
            if lt_idx > 0 {
                sig_name = trim_ascii(sig_name[..lt_idx]);
            }
            if slice_starts_with(sig_name, "::") {
                sig_name = trim_ascii(sig_name[2..]);
            }

            // Pass 1: Match exact qualified name
            var matched_exact = false;
            for fi in functions.len {
                let qname = pool_slice(pool, functions[fi].qual_off, functions[fi].qual_len);
                if sig_name == qname {
                    matched_exact = true;
                    functions[fi].specs_count++;
                    functions[fi].max_spec_nodes = max(functions[fi].max_spec_nodes, cur_nodes);
                    functions[fi].compiler_nest = max(functions[fi].compiler_nest, cur_nest);
                    if cur_noinline {
                        functions[fi].has_noinline = true;
                    }
                }
            }

            // Pass 2: Fallback to short name across matching generic functions
            if !matched_exact {
                for fi in functions.len {
                    let sname = pool_slice(pool, functions[fi].name_off, functions[fi].name_len);
                    if sig_name == sname {
                        functions[fi].specs_count++;
                        functions[fi].max_spec_nodes = max(functions[fi].max_spec_nodes, cur_nodes);
                        functions[fi].compiler_nest = max(functions[fi].compiler_nest, cur_nest);
                        if cur_noinline {
                            functions[fi].has_noinline = true;
                        }
                    }
                }
            }
            cur_nodes = 0;
            cur_nest = 0;
            cur_noinline = false;
        }
    }

    for fi in functions.len {
        if functions[fi].is_generic && functions[fi].specs_count == 0 {
            functions[fi].uninstantiated_generic = true;
        }
    }
}
