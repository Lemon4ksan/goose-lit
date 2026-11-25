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
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#endif

#if defined(__GNUC__) || defined(__clang__)
#define GCRAP_WEAK __attribute__((weak))
#else
#define GCRAP_WEAK
#endif

typedef struct {
    const uint8_t *data;
    int64_t len;
} crap_bytes_ro;

typedef struct {
    uint8_t *data;
    int64_t len;
} crap_bytes_rw;

#define GCRAP_MAX_BRANCHES 262144

static uint64_t g_crap_hits[GCRAP_MAX_BRANCHES];
static int g_crap_atexit_registered = 0;
static uint64_t g_crap_seq = 0;
static int32_t g_crap_work_next = 0;
static int32_t g_crap_stop_flag = 0;

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
    while (len > 0 &&
           (path[len - 1] == ' ' || path[len - 1] == '\t' || path[len - 1] == '\r' || path[len - 1] == '\n')) {
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
GCRAP_WEAK void crap_cov_reset(void) { memset(g_crap_hits, 0, sizeof(g_crap_hits)); }

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

#if defined(_MSC_VER)
__declspec(thread) static volatile int32_t g_last_exec_timed_out = 0;
#else
_Thread_local static volatile int32_t g_last_exec_timed_out = 0;
#endif

GCRAP_WEAK uint64_t crap_next_seq(void) {
#if defined(__GNUC__) || defined(__clang__)
    return __atomic_add_fetch(&g_crap_seq, 1ULL, __ATOMIC_RELAXED);
#elif defined(_MSC_VER)
    return (uint64_t)InterlockedIncrement64((volatile LONG64 *)&g_crap_seq);
#else
    return ++g_crap_seq;
#endif
}

GCRAP_WEAK void crap_work_reset(void) {
#if defined(__GNUC__) || defined(__clang__)
    __atomic_store_n(&g_crap_work_next, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_crap_stop_flag, 0, __ATOMIC_SEQ_CST);
#elif defined(_MSC_VER)
    InterlockedExchange((volatile LONG *)&g_crap_work_next, 0);
    InterlockedExchange((volatile LONG *)&g_crap_stop_flag, 0);
#else
    g_crap_work_next = 0;
    g_crap_stop_flag = 0;
#endif
}

GCRAP_WEAK int32_t crap_work_claim(int32_t total) {
#if defined(__GNUC__) || defined(__clang__)
    int32_t idx = __atomic_fetch_add(&g_crap_work_next, 1, __ATOMIC_SEQ_CST);
#elif defined(_MSC_VER)
    int32_t idx = (int32_t)InterlockedExchangeAdd((volatile LONG *)&g_crap_work_next, 1);
#else
    int32_t idx = g_crap_work_next++;
#endif
    return (idx >= 0 && idx < total) ? idx : -1;
}

GCRAP_WEAK void crap_atomic_set_stop(int32_t v) {
#if defined(__GNUC__) || defined(__clang__)
    __atomic_store_n(&g_crap_stop_flag, v, __ATOMIC_SEQ_CST);
#elif defined(_MSC_VER)
    InterlockedExchange((volatile LONG *)&g_crap_stop_flag, v);
#else
    g_crap_stop_flag = v;
#endif
}

GCRAP_WEAK int32_t crap_atomic_get_stop(void) {
#if defined(__GNUC__) || defined(__clang__)
    return __atomic_load_n(&g_crap_stop_flag, __ATOMIC_SEQ_CST);
#elif defined(_MSC_VER)
    return (int32_t)InterlockedCompareExchange((volatile LONG *)&g_crap_stop_flag, 0, 0);
#else
    return g_crap_stop_flag;
#endif
}

GCRAP_WEAK int32_t crap_last_exec_timed_out(void) { return g_last_exec_timed_out; }

GCRAP_WEAK int32_t crap_setenv(crap_bytes_ro key, crap_bytes_ro val) {
    char ckey[512], cval[4096];
    crap_slice_to_cstr(key, ckey, sizeof(ckey));
    crap_slice_to_cstr(val, cval, sizeof(cval));
    int has_sep = (strchr(cval, '/') != NULL || strchr(cval, '\\') != NULL);
#ifdef _WIN32
    char abs_val[4096];
    if (has_sep && GetFileAttributesA(cval) != INVALID_FILE_ATTRIBUTES &&
        GetFullPathNameA(cval, sizeof(abs_val), abs_val, NULL) > 0) {
        SetEnvironmentVariableA(ckey, abs_val);
        _putenv_s(ckey, abs_val);
    } else {
        SetEnvironmentVariableA(ckey, cval);
        _putenv_s(ckey, cval);
    }
#else
    char abs_val[4096];
    if (has_sep && realpath(cval, abs_val) != NULL) {
        setenv(ckey, abs_val, 1);
    } else {
        setenv(ckey, cval, 1);
    }
#endif
    return 0;
}

// Executes a shell command line and captures combined stdout and stderr into out_path.
// Returns process exit code (0 on success, non-zero on failure, -1 on spawn error).
GCRAP_WEAK int32_t crap_exec_to_file(crap_bytes_ro cmd, crap_bytes_ro out_path) {
    g_last_exec_timed_out = 0;
    char c_cmd[8192];
    char c_out[4096];
    crap_slice_to_cstr(cmd, c_cmd, sizeof(c_cmd));
    crap_slice_to_cstr(out_path, c_out, sizeof(c_out));
    if (!c_cmd[0] || !c_out[0]) return -1;

#ifdef _WIN32
    char full_cmd[8256];
    if (c_cmd[0] == '"' || strchr(c_cmd, '|')) {
        snprintf(full_cmd, sizeof(full_cmd), "\"%s 2>&1\"", c_cmd);
    } else {
        snprintf(full_cmd, sizeof(full_cmd), "%s 2>&1", c_cmd);
    }
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

#ifdef _WIN32
static int32_t crap_win32_spawn_and_wait_dir(wchar_t *w_cmd, const wchar_t *w_out, const wchar_t *w_dir,
                                             int32_t timeout_ms) {
    SECURITY_ATTRIBUTES sa;
    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE hOut = CreateFileW(w_out, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, &sa,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hOut == INVALID_HANDLE_VALUE) return -1;

    HANDLE hJob = CreateJobObjectW(NULL, NULL);
    if (hJob != NULL) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION jeli;
        memset(&jeli, 0, sizeof(jeli));
        jeli.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, &jeli, sizeof(jeli));
    }

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    memset(&pi, 0, sizeof(pi));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = hOut;
    si.hStdError = hOut;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    if (!CreateProcessW(NULL, w_cmd, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, w_dir, &si, &pi)) {
        if (hJob != NULL) CloseHandle(hJob);
        CloseHandle(hOut);
        return -1;
    }

    if (hJob != NULL) {
        AssignProcessToJobObject(hJob, pi.hProcess);
    }
    ResumeThread(pi.hThread);

    DWORD wait_ms = (timeout_ms > 0) ? (DWORD)timeout_ms : INFINITE;
    DWORD wait_res = WaitForSingleObject(pi.hProcess, wait_ms);
    DWORD exit_code = 1;
    if (wait_res == WAIT_TIMEOUT) {
        g_last_exec_timed_out = 1;
        if (hJob != NULL) {
            TerminateJobObject(hJob, 124);
        }
        TerminateProcess(pi.hProcess, 124);
        WaitForSingleObject(pi.hProcess, 1000);
        exit_code = 124;
    } else {
        GetExitCodeProcess(pi.hProcess, &exit_code);
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (hJob != NULL) {
        CloseHandle(hJob);
    }
    CloseHandle(hOut);
    return (int32_t)exit_code;
}

static int32_t crap_win32_spawn_and_wait(wchar_t *w_cmd, const wchar_t *w_out, int32_t timeout_ms) {
    return crap_win32_spawn_and_wait_dir(w_cmd, w_out, NULL, timeout_ms);
}

static size_t crap_append_win_quoted_arg(char *dst, size_t cap, size_t pos, const char *arg) {
    if (pos + 2 >= cap) return pos;
    if (pos > 0) dst[pos++] = ' ';
    dst[pos++] = '"';
    for (size_t i = 0; arg[i] != '\0' && pos + 2 < cap; i++) {
        if (arg[i] == '"') {
            if (pos + 3 >= cap) break;
            dst[pos++] = '\\';
        }
        dst[pos++] = arg[i];
    }
    dst[pos++] = '"';
    dst[pos] = '\0';
    return pos;
}
#endif

GCRAP_WEAK int32_t crap_exec_to_file_timeout(crap_bytes_ro cmd, crap_bytes_ro out_path, int32_t timeout_ms) {
    g_last_exec_timed_out = 0;
    if (timeout_ms <= 0) {
        return crap_exec_to_file(cmd, out_path);
    }
    char c_cmd[8192];
    char c_out[4096];
    crap_slice_to_cstr(cmd, c_cmd, sizeof(c_cmd));
    crap_slice_to_cstr(out_path, c_out, sizeof(c_out));
    if (!c_cmd[0] || !c_out[0]) return -1;

#ifdef _WIN32
    char full_cmd[8256];
    if (c_cmd[0] == '"' || strchr(c_cmd, '|')) {
        snprintf(full_cmd, sizeof(full_cmd), "cmd.exe /S /C \"%s\"", c_cmd);
    } else {
        snprintf(full_cmd, sizeof(full_cmd), "cmd.exe /C %s", c_cmd);
    }
    wchar_t w_cmd[8256];
    wchar_t w_out[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, full_cmd, -1, w_cmd, 8256) <= 0) return -1;
    if (MultiByteToWideChar(CP_UTF8, 0, c_out, -1, w_out, 4096) <= 0) return -1;
    return crap_win32_spawn_and_wait(w_cmd, w_out, timeout_ms);
#else
    int out_fd = open(c_out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) return -1;

    pid_t pid = fork();
    if (pid < 0) {
        close(out_fd);
        return -1;
    }
    if (pid == 0) {
        setpgid(0, 0);
        dup2(out_fd, STDOUT_FILENO);
        dup2(out_fd, STDERR_FILENO);
        close(out_fd);
        execl("/bin/sh", "sh", "-c", c_cmd, (char *)NULL);
        _exit(127);
    }
    close(out_fd);
    setpgid(pid, pid);

    struct timespec start_ts, now_ts, sleep_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);
    sleep_ts.tv_sec = 0;
    sleep_ts.tv_nsec = 5 * 1000 * 1000;

    int status = 0;
    for (;;) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            if (WIFEXITED(status)) return (int32_t)WEXITSTATUS(status);
            if (WIFSIGNALED(status)) return (int32_t)(128 + WTERMSIG(status));
            return (int32_t)status;
        }
        if (w < 0) return -1;

        clock_gettime(CLOCK_MONOTONIC, &now_ts);
        int64_t elapsed_ms = (int64_t)(now_ts.tv_sec - start_ts.tv_sec) * 1000LL +
                             (int64_t)(now_ts.tv_nsec - start_ts.tv_nsec) / 1000000LL;
        if (elapsed_ms >= (int64_t)timeout_ms) {
            g_last_exec_timed_out = 1;
            kill(-pid, SIGTERM);
            nanosleep(&sleep_ts, NULL);
            kill(-pid, SIGKILL);
            waitpid(pid, &status, 0);
            return 124;
        }
        nanosleep(&sleep_ts, NULL);
    }
