// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

/* shim/cov_rt.h - Self-contained branch coverage counter runtime for goose-lit.
   Splice into instrumented test builds via:
       goose build --include shim/cov_rt.h ...
   Defines crap_cov_hit so standalone instrumented tests link cleanly across
   POSIX and Windows without shim/proc.c. */

#ifndef GCRAP_COV_RT_H
#define GCRAP_COV_RT_H

#if defined(GS)

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#if !defined(_WIN32) && (defined(__GNUC__) || defined(__clang__))
#define GCRAP_COV_WEAK __attribute__((weak))
#else
#define GCRAP_COV_WEAK
#endif

#define GCRAP_COV_MAX_BRANCHES 262144

static uint64_t g_gcrap_cov_hits[GCRAP_COV_MAX_BRANCHES];
static int g_gcrap_cov_atexit = 0;

static int gcrap_cov_write_file(const char *path) {
    if (!path || !path[0]) return -1;
#ifdef _WIN32
    wchar_t wpath[4096];
    int wn = MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, 4096);
    if (wn <= 0) return -1;
    FILE *f = _wfopen(wpath, L"wb");
#else
    FILE *f = fopen(path, "wb");
#endif
    if (!f) return -1;
    for (int i = 0; i < GCRAP_COV_MAX_BRANCHES; i++) {
        if (g_gcrap_cov_hits[i] > 0) {
            fprintf(f, "id %d %llu\n", i, (unsigned long long)g_gcrap_cov_hits[i]);
        }
    }
    fclose(f);
    return 0;
}

static void gcrap_cov_atexit_cb(void) {
    const char *out_path = getenv("GCRAP_PROFILE_OUT");
    if (out_path && out_path[0]) {
        gcrap_cov_write_file(out_path);
    }
}

GCRAP_COV_WEAK void crap_cov_hit(int32_t id) {
    if (!g_gcrap_cov_atexit) {
        g_gcrap_cov_atexit = 1;
        atexit(gcrap_cov_atexit_cb);
    }
    if ((uint32_t)id < GCRAP_COV_MAX_BRANCHES) {
#if defined(__GNUC__) || defined(__clang__)
        __atomic_fetch_add(&g_gcrap_cov_hits[id], 1ULL, __ATOMIC_RELAXED);
#elif defined(_MSC_VER)
        InterlockedIncrement64((volatile LONG64 *)&g_gcrap_cov_hits[id]);
#else
        g_gcrap_cov_hits[id]++;
#endif
    }
}

#endif /* defined(GS) */

#endif /* GCRAP_COV_RT_H */
