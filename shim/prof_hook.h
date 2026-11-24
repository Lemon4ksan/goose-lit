// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

/* shim/prof_hook.h - Compile-time interposition for the goose-lit stage
   profiler, three-channel memory tracker (shim/profiler.c), and runtime
   allocation counter (shim/alloc_count.c).

   Splice this header into the generated C of an instrumented build:

       goose build -O2 --include %prof_hook <target.goose> -o <out>

   When included into non-Goose C translation units (such as shim/profiler.c),
   the #if defined(GS) && !defined(LIT_PROF_SHIM_INTERNAL) guard makes this
   header a complete no-op. */

#ifndef LIT_PROF_HOOK_H
#define LIT_PROF_HOOK_H

#if defined(GS) && !defined(LIT_PROF_SHIM_INTERNAL)

#include <stddef.h>

#if !defined(__GNUC__) && !defined(__clang__)
#ifndef __builtin_expect
#define __builtin_expect(x, v) (x)
#endif
#endif

extern uint8_t g_prof_mem_active;

typedef void (*lit_prof_stack_query_fn_t)(void **out_stks_base, int32_t *out_stride, int32_t *out_top_off,
                                          int32_t *out_nstks);

void lit_prof_set_stack_query_fn(lit_prof_stack_query_fn_t fn);
void lit_prof_bind_stacks(void *stks_base, int32_t elem_stride, int32_t top_offset, int32_t nstks);
void lit_prof_gs_peak_tap(int32_t idx, uint8_t *cur_top);
void lit_prof_on_pool_alloc(int64_t bytes);
void lit_prof_on_pool_regrow(int64_t bytes);
void lit_prof_on_pool_free(void);

void lit_alloc_on_pool_alloc(int64_t elems);
void lit_alloc_on_pool_free(void);

static void lit_prof_query_gs_stacks(void **out_stks_base, int32_t *out_stride, int32_t *out_top_off,
                                     int32_t *out_nstks) {
    *out_stks_base = (void *)gs_stks;
    *out_stride = (int32_t)sizeof(gs_stack);
    *out_top_off = (int32_t)offsetof(gs_stack, top);
    *out_nstks = (int32_t)gs_nstks;
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((constructor)) static void lit_prof_register_stack_hook(void) {
    lit_prof_set_stack_query_fn(lit_prof_query_gs_stacks);
}
#endif

static inline gs_stack *lit_prof_gs_tap(gs_stack *stks, int64_t nstks, int32_t idx) {
    if (__builtin_expect(g_prof_mem_active != 0, 0)) {
        lit_prof_bind_stacks((void *)stks, (int32_t)sizeof(gs_stack), (int32_t)offsetof(gs_stack, top), (int32_t)nstks);
        lit_prof_gs_peak_tap(idx, stks[idx].top);
    }
    return &stks[idx];
}

#undef GS
#define GS(i) lit_prof_gs_tap(gs_stks, gs_nstks, (int32_t)(i))

#ifndef LIT_MEM_HOOK_INTERPOSED
#define LIT_MEM_HOOK_INTERPOSED 1

static inline int64_t lit_prof_hook_place(gs_rref nodes, void *tree, int64_t len, int64_t cnt, const gs_loc *at) {
    lit_alloc_on_pool_alloc(cnt);
    if (__builtin_expect(g_prof_mem_active != 0, 0)) {
        lit_prof_on_pool_alloc(cnt);
    }
    return gs_slice_pool_place(nodes, tree, len, cnt, at);
}

static inline void lit_prof_hook_free(gs_rref nodes, void *tree, int64_t idx, int64_t cnt, const gs_loc *at) {
    lit_alloc_on_pool_free();
    if (__builtin_expect(g_prof_mem_active != 0, 0)) {
        lit_prof_on_pool_free();
    }
    gs_slice_pool_free(nodes, tree, idx, cnt, at);
}

static inline int64_t lit_prof_hook_regrow(gs_rref nodes, void *tree, int64_t len, int64_t idx, int64_t ol, int64_t cnt,
                                           const gs_loc *at) {
    lit_alloc_on_pool_alloc(cnt > ol ? (cnt - ol) : 0);
    if (__builtin_expect(g_prof_mem_active != 0, 0)) {
        if (cnt > ol) lit_prof_on_pool_regrow(cnt - ol);
    }
    return gs_slice_pool_regrow(nodes, tree, len, idx, ol, cnt, at);
}

static inline int64_t lit_prof_hook_spans_alloc(uint8_t *base, int64_t *n, uint8_t **top, int64_t len, int64_t cnt) {
    lit_alloc_on_pool_alloc(cnt);
    if (__builtin_expect(g_prof_mem_active != 0, 0)) {
        lit_prof_on_pool_alloc(cnt);
    }
    return gs_spans_alloc(base, n, top, len, cnt);
}

static inline int64_t lit_prof_hook_spans_regrow(uint8_t *base, int64_t *n, uint8_t **top, int64_t len, int64_t idx,
                                                 int64_t ol, int64_t cnt) {
    lit_alloc_on_pool_alloc(cnt > ol ? (cnt - ol) : 0);
    if (__builtin_expect(g_prof_mem_active != 0, 0)) {
        if (cnt > ol) lit_prof_on_pool_regrow(cnt - ol);
    }
    return gs_spans_regrow(base, n, top, len, idx, ol, cnt);
}

static inline void lit_prof_hook_spans_free(uint8_t *base, int64_t *n, uint8_t **top, int64_t idx, int64_t cnt) {
    lit_alloc_on_pool_free();
    if (__builtin_expect(g_prof_mem_active != 0, 0)) {
        lit_prof_on_pool_free();
    }
    gs_spans_free(base, n, top, idx, cnt);
}

#define gs_slice_pool_place(nodes, tree, len, cnt, at) lit_prof_hook_place(nodes, tree, len, cnt, at)
#define gs_slice_pool_free(nodes, tree, idx, cnt, at) lit_prof_hook_free(nodes, tree, idx, cnt, at)
#define gs_slice_pool_regrow(nodes, tree, len, idx, ol, cnt, at)                                                       \
    lit_prof_hook_regrow(nodes, tree, len, idx, ol, cnt, at)
#define gs_spans_alloc(base, n, top, len, cnt) lit_prof_hook_spans_alloc(base, n, top, len, cnt)
#define gs_spans_regrow(base, n, top, len, idx, ol, cnt) lit_prof_hook_spans_regrow(base, n, top, len, idx, ol, cnt)
#define gs_spans_free(base, n, top, idx, cnt) lit_prof_hook_spans_free(base, n, top, idx, cnt)

#endif /* LIT_MEM_HOOK_INTERPOSED */

#if defined(LIT_PROF_STRIP)
#if defined(__GNUC__) || defined(__clang__)
extern inline __attribute__((gnu_inline)) gs_i64 lit_prof_enter_noop(sl_u8 name) {
    (void)name;
    return -1;
}
extern inline __attribute__((gnu_inline)) void lit_prof_leave_noop(gs_i64 span_tok) { (void)span_tok; }
#define lit_prof_enter(name) lit_prof_enter_noop(name)
#define lit_prof_leave(tok) lit_prof_leave_noop(tok)
#endif
#endif

#endif /* defined(GS) && !defined(LIT_PROF_SHIM_INTERNAL) */

#endif /* LIT_PROF_HOOK_H */