#endif
}

// Executes a program directly with up to 3 arguments without invoking a shell.
GCRAP_WEAK int32_t crap_exec_argv_to_file(crap_bytes_ro prog, crap_bytes_ro arg1, crap_bytes_ro arg2,
                                          crap_bytes_ro arg3, crap_bytes_ro out_path, int32_t timeout_ms) {
    g_last_exec_timed_out = 0;
    char c_prog[1024], c_arg1[1024], c_arg2[1024], c_arg3[4096], c_out[4096];
    crap_slice_to_cstr(prog, c_prog, sizeof(c_prog));
    crap_slice_to_cstr(arg1, c_arg1, sizeof(c_arg1));
    crap_slice_to_cstr(arg2, c_arg2, sizeof(c_arg2));
    crap_slice_to_cstr(arg3, c_arg3, sizeof(c_arg3));
    crap_slice_to_cstr(out_path, c_out, sizeof(c_out));
    if (!c_prog[0] || !c_out[0]) return -1;

#ifdef _WIN32
    char cmd_line[8192];
    cmd_line[0] = '\0';
    size_t pos = 0;
    pos = crap_append_win_quoted_arg(cmd_line, sizeof(cmd_line), pos, c_prog);
    if (c_arg1[0]) pos = crap_append_win_quoted_arg(cmd_line, sizeof(cmd_line), pos, c_arg1);
    if (c_arg2[0]) pos = crap_append_win_quoted_arg(cmd_line, sizeof(cmd_line), pos, c_arg2);
    if (c_arg3[0]) pos = crap_append_win_quoted_arg(cmd_line, sizeof(cmd_line), pos, c_arg3);

    wchar_t w_cmd[8192];
    wchar_t w_out[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, cmd_line, -1, w_cmd, 8192) <= 0) return -1;
    if (MultiByteToWideChar(CP_UTF8, 0, c_out, -1, w_out, 4096) <= 0) return -1;
    return crap_win32_spawn_and_wait(w_cmd, w_out, timeout_ms);
