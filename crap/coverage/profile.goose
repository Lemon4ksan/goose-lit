// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Branch coverage profile reader, writer, LCOV importer, and metric aggregator.
namespace crap;

import std;
import os;
import sys.bytes;
import crap.ast.model;

fn add_hits_sat(cur: u64, delta: u64) -> u64 {
    let max_u64: u64 = 18446744073709551615;
    if cur > max_u64 - delta {
        return max_u64;
    }
    return cur + delta;
}

// Loads a `.gcrap-cov` profile and maps hits to branches by branch_id.
fn load_gcrap_profile(profile_path: const u8[:], branches: BranchSite[>..]&) -> bool {
    var content: u8[>..] = [];
    guard read_file(profile_path, content) else { return false; }

    var line_start: i64 = 0;
    let n = content.len;

    while line_start < n {
        var line_end = n;
        for i in line_start..n {
            if content[i] == '\n' {
                line_end = i;
                break;
            }
        }

        let raw_line = trim_ascii(content[line_start..line_end]);
        line_start = line_end + 1;

        if raw_line.len == 0 || raw_line[0] == '#' {
            continue;
        }

        // Expected format: "id <branch_id> <hits>"
        if slice_starts_with(raw_line, "id ") {
            let rest = trim_ascii(raw_line[3..]);
            let sp_idx = slice_index_of_byte(rest, ' ');
            if sp_idx > 0 {
                let id_str = trim_ascii(rest[..sp_idx]);
                let hits_str = trim_ascii(rest[sp_idx + 1..]);
                let bid, ok_id = parse_i64_slice(id_str);
                let hits_val, ok_h = parse_u64_slice(hits_str);
                if ok_id && ok_h && bid >= 0 && bid <= 2147483647 {
                    let bid32 = bid as i32;
                    var matched_idx: i64 = -1;
                    if bid < branches.len && branches[bid].branch_id == bid32 {
                        matched_idx = bid;
                    } else {
                        for bi in branches.len {
                            if branches[bi].branch_id == bid32 {
                                matched_idx = bi;
                                break;
                            }
                        }
                    }
                    if matched_idx >= 0 {
                        branches[matched_idx].hits = add_hits_sat(branches[matched_idx].hits, hits_val);
                        branches[matched_idx].covered = branches[matched_idx].covered || (hits_val > 0);
                    }
                }
            }
        }
    }
    return true;
}

