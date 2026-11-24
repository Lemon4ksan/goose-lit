// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// shim/alloc_count.c - Runtime allocation counter shim for goose-lit.
//
// Goose has no heap: growable arrays bump-allocate on per-thread data stacks.
// The runtime's only function-call allocator paths are the slice-pool span
// primitives (gs_slice_pool_place/regrow/free, gs_spans_alloc/regrow/free).
// This shim counts those calls when the program is built with shim/alloc_hook.h
// (or shim/prof_hook.h), plus explicit lit_alloc_note taps and data-stack
// growth sampling through lit_alloc_mark / lit_alloc_growth.
//
// Zero-overhead when disabled: production builds never splice alloc_hook.h,
// so generated C calls runtime primitives directly. Instrumented builds gate
// counting on the enabled flag (lit_alloc_reset enables, lit_alloc_disable off).

#define LIT_ALLOC_SHIM_INTERNAL 1

#include "goose.h"

static uint64_t g_lit_ac_events = 0;
static uint64_t g_lit_ac_bytes = 0;
static uint64_t g_lit_ac_frees = 0;
static uint8_t g_lit_ac_enabled = 0;

void lit_alloc_on_pool_alloc(int64_t elems) {
    if (!g_lit_ac_enabled) return;
    g_lit_ac_events++;
    if (elems > 0) g_lit_ac_bytes += (uint64_t)elems;
}

void lit_alloc_on_pool_free(void) {
    if (!g_lit_ac_enabled) return;
    g_lit_ac_frees++;
}

void lit_alloc_reset(void) {
    g_lit_ac_events = 0;
    g_lit_ac_bytes = 0;
    g_lit_ac_frees = 0;
    g_lit_ac_enabled = 1;
}

void lit_alloc_disable(void) { g_lit_ac_enabled = 0; }

uint64_t lit_alloc_events(void) { return g_lit_ac_events; }

uint64_t lit_alloc_bytes(void) { return g_lit_ac_bytes; }

uint64_t lit_alloc_frees(void) { return g_lit_ac_frees; }

void lit_alloc_note(int64_t bytes) { lit_alloc_on_pool_alloc(bytes); }

// Bump watermark (current top) of the data stack that owns `probe`.
uint64_t lit_alloc_mark(gs_rref probe) { return (uint64_t)(uintptr_t)probe.stk->top; }

// Net growth of that data stack since `mark` in bytes.
int64_t lit_alloc_growth(gs_rref probe, uint64_t mark) { return (int64_t)((uint64_t)(uintptr_t)probe.stk->top - mark); }