#else
    int out_fd = open(c_out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) return -1;

    pid_t pid = fork();
    if (pid < 0) {
        close(out_fd);
        return -1;
    }
    if (pid == 0) {
        setpgid(0, 0);
        dup2(out_fd, STDOUT_FILENO);
        dup2(out_fd, STDERR_FILENO);
        close(out_fd);
        char *argv[6];
        int argc = 0;
        argv[argc++] = c_prog;
        if (c_arg1[0]) argv[argc++] = c_arg1;
        if (c_arg2[0]) argv[argc++] = c_arg2;
        if (c_arg3[0]) argv[argc++] = c_arg3;
        argv[argc] = NULL;
        execvp(c_prog, argv);
        _exit(127);
    }
    close(out_fd);
    setpgid(pid, pid);

    struct timespec start_ts, now_ts, sleep_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);
    sleep_ts.tv_sec = 0;
    sleep_ts.tv_nsec = 5 * 1000 * 1000;

    int status = 0;
    for (;;) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            if (WIFEXITED(status)) return (int32_t)WEXITSTATUS(status);
            if (WIFSIGNALED(status)) return (int32_t)(128 + WTERMSIG(status));
            return (int32_t)status;
        }
        if (w < 0) return -1;

        if (timeout_ms > 0) {
            clock_gettime(CLOCK_MONOTONIC, &now_ts);
            int64_t elapsed_ms = (int64_t)(now_ts.tv_sec - start_ts.tv_sec) * 1000LL +
                                 (int64_t)(now_ts.tv_nsec - start_ts.tv_nsec) / 1000000LL;
            if (elapsed_ms >= (int64_t)timeout_ms) {
                g_last_exec_timed_out = 1;
                kill(-pid, SIGTERM);
                nanosleep(&sleep_ts, NULL);
                kill(-pid, SIGKILL);
                waitpid(pid, &status, 0);
                return 124;
            }
        }
        nanosleep(&sleep_ts, NULL);
    }
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