// Imports LCOV DA (line) and BRDA (branch) counts into branch coverage.
fn load_lcov_profile(
    lcov_path: const u8[:],
    pool:      const u8[:],
    functions: FunctionInfo[>..]&,
    branches:  BranchSite[>..]&,
) -> bool {
    var content: u8[>..] = [];
    guard read_file(lcov_path, content) else { return false; }

    var cur_file:   u8[>..] = [];
    var line_start: i64     = 0;
    let n = content.len;

    while line_start < n {
        var line_end = n;
        for i in line_start..n {
            if content[i] == '\n' {
                line_end = i;
                break;
            }
        }

        let raw_line = trim_ascii(content[line_start..line_end]);
        line_start = line_end + 1;

        if slice_starts_with(raw_line, "SF:") {
            cur_file.clear();
            cur_file.append(trim_ascii(raw_line[3..]));
            continue;
        }

        if slice_starts_with(raw_line, "DA:") && cur_file.len > 0 {
            // Line coverage fallback: DA:<line>,<hits>[,<checksum>]
            let rest = trim_ascii(raw_line[3..]);
            let comma_idx = slice_index_of_byte(rest, ',');
            if comma_idx > 0 {
                let l_str = trim_ascii(rest[..comma_idx]);
                var h_str = trim_ascii(rest[comma_idx + 1..]);
                let comma2 = slice_index_of_byte(h_str, ',');
                if comma2 >= 0 {
                    h_str = trim_ascii(h_str[..comma2]);
                }
                let lnum, ok_l = parse_i64_slice(l_str);
                let hits, ok_h = parse_u64_slice(h_str);
                if ok_l && ok_h && hits > 0 {
                    let line32 = lnum as i32;
                    for bi in branches.len {
                        let f_idx: i64 = branches[bi].func_idx;
                        if f_idx >= 0 && f_idx < functions.len {
                            let fn_file = pool_slice(pool, functions[f_idx].file_off, functions[f_idx].file_len);
                            if paths_match(fn_file, cur_file) {
                                if branches[bi].start_line == line32 {
                                    branches[bi].hits = add_hits_sat(branches[bi].hits, hits);
                                    branches[bi].covered = true;
                                }
                            }
                        }
                    }
                }
            }
            continue;
        }

        if slice_starts_with(raw_line, "BRDA:") && cur_file.len > 0 {
            // BRDA:<line>,<block>,<branch>,<hits>
            let rest = trim_ascii(raw_line[5..]);
            let c1 = slice_index_of_byte(rest, ',');
            if c1 > 0 {
                let line_part = trim_ascii(rest[..c1]);
                let after_c1 = rest[c1 + 1..];
                let c2 = slice_index_of_byte(after_c1, ',');
                if c2 >= 0 {
                    let after_c2 = after_c1[c2 + 1..];
                    let c3 = slice_index_of_byte(after_c2, ',');
                    if c3 > 0 {
                        let br_part = trim_ascii(after_c2[..c3]);
                        let hits_part = trim_ascii(after_c2[c3 + 1..]);
                        let lnum, ok_l = parse_i64_slice(line_part);
                        let br_idx, ok_br = parse_i64_slice(br_part);
                        if ok_l && hits_part != "-" {
                            let hits, ok_h = parse_u64_slice(hits_part);
                            if ok_h && hits > 0 {
                                let line32 = lnum as i32;
                                let target_ord = if ok_br && br_idx >= 0 { br_idx } else { 0 };
                                var cur_ord: i64 = 0;
                                for bi in branches.len {
                                    let f_idx: i64 = branches[bi].func_idx;
                                    if f_idx >= 0 && f_idx < functions.len {
                                        let fn_file = pool_slice(pool, functions[f_idx].file_off, functions[f_idx].file_len);
                                        if paths_match(fn_file, cur_file) && branches[bi].start_line == line32 {
                                            if cur_ord == target_ord {
                                                branches[bi].hits = add_hits_sat(branches[bi].hits, hits);
                                                branches[bi].covered = true;
                                                break;
                                            }
                                            cur_ord += 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return true;
}

// Aggregates branch coverage metrics and safety invariants onto each function.
fn aggregate_coverage_metrics(
    cfg:       const RiskConfig&,
    functions: FunctionInfo[>..]&,
    branches:  BranchSite[>..]&,
) {
    for fi in functions.len {
        let first = functions[fi].first_branch;
        let count = functions[fi].branch_count;
        let prev_covered = functions[fi].covered_branches;

        var covered_cnt:    i32 = 0;
        var uncov_bce_keep: i32 = 0;
        var uncov_ovf:      i32 = 0;

        for bi in count {
            let idx: i64 = first + bi;
            if idx < branches.len {
                if cfg.has_coverage_profile {
                    if branches[idx].covered {
                        covered_cnt++;
                    } else {
                        uncov_bce_keep += branches[idx].bce_keep;
                        uncov_ovf += branches[idx].ovf_ops;
                    }
                } else {
                    // Static triage mode: default coverage or 0.0
                    if cfg.default_cov >= 1.0 {
                        branches[idx].covered = true;
                        covered_cnt++;
                    } else {
                        branches[idx].covered = false;
                        uncov_bce_keep += branches[idx].bce_keep;
                        uncov_ovf += branches[idx].ovf_ops;
                    }
                }
            }
        }

        if count > 0 {
            functions[fi].covered_branches = covered_cnt;
            if cfg.has_coverage_profile {
                functions[fi].cov_branch = (covered_cnt as f64) / count;
            } else {
                functions[fi].cov_branch = cfg.default_cov;
            }
        } else {
            // Function with 0 branches preserves prior covered_branches indicator
            functions[fi].cov_branch = if cfg.has_coverage_profile {
                if prev_covered > 0 { 1.0 } else { 0.0 }
            } else {
                cfg.default_cov
            };
        }

        functions[fi].uncovered_bce_keep = uncov_bce_keep;
        functions[fi].uncovered_ovf_ops = uncov_ovf;
    }
}
