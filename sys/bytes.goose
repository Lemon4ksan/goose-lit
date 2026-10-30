// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// Zero-allocation byte slice scanning, integer parsing, float formatting, and path canonicalization.
namespace crap;

import std;

fn is_ascii_space(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

fn is_ascii_digit(c: u8) -> bool {
    return c >= '0' && c <= '9';
}

fn is_ident_start(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

fn is_ident_cont(c: u8) -> bool {
    return is_ident_start(c) || is_ascii_digit(c);
}

fn ascii_lower(c: u8) -> u8 {
    if c >= 'A' && c <= 'Z' {
        return c + 32;
    }
    return c;
}

fn slice_starts_with(s: const u8[:], prefix: const u8[:]) -> bool {
    guard s.len >= prefix.len else { return false; }
    return s[..prefix.len] == prefix;
}

fn slice_ends_with(s: const u8[:], suffix: const u8[:]) -> bool {
    guard s.len >= suffix.len else { return false; }
    let start = s.len - suffix.len;
    guard start >= 0 && start <= s.len else { return false; }
    return s[start..] == suffix;
}

fn slice_index_of_byte(s: const u8[:], b: u8) -> i64 {
    for i in s.len {
        if s[i] == b { return i; }
    }
    return -1;
}

fn slice_last_index_of_byte(s: const u8[:], b: u8) -> i64 {
    var i: i64 = s.len - 1;
    while i >= 0 {
        if s[i] == b { return i; }
        i--;
    }
    return -1;
}

fn slice_index_of(haystack: const u8[:], needle: const u8[:]) -> i64 {
    if needle.len == 0 { return 0; }
    guard haystack.len >= needle.len else { return -1; }
    let limit = haystack.len - needle.len;
    var i: i64 = 0;
    while i <= limit {
        let end = i + needle.len;
        guard end <= haystack.len else { break; }
        if haystack[i..end] == needle {
            return i;
        }
        i++;
    }
    return -1;
}

fn slice_contains(haystack: const u8[:], needle: const u8[:]) -> bool {
    return slice_index_of(haystack, needle) >= 0;
}

fn trim_ascii(s: const u8[:]) -> const u8[:] {
    var start: i64 = 0;
    var end:   i64 = s.len;
    while start < end && is_ascii_space(s[start]) {
        start++;
    }
    while end > start && is_ascii_space(s[end - 1]) {
        end--;
    }
    guard start >= 0 && end <= s.len && start <= end else { return ""; }
    return s[start..end];
}

fn parse_u64_slice(s: const u8[:]) -> u64, bool {
    let t = trim_ascii(s);
    guard t.len > 0 else { return 0, false; }
    var val: u64 = 0;
    for c in t {
        guard is_ascii_digit(c) else { return 0, false; }
        val = val * 10 + (c - '0');
    }
    return val, true;
}

fn parse_i64_slice(s: const u8[:]) -> i64, bool {
    let t = trim_ascii(s);
    guard t.len > 0 else { return 0, false; }
    var neg = false;
    var idx: i64 = 0;
    if t[0] == '-' {
        neg = true;
        idx = 1;
    } else if t[0] == '+' {
        idx = 1;
    }
    guard idx < t.len else { return 0, false; }
    let uval, ok = parse_u64_slice(t[idx..]);
    guard ok else { return 0, false; }
    if neg {
        return -(uval as i64), true;
    }
    return uval as i64, true;
}

// Parses a 64-bit float from a byte slice with optional sign, decimal point, and exponent.
// Avoids heap allocation or string scanning buffers (§7.8).
fn parse_f64_slice(s: const u8[:]) -> f64, bool {
    let t = trim_ascii(s);
    guard t.len > 0 else { return 0.0, false; }
    var neg = false;
    var idx: i64 = 0;
    if t[0] == '-' {
        neg = true;
        idx = 1;
    } else if t[0] == '+' {
        idx = 1;
    }
    guard idx < t.len else { return 0.0, false; }

    var val: f64 = 0.0;
    var digits_seen = 0;

    // Parse integer part
    while idx < t.len && is_ascii_digit(t[idx]) {
        val = val * 10.0 + (t[idx] - '0');
        digits_seen++;
        idx++;
    }

    // Parse fractional part
    if idx < t.len && t[idx] == '.' {
        idx++;
        var frac_val: f64 = 0.0;
        var frac_div: f64 = 1.0;
        while idx < t.len && is_ascii_digit(t[idx]) {
            frac_val = frac_val * 10.0 + (t[idx] - '0');
            frac_div *= 10.0;
            digits_seen++;
            idx++;
        }
        val += frac_val / frac_div;
    }

    guard digits_seen > 0 else { return 0.0, false; }

    // Parse exponent part
    if idx < t.len && (t[idx] == 'e' || t[idx] == 'E') {
        idx++;
        guard idx < t.len else { return 0.0, false; }
        var exp_neg = false;
        if t[idx] == '-' {
            exp_neg = true;
            idx++;
        } else if t[idx] == '+' {
            idx++;
        }
        guard idx < t.len && is_ascii_digit(t[idx]) else { return 0.0, false; }
        var exp_val: i64 = 0;
        while idx < t.len && is_ascii_digit(t[idx]) {
            exp_val = exp_val * 10 + (t[idx] - '0');
            idx++;
        }
        var exp_scale: f64 = 1.0;
        var p:         i64 = 0;
        while p < exp_val {
            exp_scale *= 10.0;
            p++;
        }
        if exp_neg {
            val /= exp_scale;
        } else {
            val *= exp_scale;
        }
    }

    guard idx == t.len else { return 0.0, false; }

    if neg {
        val = -val;
    }
    return val, true;
}

fn append_u64<B>(out: B&, val: u64) {
    if val == 0 {
        out.push('0');
        return;
    }
    var tmp: u8[..24] = [];
    var v = val;
    while v > 0 {
        tmp.push(('0' + (v % 10)) as u8);
        v /= 10;
    }
    var i: i64 = tmp.len - 1;
    while i >= 0 {
        out.push(tmp[i]);
        i--;
    }
}

fn append_i64<B>(out: B&, val: i64) {
    if val < 0 {
        out.push('-');
        append_u64(out, (-val) as u64);
    } else {
        append_u64(out, val as u64);
    }
}

fn append_f64_1<B>(out: B&, val: f64) {
    var v = val;
    if v < 0.0 {
        out.push('-');
        v = -v;
    }
    let scaled = ((v * 10.0) + 0.5) as! u64;
    let whole = scaled / 10;
    let frac = scaled % 10;
    append_u64(out, whole);
    out.push('.');
    out.push(('0' + frac) as u8);
}

fn append_f64_2<B>(out: B&, val: f64) {
    var v = val;
    if v < 0.0 {
        out.push('-');
        v = -v;
    }
    let scaled = ((v * 100.0) + 0.5) as! u64;
    let whole = scaled / 100;
    let frac = scaled % 100;
    append_u64(out, whole);
    out.push('.');
    out.push(('0' + (frac / 10)) as u8);
    out.push(('0' + (frac % 10)) as u8);
}

fn append_padded_right<B>(out: B&, s: const u8[:], width: i64) {
    out.append(s);
    var rem = width - s.len;
    while rem > 0 {
        out.push(' ');
        rem--;
    }
}

fn append_padded_left<B>(out: B&, s: const u8[:], width: i64) {
    var rem = width - s.len;
    while rem > 0 {
        out.push(' ');
        rem--;
    }
    out.append(s);
}

// Normalizes file paths so mixed Windows/POSIX separators and casing match identically.
// Strips redundant leading `./` or `.\\` segments.
fn normalize_path(path: const u8[:], out: u8[>..]&) {
    var t = trim_ascii(path);
    // Strip UTF-8 BOM (0xEF, 0xBB, 0xBF) if present
    if t.len >= 3 && t[0] == 0xEF && t[1] == 0xBB && t[2] == 0xBF {
        t = t[3..];
    }
    while t.len >= 2 && t[0] == '.' && (t[1] == '/' || t[1] == '\\') {
        t = t[2..];
    }
    for i in t.len {
        let c = t[i];
        if c == '\\' {
            out.push('/');
        } else {
            out.push(ascii_lower(c));
        }
    }
}

// Replaces all backslashes with forward slashes without modifying letter casing.
fn normalize_slashes(path: const u8[:], out: u8[>..]&) {
    var t = trim_ascii(path);
    if t.len >= 3 && t[0] == 0xEF && t[1] == 0xBB && t[2] == 0xBF {
        t = t[3..];
    }
    for i in t.len {
        let c = t[i];
        if c == '\\' {
            out.push('/');
        } else {
            out.push(c);
        }
    }
}

// Converts a path into a canonical relative path by stripping root prefixes or leading relative markers.
fn to_relative_path(path: const u8[:], root: const u8[:], out: u8[>..]&) {
    var npath: u8[>..] = [];
    normalize_path(path, npath);
    var p: const u8[:] = npath[..];

    var nroot: u8[>..] = [];
    normalize_path(root, nroot);
    var r: const u8[:] = nroot[..];
    while r.len > 0 && r[r.len - 1] == '/' {
        r = r[..r.len - 1];
    }

    if r.len > 0 && r != "." && slice_starts_with(p, r) {
        p = p[r.len..];
        while p.len > 0 && p[0] == '/' {
            p = p[1..];
        }
    }
    while p.len >= 2 && p[0] == '.' && p[1] == '/' {
        p = p[2..];
    }
    out.append(p);
}

// Checks if two paths refer to the same file.
fn paths_match(a: const u8[:], b: const u8[:]) -> bool {
    var na: u8[>..] = [];
    var nb: u8[>..] = [];
    normalize_path(a, na);
    normalize_path(b, nb);
    let sa: const u8[:] = na[..];
    let sb: const u8[:] = nb[..];
    if sa == sb { return true; }
    if sa.len == 0 || sb.len == 0 { return false; }

    // Case 1: one path is a relative suffix of the other (e.g. "auth/digest.goose" vs "/path/to/auth/digest.goose")
    if sa.len > sb.len && slice_ends_with(sa, sb) {
        let idx = sa.len - sb.len;
        guard idx > 0 && idx <= sa.len else { return false; }
        if sa[idx - 1] == '/' { return true; }
    }
    if sb.len > sa.len && slice_ends_with(sb, sa) {
        let idx = sb.len - sa.len;
        guard idx > 0 && idx <= sb.len else { return false; }
        if sb[idx - 1] == '/' { return true; }
    }

    // Case 2: cross-environment absolute paths sharing common repo suffix
    var common_len: i64 = 0;
    while common_len < sa.len && common_len < sb.len {
        let ca = sa[sa.len - 1 - common_len];
        let cb = sb[sb.len - 1 - common_len];
        if ca != cb { break; }
        common_len++;
    }
    guard common_len > 0 else { return false; }

    var valid_len: i64 = common_len;
    while valid_len > 0 {
        let a_delim = (sa.len == valid_len) || (sa[sa.len - 1 - valid_len] == '/');
        let b_delim = (sb.len == valid_len) || (sb[sb.len - 1 - valid_len] == '/');
        if a_delim && b_delim {
            let matched = sa[sa.len - valid_len..];
            if slice_index_of_byte(matched, '/') >= 0 {
                return true;
            }
            if sa.len == valid_len || sb.len == valid_len {
                return true;
            }
            break;
        }
        valid_len--;
    }

    return false;
}

// Extracts a concise display path (last 2 path segments).
fn short_display_path(path: const u8[:], out: u8[>..]&) {
    var norm: u8[>..] = [];
    normalize_path(path, norm);
    var slashes: i64 = 0;
    var i:       i64 = norm.len - 1;
    while i >= 0 {
        if norm[i] == '/' {
            slashes++;
            if slashes == 2 {
                out.append(norm[i + 1..]);
                return;
            }
        }
        i--;
    }
    out.append(norm);
}
