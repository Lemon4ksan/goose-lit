// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: goose %s | %FileCheck %s

import std;
import lit from "..";

fn test_parse_config() {
    var cfg = crap::LitConfig { .. };

    crap::parse_config_line("# This is a comment", cfg);
    crap::parse_config_line("// Another comment", cfg);
    crap::parse_config_line("; Semicolon comment", cfg);
    assert(!cfg.has_gate_ceiling);

    crap::parse_config_line("baseline = custom.baseline", cfg);
    assert(cfg.baseline_buf == "custom.baseline");

    crap::parse_config_line("ceiling = 18.5", cfg);
    assert(cfg.has_gate_ceiling);
    assert(cfg.gate_ceiling > 18.4 && cfg.gate_ceiling < 18.6);

    crap::parse_config_line("cov_profile = .lit/cache/cov/merged.gcrap-cov", cfg);
    assert(cfg.cov_profile_buf == ".lit/cache/cov/merged.gcrap-cov");

    crap::parse_config_line("delta = 4.0", cfg);
    assert(cfg.has_delta);
    assert(cfg.delta_threshold > 3.9 && cfg.delta_threshold < 4.1);

    crap::parse_config_line("format = json", cfg);
    assert(cfg.format_buf == "json");

    crap::parse_config_line("prefix = VERIFY", cfg);
    assert(cfg.prefix_buf == "VERIFY");

    crap::parse_config_line("tests_dir = custom_tests", cfg);
    assert(cfg.tests_dir_buf == "custom_tests");

    crap::parse_config_line("src_dir = custom_src", cfg);
    assert(cfg.src_dir_buf == "custom_src");

    crap::parse_config_line("include_tests = true", cfg);
    assert(cfg.has_include_tests);
    assert(cfg.include_tests == true);

    crap::parse_config_line("include_tests = false", cfg);
    assert(cfg.include_tests == false);

    var save_buf: u8[..256] = [];
    crap::default_save_baseline_path(cfg.baseline_buf[..], save_buf);
    assert(save_buf == "custom.baseline");

    var empty_save: u8[..256] = [];
    crap::default_save_baseline_path("", empty_save);
    assert(empty_save == ".lit/baseline" || empty_save == ".lit-baseline");

    // Verify integer parsing overflow and i64::MIN formatting invariants
    let min_val, ok_min = crap::parse_i64_slice("-9223372036854775808");
    assert(ok_min);
    assert(min_val == (-9223372036854775807 - 1));

    var min_buf: u8[..32] = [];
    crap::append_i64(min_buf, min_val);
    assert(min_buf == "-9223372036854775808");

    let _, ok_ovf_pos = crap::parse_i64_slice("9223372036854775808");
    assert(!ok_ovf_pos);

    let _, ok_ovf_neg = crap::parse_i64_slice("-9223372036854775809");
    assert(!ok_ovf_neg);

    let _, ok_ovf_u64 = crap::parse_u64_slice("18446744073709551616");
    assert(!ok_ovf_u64);

    // Verify sloc_* config keys and absolute path resolution
    crap::parse_config_line("sloc_baseline = .lit/custom-sloc-baseline", cfg);
    assert(cfg.sloc_baseline_buf == ".lit/custom-sloc-baseline");

    crap::parse_config_line("sloc_map = .lit/custom-sloc-map", cfg);
    assert(cfg.sloc_map_buf == ".lit/custom-sloc-map");

    crap::parse_config_line("sloc_exclude = tests/, bench/, tools/", cfg);
    assert(crap::is_excluded_path("bench/foo.goose", cfg.sloc_exclude_buf[..]));
    assert(!crap::is_excluded_path("http/parser.goose", cfg.sloc_exclude_buf[..]));

    crap::parse_config_line("sloc_bce_entries = core.goose, wing.goose", cfg);
    assert(crap::slice_contains(cfg.sloc_bce_entries_buf[..], "core.goose"));
    assert(crap::slice_contains(cfg.sloc_bce_entries_buf[..], "wing.goose"));

    crap::parse_config_line("sloc_max_packing = 1.40", cfg);
    assert(cfg.has_sloc_max_packing);
    assert(cfg.sloc_max_packing > 1.39 && cfg.sloc_max_packing < 1.41);

    crap::parse_config_line("sloc_max_delta = 12", cfg);
    assert(cfg.has_sloc_max_delta);
    assert(cfg.sloc_max_delta == 12);

    crap::parse_config_line("sloc_cycle_noise = 7.5", cfg);
    assert(cfg.has_sloc_cycle_noise);
    assert(cfg.sloc_cycle_noise > 7.4 && cfg.sloc_cycle_noise < 7.6);

    var sloc_save_buf: u8[..256] = [];
    crap::default_save_sloc_baseline_path(cfg.sloc_baseline_buf[..], sloc_save_buf);
    assert(sloc_save_buf == ".lit/custom-sloc-baseline");

    var abs_buf: u8[>..] = [];
    let ok_abs = crap::resolve_abs_path("bin.goose", abs_buf);
    assert(ok_abs);
    assert(abs_buf.len > 9);
    assert(crap::slice_ends_with(abs_buf[..], "bin.goose"));
}

fn main() {
    test_parse_config();
    print("CONFIG_TEST: PASS");
}

// CHECK: CONFIG_TEST: PASS
