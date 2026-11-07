#ifdef _WIN32
#define _WIN32_WINNT 0x0A00
#define NTDDI_VERSION 0x0A000006
#include <windows.h>
#else
#define _DEFAULT_SOURCE
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static int child(void) {
    char input[64];
#ifdef _WIN32
    // CI redirects the parent's standard handles. Bind the child CRT to its
    // attached console instead of those inherited redirected streams.
    FILE *reopened = NULL;
    if (freopen_s(&reopened, "CONIN$", "r", stdin) != 0 ||
        freopen_s(&reopened, "CONOUT$", "w", stdout) != 0 ||
        freopen_s(&reopened, "CONOUT$", "w", stderr) != 0) return 7;
    // ConPTY's input consumer must be attached before the parent sends keys.
    if (printf("MYTERM_CHILD_READY\n") < 0 || fflush(stdout) != 0) return 6;
#endif
    if (!fgets(input, sizeof(input), stdin)) {
        fprintf(stderr, "Child stdin read failed\n");
        return 2;
    }
    if (strcmp(input, "PTY_INPUT\n") != 0) {
        fprintf(stderr, "Child input mismatch:");
        for (size_t i = 0; input[i]; ++i) fprintf(stderr, " %02x", (unsigned char)input[i]);
        fprintf(stderr, "\n");
        return 2;
    }
#ifdef _WIN32
    CONSOLE_SCREEN_BUFFER_INFO info;
    int cols = 0, rows = 0;
    ULONGLONG deadline = GetTickCount64() + 2000;
    // Resize and input use separate ConPTY channels; observe the applied geometry.
    do {
        if (!GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info)) return 3;
        cols = info.srWindow.Right - info.srWindow.Left + 1;
        rows = info.srWindow.Bottom - info.srWindow.Top + 1;
        if (cols == 101 && rows == 31) break;
        Sleep(10);
    } while (GetTickCount64() < deadline);
#else
    struct winsize size;
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) || tcgetpgrp(STDIN_FILENO) != getpgrp()) return 3;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0) return 4;
    int cols = size.ws_col, rows = size.ws_row;
#endif
    printf("MYTERM_NATIVE_OK %d %d\n", cols, rows);
    return cols == 101 && rows == 31 ? 0 : 5;
}

#ifdef _WIN32
struct output { HANDLE pipe; HANDLE ready; char bytes[8192]; size_t used; DWORD error; DWORD signalError; int overflow; };
static DWORD WINAPI drain(LPVOID context) {
    struct output *out = context;
    char chunk[1024];
    DWORD count;
    while (ReadFile(out->pipe, chunk, sizeof(chunk), &count, NULL) && count) {
        if (out->used + count >= sizeof(out->bytes)) out->overflow = 1;
        else {
            memcpy(out->bytes + out->used, chunk, count); out->used += count;
            out->bytes[out->used] = '\0';
            if (strstr(out->bytes, "MYTERM_CHILD_READY")) {
                if (!SetEvent(out->ready)) out->signalError = GetLastError();
            }
        }
    }
    out->error = GetLastError();
    out->bytes[out->used] = '\0';
    return 0;
}
static int probe(const char *executable) {
    (void)executable;
    HANDLE inputRead = NULL, inputWrite = NULL, outputRead = NULL, outputWrite = NULL, reader = NULL;
    HPCON console = NULL;
    STARTUPINFOEXW startup = {0};
    PROCESS_INFORMATION process = {0};
    SIZE_T bytes = 0;
    int initialized = 0, result = 1;
    DWORD code = 1, written;
    struct output output = {0};
    wchar_t path[32768], command[32780];
    DWORD length = GetModuleFileNameW(NULL, path, 32768);
    if (!length || length >= 32768) goto cleanup;
    if (swprintf(command, 32780, L"\"%ls\" --child", path) < 0) goto cleanup;
    if (!CreatePipe(&inputRead, &inputWrite, NULL, 0) || !CreatePipe(&outputRead, &outputWrite, NULL, 0)) goto cleanup;
    COORD initial = {80, 24}, resized = {101, 31};
    HRESULT hr = CreatePseudoConsole(initial, inputRead, outputWrite, 0, &console);
    if (FAILED(hr)) { fprintf(stderr, "CreatePseudoConsole HRESULT: 0x%lx\n", (unsigned long)hr); goto cleanup; }
    output.pipe = outputRead;
    output.ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!output.ready) goto cleanup;
    reader = CreateThread(NULL, 0, drain, &output, 0, NULL);
    if (!reader) goto cleanup;
    InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
    startup.lpAttributeList = malloc(bytes);
    if (!startup.lpAttributeList) goto cleanup;
    if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &bytes)) goto cleanup;
    initialized = 1;
    if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console, sizeof(console), NULL, NULL)) goto cleanup;
    startup.StartupInfo.cb = sizeof(startup);
    if (!CreateProcessW(path, command, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &startup.StartupInfo, &process)) goto cleanup;
    CloseHandle(inputRead); inputRead = NULL;
    CloseHandle(outputWrite); outputWrite = NULL;
    HANDLE readiness[] = {output.ready, process.hProcess};
    DWORD ready = WaitForMultipleObjects(2, readiness, FALSE, 5000);
    if (ready != WAIT_OBJECT_0) {
        fprintf(stderr, "Child readiness wait failed: %lu\n", ready);
        goto cleanup;
    }
    if (FAILED(ResizePseudoConsole(console, resized))) goto cleanup;
    if (!WriteFile(inputWrite, "PTY_INPUT\r\n", 11, &written, NULL) || written != 11) goto cleanup;
    if (WaitForSingleObject(process.hProcess, 10000) != WAIT_OBJECT_0) { fprintf(stderr, "Child timeout\n"); goto cleanup; }
    if (!GetExitCodeProcess(process.hProcess, &code) || code != 0) goto cleanup;
    result = 0;