#ifdef _WIN32
static int crap_win32_remove_tree_w(const wchar_t *wpath) {
    DWORD attrs = GetFileAttributesW(wpath);
    if (attrs == INVALID_FILE_ATTRIBUTES) return -1;
    if (!(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
        return DeleteFileW(wpath) ? 0 : -1;
    }
    wchar_t search_pat[4096];
    _snwprintf(search_pat, 4096, L"%s\\*", wpath);
    WIN32_FIND_DATAW fd;
    HANDLE hFind = FindFirstFileW(search_pat, &fd);
    if (hFind != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) continue;
            wchar_t child[4096];
            _snwprintf(child, 4096, L"%s\\%s", wpath, fd.cFileName);
            crap_win32_remove_tree_w(child);
        } while (FindNextFileW(hFind, &fd));
        FindClose(hFind);
    }
    return RemoveDirectoryW(wpath) ? 0 : -1;
}
#else
static int crap_posix_remove_tree(const char *cpath) {
    struct stat st;
    if (lstat(cpath, &st) != 0) return -1;
    if (!S_ISDIR(st.st_mode)) {
        return unlink(cpath);
    }
    DIR *d = opendir(cpath);
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
            char child[4096];
            snprintf(child, sizeof(child), "%s/%s", cpath, ent->d_name);
            crap_posix_remove_tree(child);
        }
        closedir(d);
    }
    return rmdir(cpath);
}
#endif

