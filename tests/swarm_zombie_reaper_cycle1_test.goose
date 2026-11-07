// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// RUN: goose %s
import std;
import os;
import lit from "..";

fn test_bug1_config_bracketed_exclude_list() {
    var cfg = crap::LitConfig { .. };
    crap::parse_config_line("exclude = [\"vendor\", \"scratch\"]", cfg);

    let vendor_excluded = crap::is_excluded_path("vendor/lib.goose", cfg.exclude_buf[..]);
    let scratch_excluded = crap::is_excluded_path("scratch/tmp.goose", cfg.exclude_buf[..]);

    assert(vendor_excluded);
    assert(scratch_excluded);
}

fn test_bug2_runner_directive_drop_and_substitution() {
    var long_src: u8[>..] = [];
    long_src.append("// RUN: echo ");
    for _ in 520 {
        long_src.push('A');
    }
    long_src.push('\n');

    var directives: lit::RunDirective[>..] = [];
    let has_dirs = lit::parse_run_directives(long_src[..], directives);
    assert(has_dirs);
    assert(directives.len == 1);
    assert(!directives[0].overflowed);

    var out_escaped: u8[>..] = [];
    lit::substitute_lit_command("printf %%s", "tests/sample.lit", out_escaped);
    assert(out_escaped[..] == "printf %s");

    var out_env: u8[>..] = [];
    lit::substitute_lit_command("echo %temp%", "tests/sample.lit", out_env);
    assert(out_env[..] == "echo %temp%");
}

fn test_bug3_wire_hex_fail_open_and_mutate_zero_seed() {
    var pkt1: u8[>..] = [];
    let ok1 = lit::parse_packet_payload("0x41 0x42", pkt1);
    assert(!ok1);
    assert(pkt1.len == 0);

    var pkt2: u8[>..] = [];
    let ok2 = lit::parse_packet_payload("deadbeef.nonexistent_file", pkt2);
    assert(!ok2);
    assert(pkt2.len == 0);

    var zero_rng: u64 = 0;
    let step1 = lit::xorshift64_step(zero_rng);
    let step2 = lit::xorshift64_step(zero_rng);
    assert(step1 != 0 && step2 != 0 && zero_rng != 0);
}

fn test_bug4_shim_setenv_cwd_corruption() {
    crap::native_setenv("GCRAP_TEST_CC_VAR", "gcc");
    var val: u8[>..] = [];
    let ok = env("GCRAP_TEST_CC_VAR", val);
    assert(ok);
    assert(val[..] == "gcc");
}

fn main() {
    test_bug1_config_bracketed_exclude_list();
    test_bug2_runner_directive_drop_and_substitution();
    test_bug3_wire_hex_fail_open_and_mutate_zero_seed();
    test_bug4_shim_setenv_cwd_corruption();
    print("ALL_ZOMBIE_REAPER_CYCLE1_FIXED");
}
