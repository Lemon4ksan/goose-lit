// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

/* shim/alloc_hook.h - Compile-time interposition for the goose-lit runtime
   allocation counter (shim/alloc_count.c).

   Splice this header into the generated C of an instrumented build only:

       goose build --cc gcc -O2 --include %alloc_hook -o out.exe t.goose

   When included into non-Goose C translation units, the #if defined(GS) guard
   makes this header a complete no-op. If shim/prof_hook.h is already active,
   it forwards pool events to lit_alloc_on_pool_* automatically so both headers
   compose cleanly without macro redefinition. */

#ifndef LIT_ALLOC_HOOK_H
#define LIT_ALLOC_HOOK_H

#if defined(GS) && !defined(LIT_ALLOC_SHIM_INTERNAL) && !defined(LIT_MEM_HOOK_INTERPOSED)
#define LIT_MEM_HOOK_INTERPOSED 1

void lit_alloc_on_pool_alloc(int64_t elems);
void lit_alloc_on_pool_free(void);

static inline int64_t lit_ac_hook_place(gs_rref nodes, void *tree, int64_t len, int64_t cnt, const gs_loc *at) {
    lit_alloc_on_pool_alloc(cnt);
    return gs_slice_pool_place(nodes, tree, len, cnt, at);
}

static inline void lit_ac_hook_free(gs_rref nodes, void *tree, int64_t idx, int64_t cnt, const gs_loc *at) {
    lit_alloc_on_pool_free();
    gs_slice_pool_free(nodes, tree, idx, cnt, at);
}

static inline int64_t lit_ac_hook_regrow(gs_rref nodes, void *tree, int64_t len, int64_t idx, int64_t ol, int64_t cnt,
                                         const gs_loc *at) {
    lit_alloc_on_pool_alloc(cnt > ol ? (cnt - ol) : 0);
    return gs_slice_pool_regrow(nodes, tree, len, idx, ol, cnt, at);
}

static inline int64_t lit_ac_hook_spans_alloc(uint8_t *base, int64_t *n, uint8_t **top, int64_t len, int64_t cnt) {
    lit_alloc_on_pool_alloc(cnt);
    return gs_spans_alloc(base, n, top, len, cnt);
}

static inline int64_t lit_ac_hook_spans_regrow(uint8_t *base, int64_t *n, uint8_t **top, int64_t len, int64_t idx,
                                               int64_t ol, int64_t cnt) {
    lit_alloc_on_pool_alloc(cnt > ol ? (cnt - ol) : 0);
    return gs_spans_regrow(base, n, top, len, idx, ol, cnt);
}

static inline void lit_ac_hook_spans_free(uint8_t *base, int64_t *n, uint8_t **top, int64_t idx, int64_t cnt) {
    lit_alloc_on_pool_free();
    gs_spans_free(base, n, top, idx, cnt);
}

#define gs_slice_pool_place(nodes, tree, len, cnt, at) lit_ac_hook_place(nodes, tree, len, cnt, at)
#define gs_slice_pool_free(nodes, tree, idx, cnt, at) lit_ac_hook_free(nodes, tree, idx, cnt, at)
#define gs_slice_pool_regrow(nodes, tree, len, idx, ol, cnt, at) lit_ac_hook_regrow(nodes, tree, len, idx, ol, cnt, at)
#define gs_spans_alloc(base, n, top, len, cnt) lit_ac_hook_spans_alloc(base, n, top, len, cnt)
#define gs_spans_regrow(base, n, top, len, idx, ol, cnt) lit_ac_hook_spans_regrow(base, n, top, len, idx, ol, cnt)
#define gs_spans_free(base, n, top, idx, cnt) lit_ac_hook_spans_free(base, n, top, idx, cnt)

#endif /* defined(GS) && !defined(LIT_ALLOC_SHIM_INTERNAL) && !defined(LIT_MEM_HOOK_INTERPOSED) */

#endif /* LIT_ALLOC_HOOK_H */