cleanup:
    if (result) {
        DWORD error = GetLastError();
        if (process.hProcess && !GetExitCodeProcess(process.hProcess, &code)) fprintf(stderr, "GetExitCodeProcess failed: %lu\n", GetLastError());
        fprintf(stderr, "ConPTY failure, Win32 error=%lu, child exit=%lu\n", error, code);
    }
    if (process.hProcess && WaitForSingleObject(process.hProcess, 0) == WAIT_TIMEOUT) {
        if (!TerminateProcess(process.hProcess, 1)) fprintf(stderr, "TerminateProcess failed: %lu\n", GetLastError());
        if (WaitForSingleObject(process.hProcess, 5000) != WAIT_OBJECT_0) result = 1;
    }
    if (inputRead) CloseHandle(inputRead);
    if (outputWrite) CloseHandle(outputWrite);
    // ConPTY may emit a final frame during close; keep the reader draining it.
    if (console) ClosePseudoConsole(console);
    if (inputWrite) CloseHandle(inputWrite);
    if (reader) {
        if (WaitForSingleObject(reader, 5000) != WAIT_OBJECT_0) {
            fprintf(stderr, "Output drain timeout\n");
            // Process exit releases handles without leaving a thread referencing stack data.
            ExitProcess(1);
        }
        printf("%s\n", output.bytes);
        if (output.overflow || output.signalError || (output.error != ERROR_BROKEN_PIPE && output.error != ERROR_SUCCESS) || !strstr(output.bytes, "MYTERM_NATIVE_OK 101 31")) result = 1;
        CloseHandle(reader);
    } else result = 1;
    if (output.ready) CloseHandle(output.ready);
    if (outputRead) CloseHandle(outputRead);
    if (process.hThread) CloseHandle(process.hThread);
    if (process.hProcess) CloseHandle(process.hProcess);
    if (initialized) DeleteProcThreadAttributeList(startup.lpAttributeList);
    free(startup.lpAttributeList);
    return result;
}
#else
#include <time.h>
static double now(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) { perror("clock_gettime"); exit(1); }
    return time.tv_sec + time.tv_nsec / 1000000000.0;
}
static int probe(const char *executable) {
    int master, status = 0, exited = 0, result = 1;
    struct winsize size = {.ws_row = 24, .ws_col = 80};
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) { perror("forkpty"); return 1; }
    if (pid == 0) { execlp(executable, executable, "--child", (char *)NULL); perror("execlp"); _exit(127); }
    size.ws_row = 31; size.ws_col = 101;
    char output[8192] = {0};
    size_t used = 0;
    double deadline = now() + 10;
    if (ioctl(master, TIOCSWINSZ, &size) != 0 || write(master, "PTY_INPUT\n", 10) != 10) { perror("PTY setup"); goto cleanup; }
    while (now() < deadline) {
        fd_set reads;
        FD_ZERO(&reads); FD_SET(master, &reads);
        struct timeval timeout = {.tv_sec = 0, .tv_usec = 100000};
        int ready = select(master + 1, &reads, NULL, NULL, &timeout);
        if (ready < 0) { if (errno == EINTR) continue; perror("select"); goto cleanup; }
        int drained = 0;
        if (ready > 0) {
            ssize_t count = read(master, output + used, sizeof(output) - used - 1);
            if (count < 0 && errno != EIO && errno != EINTR) { perror("read"); goto cleanup; }
            drained = count == 0 || (count < 0 && errno == EIO);
            if (count > 0) { used += (size_t)count; if (used == sizeof(output) - 1) { fprintf(stderr, "Output overflow\n"); goto cleanup; } }
        }
        if (!exited) {
            pid_t waited = waitpid(pid, &status, WNOHANG);
            if (waited < 0) { perror("waitpid"); goto cleanup; }
            exited = waited == pid;
        }
        if (exited && drained && !strstr(output, "MYTERM_NATIVE_OK 101 31")) {
            if (WIFEXITED(status)) fprintf(stderr, "Child exit=%d; marker missing\n", WEXITSTATUS(status));
            else if (WIFSIGNALED(status)) fprintf(stderr, "Child signal=%d; marker missing\n", WTERMSIG(status));
            goto cleanup;
        }
        if (exited && strstr(output, "MYTERM_NATIVE_OK 101 31")) {
            result = WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
            goto cleanup;
        }
    }
    fprintf(stderr, "PTY probe timed out or marker missing\n");
cleanup:
    if (!exited) {
        if (kill(pid, SIGKILL) != 0 && errno != ESRCH) perror("kill");
        while (waitpid(pid, &status, 0) < 0) { if (errno != EINTR) { perror("waitpid cleanup"); break; } }
    }
    close(master);
    printf("%s\n", output);
    return result;
}
#endif
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--child") == 0) return child();
    int result = probe(argv[0]);
    printf("native PTY probe: %s\n", result == 0 ? "PASS" : "FAIL");
    return result;
}
