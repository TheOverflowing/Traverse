// SPDX-License-Identifier: MIT
// Steam's CEF flags must be applied to webhelper, not steam.exe. Keeping its
// renderer in the browser process avoids Wine's cross-process presentation gap.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

int wmain(void) {
    wchar_t real[MAX_PATH];
    DWORD length = GetModuleFileNameW(NULL, real, MAX_PATH);
    if (!length || length >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(real, L'\\');
    if (!slash) return 1;
    *(slash + 1) = 0;
    const wchar_t *name = L"steamwebhelper_original.exe";
    if (wcslen(real) + wcslen(name) >= MAX_PATH) return 1;
    wcscat(real, name);

    const wchar_t *tail = GetCommandLineW();
    int quoted = 0;
    while (*tail) {
        if (*tail == L'"') quoted = !quoted;
        else if ((*tail == L' ' || *tail == L'\t') && !quoted) break;
        tail++;
    }
    while (*tail == L' ' || *tail == L'\t') tail++;
    const wchar_t *flags = L"--disable-gpu --single-process";
    size_t capacity = wcslen(real) + wcslen(flags) + wcslen(tail) + 8;
    wchar_t *command = calloc(capacity, sizeof(wchar_t));
    if (!command) return 1;
    swprintf(command, capacity, L"\"%ls\" %ls %ls", real, flags, tail);

    STARTUPINFOW startup = { .cb = sizeof(STARTUPINFOW) };
    PROCESS_INFORMATION child = {0};
    if (!CreateProcessW(real, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &child)) {
        free(command);
        return (int)GetLastError();
    }
    free(command);
    WaitForSingleObject(child.hProcess, INFINITE);
    DWORD status = 1;
    GetExitCodeProcess(child.hProcess, &status);
    CloseHandle(child.hThread);
    CloseHandle(child.hProcess);
    return (int)status;
}
