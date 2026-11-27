// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: goose %s
import std;
import os;
import cli from "..";

fn dummy_fuzz_target(buf: const u8[:]) -> bool {
    return false;
}

fn test_cycle2_bug1_shim_timeout_zombie_and_file_lock() {
    if crap::native_host_os() == 1 {
        var tmp_out: u8[>..] = [];
        tmp_out.append(".lit/cache/.gcrap_zr_cycle2_timeout.tmp");
        crap::ensure_lit_cache_dir();
        if file_exists(tmp_out[..]) {
            delete_file(tmp_out[..]);
        }

        let rc = crap::native_exec_to_file_timeout("ping -n 3 127.0.0.1", tmp_out[..], 100);
        assert(rc == 124);
        assert(crap::native_last_exec_timed_out() != 0);

        let del_ok = delete_file(tmp_out[..]);
        let still_exists = file_exists(tmp_out[..]);
        assert(del_ok && !still_exists);
    }
}

fn test_cycle2_bug2_runner_multi_feature_and_exit124() {
    assert(lit::host_has_feature("windows, linux, macos"));
    if crap::native_host_os() == 1 {
        assert(lit::host_has_all_features("windows, x86_64"));
    }

    crap::ensure_lit_cache_dir();
    let test_file = ".lit/cache/zr_cycle2_exit124.lit";
    let content = "// RUN: exit 124\n// XFAIL: *\n";
    write_file(test_file, content);

    var res = lit::TestResult { .. };
    let ok = lit::run_single_lit_test_with_timeout(test_file, false, 60, res);
    delete_file(test_file);

    assert(ok);
    assert(res.passed);
    assert(res.status == lit::TestStatus.XFail);
}

fn test_cycle2_bug3_wire_inspect_truncation_and_mutate_defects() {
    var hex_out: u8[>..] = [];
    lit::format_hexdump("ABCD", lit::VIRTUAL_PAGE_SIZE, hex_out);
    assert(crap::slice_starts_with(hex_out[..], "[0x10000]"));

    var simd_out: u8[>..] = [];
    lit::format_simd_lanes("ABCD", 65, 0x12340000, simd_out);
    assert(crap::slice_contains(simd_out[..], "[0x12340000..+16B]"));

    var fuzz_diag: u8[>..] = [];
    let fuzz_ok = lit::fuzz_payload_stream("ABCD", 0, fuzz_diag, dummy_fuzz_target);
    assert(!fuzz_ok);

    var rng:        u64 = 0x9E3779B97F4A7C15;
    var noop_count: i64 = 0;
    for _ in 50 {
        var one_b: u8[>..] = [];
        one_b.push(0xAA);
        lit::mutate_payload_once(one_b, rng);
        if one_b.len == 1 && one_b[0] == 0xAA {
            noop_count += 1;
        }
    }
    assert(noop_count == 0);
}

fn test_cycle2_bug4_config_quotes_comments_and_exclude_bypass() {
    var cfg = crap::LitConfig { .. };
    crap::parse_config_line("src_dir = \"src\"", cfg);
    crap::parse_config_line("format = \"json\"", cfg);
    crap::parse_config_line("ceiling = 20.0 # inline comment", cfg);
    crap::parse_config_line("timeout = 30 # inline comment", cfg);
    crap::parse_config_line("include_tests = \"true\"", cfg);

    assert(cfg.src_dir_buf == "src");
    assert(cfg.format_buf == "json");
    assert(cfg.has_gate_ceiling && cfg.gate_ceiling == 20.0);
    assert(cfg.has_timeout && cfg.timeout_sec == 30);
    assert(cfg.has_include_tests && cfg.include_tests);

    var ex_cfg = crap::LitConfig { .. };
    crap::parse_config_line("exclude = vendor", ex_cfg);
    assert(crap::is_excluded_path("./vendor/foo.goose", ex_cfg.exclude_buf[..]));
    assert(crap::is_excluded_path("././vendor/foo.goose", ex_cfg.exclude_buf[..]));

    var pat512:    u8[..1024] = [];
    var long_path: u8[>..]    = [];
    for _ in 512 {
        pat512.push('a');
        long_path.push('a');
    }
    pat512.push('\n');
    long_path.append("_not_matching_suffix.goose");

    let falsely_excluded = crap::is_excluded_path(long_path[..], pat512[..]);
    assert(!falsely_excluded);
}

fn main() {
    test_cycle2_bug1_shim_timeout_zombie_and_file_lock();
    test_cycle2_bug2_runner_multi_feature_and_exit124();
    test_cycle2_bug3_wire_inspect_truncation_and_mutate_defects();
    test_cycle2_bug4_config_quotes_comments_and_exclude_bypass();
    print("ALL_ZOMBIE_REAPER_CYCLE2_FIXED");
}
