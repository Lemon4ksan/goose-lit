// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Lemon4ksan

// shim/proc.c - Process execution and branch probe counter runtime for goose-crap.
// Conforms to Goose slice ABI (spec section 7.10).

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define WIN32_LEAN_AND_MEAN

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <sys/wait.h>
#endif

#if defined(__GNUC__) || defined(__clang__)
#define GCRAP_WEAK __attribute__((weak))
#else
#define GCRAP_WEAK
#endif

#pragma pack(push, 1)
typedef struct { const uint8_t *data; int64_t len; } crap_bytes_ro;
typedef struct { uint8_t *data; int64_t len; } crap_bytes_rw;
#pragma pack(pop)

#define GCRAP_MAX_BRANCHES 65536

static uint64_t g_crap_hits[GCRAP_MAX_BRANCHES];
static int g_crap_atexit_registered = 0;

static void crap_slice_to_cstr(crap_bytes_ro s, char *out, size_t max_out) {
    if (!s.data || s.len <= 0 || max_out == 0) {
        if (max_out > 0) out[0] = '\0';
        return;
    }
    size_t n = (size_t)s.len < (max_out - 1) ? (size_t)s.len : (max_out - 1);
    memcpy(out, s.data, n);
    out[n] = '\0';
}

static int crap_write_hits_to_file(const char *path) {
    if (!path || !path[0]) return -1;
    char clean_path[4096];
    size_t len = strlen(path);
    while (len > 0 && (path[len - 1] == ' ' || path[len - 1] == '\t' || path[len - 1] == '\r' || path[len - 1] == '\n')) {
        len--;
    }
    if (len == 0 || len >= sizeof(clean_path)) return -1;
    memcpy(clean_path, path, len);
    clean_path[len] = '\0';

#ifdef _WIN32
    wchar_t wpath[4096];
    int wn = MultiByteToWideChar(CP_UTF8, 0, clean_path, -1, wpath, 4096);
    if (wn <= 0) return -1;
    FILE *f = _wfopen(wpath, L"wb");
#else
    FILE *f = fopen(clean_path, "wb");
#endif
    if (!f) return -1;
    for (int i = 0; i < GCRAP_MAX_BRANCHES; i++) {
        if (g_crap_hits[i] > 0) {
            fprintf(f, "id %d %llu\n", i, (unsigned long long)g_crap_hits[i]);
        }
    }
    fclose(f);
    return 0;
}

static void crap_atexit_dump(void) {
    const char *env_path = getenv("GCRAP_PROFILE_OUT");
    if (env_path && env_path[0]) {
        crap_write_hits_to_file(env_path);
    }
}

// Records a branch hit at runtime. Safe under -O2 because extern calls are observable.
GCRAP_WEAK void crap_cov_hit(int32_t id) {
    if (!g_crap_atexit_registered) {
        g_crap_atexit_registered = 1;
        atexit(crap_atexit_dump);
    }
    if ((uint32_t)id < GCRAP_MAX_BRANCHES) {
#if defined(__GNUC__) || defined(__clang__)
        __atomic_fetch_add(&g_crap_hits[id], 1ULL, __ATOMIC_RELAXED);
#elif defined(_MSC_VER)
        InterlockedIncrement64((volatile LONG64 *)&g_crap_hits[id]);
#else
        g_crap_hits[id]++;
#endif
    }
}

// Resets all in-memory branch counters to zero.
GCRAP_WEAK void crap_cov_reset(void) {
    memset(g_crap_hits, 0, sizeof(g_crap_hits));
}

// Reads the current hit count for a specific branch ID.
GCRAP_WEAK int64_t crap_cov_get(int32_t id) {
    if ((uint32_t)id < GCRAP_MAX_BRANCHES) {
        return (int64_t)g_crap_hits[id];
    }
    return 0;
}

// Writes non-zero branch counters to the specified file path.
GCRAP_WEAK int32_t crap_cov_dump(crap_bytes_ro path) {
    char cpath[4096];
    crap_slice_to_cstr(path, cpath, sizeof(cpath));
    return (int32_t)crap_write_hits_to_file(cpath);
}

// Executes a shell command line and captures combined stdout and stderr into out_path.
// Returns process exit code (0 on success, non-zero on failure, -1 on spawn error).
GCRAP_WEAK int32_t crap_exec_to_file(crap_bytes_ro cmd, crap_bytes_ro out_path) {
    char c_cmd[8192];
    char c_out[4096];
    crap_slice_to_cstr(cmd, c_cmd, sizeof(c_cmd));
    crap_slice_to_cstr(out_path, c_out, sizeof(c_out));
    if (!c_cmd[0] || !c_out[0]) return -1;

#ifdef _WIN32
    char full_cmd[8256];
    snprintf(full_cmd, sizeof(full_cmd), "%s 2>&1", c_cmd);
    wchar_t w_cmd[8256];
    wchar_t w_out[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, full_cmd, -1, w_cmd, 8256) <= 0) return -1;
    if (MultiByteToWideChar(CP_UTF8, 0, c_out, -1, w_out, 4096) <= 0) return -1;

    FILE *pipe = _wpopen(w_cmd, L"rb");
    if (!pipe) return -1;
    FILE *out_f = _wfopen(w_out, L"wb");
    if (!out_f) {
        _pclose(pipe);
        return -1;
    }
    uint8_t buf[4096];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof(buf), pipe)) > 0) {
        fwrite(buf, 1, n, out_f);
    }
    fclose(out_f);
    int rc = _pclose(pipe);
    return (int32_t)rc;
#else
    char full_cmd[8256];
    snprintf(full_cmd, sizeof(full_cmd), "%s 2>&1", c_cmd);
    FILE *pipe = popen(full_cmd, "r");
    if (!pipe) return -1;
    FILE *out_f = fopen(c_out, "wb");
    if (!out_f) {
        pclose(pipe);
        return -1;
    }
    uint8_t buf[4096];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof(buf), pipe)) > 0) {
        fwrite(buf, 1, n, out_f);
    }
    fclose(out_f);
    int status = pclose(pipe);
    if (WIFEXITED(status)) {
        return (int32_t)WEXITSTATUS(status);
    }
    return (int32_t)status;
#endif
}

// Deletes a file on disk. Returns 0 on success, non-zero on failure.
GCRAP_WEAK int32_t crap_file_delete(crap_bytes_ro path) {
    char cpath[4096];
    crap_slice_to_cstr(path, cpath, sizeof(cpath));
    if (!cpath[0]) return -1;
#ifdef _WIN32
    wchar_t wpath[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, cpath, -1, wpath, 4096) <= 0) return -1;
    return DeleteFileW(wpath) ? 0 : -1;
#else
    return unlink(cpath);
#endif
}