GCRAP_WEAK int32_t crap_remove_tree(crap_bytes_ro path) {
    char cpath[4096];
    crap_slice_to_cstr(path, cpath, sizeof(cpath));
    if (!cpath[0]) return -1;
#ifdef _WIN32
    wchar_t wpath[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, cpath, -1, wpath, 4096) <= 0) return -1;
    return (int32_t)crap_win32_remove_tree_w(wpath);
#else
    return (int32_t)crap_posix_remove_tree(cpath);
#endif
}

// Checks whether an executable exists on PATH or as an explicit path.
GCRAP_WEAK int32_t crap_has_executable(crap_bytes_ro prog) {
    char cprog[1024];
    crap_slice_to_cstr(prog, cprog, sizeof(cprog));
    if (!cprog[0]) return 0;
#ifdef _WIN32
    char out_buf[4096];
    if (SearchPathA(NULL, cprog, ".exe", sizeof(out_buf), out_buf, NULL) > 0) return 1;
    if (SearchPathA(NULL, cprog, ".cmd", sizeof(out_buf), out_buf, NULL) > 0) return 1;
    if (SearchPathA(NULL, cprog, ".bat", sizeof(out_buf), out_buf, NULL) > 0) return 1;
    return 0;
#else
    if (strchr(cprog, '/') != NULL) {
        return access(cprog, X_OK) == 0 ? 1 : 0;
    }
    const char *path_env = getenv("PATH");
    if (!path_env) return 0;
    const char *p = path_env;
    while (*p) {
        const char *colon = strchr(p, ':');
        size_t dir_len = colon ? (size_t)(colon - p) : strlen(p);
        if (dir_len > 0 && dir_len + 1 + strlen(cprog) < 4096) {
            char cand[4096];
            memcpy(cand, p, dir_len);
            cand[dir_len] = '/';
            strcpy(cand + dir_len + 1, cprog);
            if (access(cand, X_OK) == 0) return 1;
        }
        if (!colon) break;
        p = colon + 1;
    }
    return 0;
#endif
}

GCRAP_WEAK int32_t crap_host_os(void) {
#if defined(_WIN32)
    return 1;
#elif defined(__APPLE__)
    return 3;
#elif defined(__linux__)
    return 2;
#else
    return 0;
#endif
}

GCRAP_WEAK int32_t crap_host_arch(void) {
#if defined(__x86_64__) || defined(_M_X64)
    return 1;
#elif defined(__aarch64__) || defined(_M_ARM64)
    return 2;
#else
    return 0;
#endif
}

GCRAP_WEAK int32_t crap_cpu_count(void) {
#if defined(_WIN32)
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (int32_t)(si.dwNumberOfProcessors > 0 ? si.dwNumberOfProcessors : 1);
#elif defined(__APPLE__) || defined(__linux__)
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return (int32_t)(n > 0 ? n : 1);
#else
    return 1;
#endif
}

GCRAP_WEAK int64_t crap_file_mtime(crap_bytes_ro path) {
    char cpath[4096];
    crap_slice_to_cstr(path, cpath, sizeof(cpath));
    if (!cpath[0]) return -1;
#ifdef _WIN32
    wchar_t wpath[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, cpath, -1, wpath, 4096) <= 0) return -1;
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(wpath, GetFileExInfoStandard, &fad)) return -1;
    ULARGE_INTEGER uli;
    uli.LowPart = fad.ftLastWriteTime.dwLowDateTime;
    uli.HighPart = fad.ftLastWriteTime.dwHighDateTime;
    return (int64_t)uli.QuadPart;
#else
    struct stat st;
    if (stat(cpath, &st) != 0) return -1;
    return (int64_t)st.st_mtime;
#endif
}

GCRAP_WEAK int64_t crap_file_size(crap_bytes_ro path) {
    char cpath[4096];
    crap_slice_to_cstr(path, cpath, sizeof(cpath));
    if (!cpath[0]) return -1;
#ifdef _WIN32
    wchar_t wpath[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, cpath, -1, wpath, 4096) <= 0) return -1;
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(wpath, GetFileExInfoStandard, &fad)) return -1;
    ULARGE_INTEGER uli;
    uli.LowPart = fad.nFileSizeLow;
    uli.HighPart = fad.nFileSizeHigh;
    return (int64_t)uli.QuadPart;
#else
    struct stat st;
    if (stat(cpath, &st) != 0) return -1;
    return (int64_t)st.st_size;
#endif
}

GCRAP_WEAK int32_t crap_exec_in_dir_with_env(crap_bytes_ro dir, crap_bytes_ro cmd, crap_bytes_ro env_key,
                                              crap_bytes_ro env_val, crap_bytes_ro out_path, int32_t timeout_ms) {
    g_last_exec_timed_out = 0;
    char c_dir[4096], c_cmd[8192], c_key[256], c_val[4096], c_out[4096];
    crap_slice_to_cstr(dir, c_dir, sizeof(c_dir));
    crap_slice_to_cstr(cmd, c_cmd, sizeof(c_cmd));
    crap_slice_to_cstr(env_key, c_key, sizeof(c_key));
    crap_slice_to_cstr(env_val, c_val, sizeof(c_val));
    crap_slice_to_cstr(out_path, c_out, sizeof(c_out));
    if (!c_cmd[0] || !c_out[0]) return -1;

#ifdef _WIN32
    char abs_val[4096];
    const char *eff_val = c_val;
    if (c_key[0] && c_val[0] && (strchr(c_val, '/') != NULL || strchr(c_val, '\\') != NULL)) {
        if (GetFullPathNameA(c_val, sizeof(abs_val), abs_val, NULL) > 0) {
            eff_val = abs_val;
        }
    }
    char inner_cmd[16384];
    if (c_key[0]) {
        snprintf(inner_cmd, sizeof(inner_cmd), "set \"%s=%s\" && %s", c_key, eff_val, c_cmd);
    } else {
        snprintf(inner_cmd, sizeof(inner_cmd), "%s", c_cmd);
    }
    char full_cmd[16448];
    snprintf(full_cmd, sizeof(full_cmd), "cmd.exe /S /C \"%s\"", inner_cmd);

    wchar_t w_cmd[16448];
    wchar_t w_out[4096];
    wchar_t w_dir[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, full_cmd, -1, w_cmd, 16448) <= 0) return -1;
    if (MultiByteToWideChar(CP_UTF8, 0, c_out, -1, w_out, 4096) <= 0) return -1;
    const wchar_t *p_dir = NULL;
    if (c_dir[0]) {
        if (MultiByteToWideChar(CP_UTF8, 0, c_dir, -1, w_dir, 4096) <= 0) return -1;
        p_dir = w_dir;
    }
    return crap_win32_spawn_and_wait_dir(w_cmd, w_out, p_dir, timeout_ms);
#else
    char abs_val[4096];
    const char *eff_val = c_val;
    if (c_key[0] && c_val[0] && c_val[0] != '/' && (strchr(c_val, '/') != NULL)) {
        char cwd[4096];
        if (getcwd(cwd, sizeof(cwd)) != NULL) {
            snprintf(abs_val, sizeof(abs_val), "%s/%s", cwd, c_val);
            eff_val = abs_val;
        }
    }
    int out_fd = open(c_out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) return -1;

    pid_t pid = fork();
    if (pid < 0) {
        close(out_fd);
        return -1;
    }
    if (pid == 0) {
        setpgid(0, 0);
        if (c_dir[0]) {
            if (chdir(c_dir) != 0) _exit(127);
        }
        if (c_key[0]) {
            setenv(c_key, eff_val, 1);
        }
        dup2(out_fd, STDOUT_FILENO);
        dup2(out_fd, STDERR_FILENO);
        close(out_fd);
        execl("/bin/sh", "sh", "-c", c_cmd, (char *)NULL);
        _exit(127);
    }
    close(out_fd);
    setpgid(pid, pid);

    struct timespec start_ts, now_ts, sleep_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);
    sleep_ts.tv_sec = 0;
    sleep_ts.tv_nsec = 5 * 1000 * 1000;

    int status = 0;
    for (;;) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            if (WIFEXITED(status)) return (int32_t)WEXITSTATUS(status);
            if (WIFSIGNALED(status)) return (int32_t)(128 + WTERMSIG(status));
            return (int32_t)status;
        }
        if (w < 0) return -1;

        if (timeout_ms > 0) {
            clock_gettime(CLOCK_MONOTONIC, &now_ts);
            int64_t elapsed_ms = (int64_t)(now_ts.tv_sec - start_ts.tv_sec) * 1000LL +
                                 (int64_t)(now_ts.tv_nsec - start_ts.tv_nsec) / 1000000LL;
            if (elapsed_ms >= (int64_t)timeout_ms) {
                g_last_exec_timed_out = 1;
                kill(-pid, SIGTERM);
                nanosleep(&sleep_ts, NULL);
                kill(-pid, SIGKILL);
                waitpid(pid, &status, 0);
                return 124;
            }
        }
        nanosleep(&sleep_ts, NULL);
    }
#endif
}

GCRAP_WEAK int32_t crap_exec_with_env_to_file(crap_bytes_ro cmd, crap_bytes_ro env_key, crap_bytes_ro env_val,
                                               crap_bytes_ro out_path, int32_t timeout_ms) {
    crap_bytes_ro empty_dir = {NULL, 0};
    return crap_exec_in_dir_with_env(empty_dir, cmd, env_key, env_val, out_path, timeout_ms);
}

GCRAP_WEAK int64_t crap_abs_path(crap_bytes_ro path, crap_bytes_rw out) {
    if (!path.data || path.len <= 0 || !out.data || out.len <= 0) return -1;
    char c_path[4096];
    crap_slice_to_cstr(path, c_path, sizeof(c_path));
    if (!c_path[0]) return -1;
#ifdef _WIN32
    wchar_t w_in[4096];
    wchar_t w_abs[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, c_path, -1, w_in, 4096) <= 0) return -1;
    DWORD wn = GetFullPathNameW(w_in, 4096, w_abs, NULL);
    if (wn == 0 || wn >= 4096) return -1;
    char utf8[4096];
    int n = WideCharToMultiByte(CP_UTF8, 0, w_abs, -1, utf8, (int)sizeof(utf8), NULL, NULL);
    if (n <= 1) return -1;
    int64_t len = (int64_t)(n - 1);
    if (len > out.len) return -1;
    memcpy(out.data, utf8, (size_t)len);
    return len;
#else
    char resolved[4096];
    const char *src = NULL;
    if (realpath(c_path, resolved) != NULL) {
        src = resolved;
    } else if (c_path[0] == '/') {
        src = c_path;
    } else {
        char cwd[4096];
        if (getcwd(cwd, sizeof(cwd)) == NULL) return -1;
        int written = snprintf(resolved, sizeof(resolved), "%s/%s", cwd, c_path);
        if (written <= 0 || (size_t)written >= sizeof(resolved)) return -1;
        src = resolved;
    }
    int64_t len = (int64_t)strlen(src);
    if (len <= 0 || len > out.len) return -1;
    memcpy(out.data, src, (size_t)len);
    return len;
#endif
}
