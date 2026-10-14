// SPDX-License-Identifier: MIT
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define COBJMACROS
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <shobjidl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define PATH_CAPACITY 32768

typedef char *(CDECL *wine_unix_name_fn)(const wchar_t *);
typedef const char *(CDECL *wine_version_fn)(void);

typedef struct {
    wchar_t windows[PATH_CAPACITY];
    char *unix_name;
} ImagePath;

typedef struct {
    ImagePath paths[5];
    unsigned path_count;
    BOOL directory;
    wine_unix_name_fn unix_name;
    BOOL mac_activation_message;
    HWND window;
    DWORD pid;
    unsigned long long area;
} WindowMatch;

static void release_path(ImagePath *path) {
    if (path->unix_name) HeapFree(GetProcessHeap(), 0, path->unix_name);
    path->unix_name = NULL;
}

static BOOL resolve_path(const wchar_t *source, ImagePath *path, wine_unix_name_fn unix_name) {
    DWORD length = GetFullPathNameW(source, PATH_CAPACITY, path->windows, NULL);
    if (!length || length >= PATH_CAPACITY) return FALSE;
    for (wchar_t *p = path->windows; *p; p++) if (*p == L'/') *p = L'\\';
    while (length > 3 && path->windows[length - 1] == L'\\') path->windows[--length] = 0;
    // Wine's host filename resolves DOS drive aliases, including C: and a Z:
    // path through the same prefix. GetFullPathName alone cannot equate them.
    if (unix_name) path->unix_name = unix_name(path->windows);
    if (path->unix_name) {
        size_t size = strlen(path->unix_name);
        while (size > 1 && path->unix_name[size - 1] == '/') path->unix_name[--size] = 0;
    }
    return TRUE;
}

static BOOL same_image(const ImagePath *image, const ImagePath *target, BOOL directory) {
    if (image->unix_name && target->unix_name) {
        size_t length = strlen(target->unix_name);
        if (!directory) return strcmp(image->unix_name, target->unix_name) == 0;
        return strncmp(image->unix_name, target->unix_name, length) == 0 &&
            (target->unix_name[length - 1] == '/' || image->unix_name[length] == '/');
    }
    size_t length = wcslen(target->windows);
    if (!directory) return _wcsicmp(image->windows, target->windows) == 0;
    return _wcsnicmp(image->windows, target->windows, length) == 0 &&
        (target->windows[length - 1] == L'\\' || image->windows[length] == L'\\');
}

static HRESULT shortcut_target(const wchar_t *shortcut, wchar_t *target) {
    IShellLinkW *link = NULL;
    IPersistFile *file = NULL;
    HRESULT result = CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER,
                                     &IID_IShellLinkW, (void **)&link);
    if (SUCCEEDED(result)) result = IShellLinkW_QueryInterface(link, &IID_IPersistFile, (void **)&file);
    if (SUCCEEDED(result)) result = IPersistFile_Load(file, shortcut, STGM_READ);
    // Reading the stored target avoids Resolve's search or UI for a moved app.
    if (SUCCEEDED(result)) result = IShellLinkW_GetPath(link, target, PATH_CAPACITY, NULL, 0);
    if (file) IPersistFile_Release(file);
    if (link) IShellLinkW_Release(link);
    return result;
}

static BOOL CALLBACK find_window(HWND window, LPARAM parameter) {
    WindowMatch *match = (WindowMatch *)parameter;
    if (!IsWindowVisible(window) || !IsWindowEnabled(window)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return TRUE;
    wchar_t executable[PATH_CAPACITY];
    DWORD size = PATH_CAPACITY;
    BOOL queried = QueryFullProcessImageNameW(process, 0, executable, &size);
    CloseHandle(process);
    if (!queried) return TRUE;
    ImagePath image = {0};
    if (!resolve_path(executable, &image, match->unix_name)) return TRUE;
    BOOL selected = FALSE;
    for (unsigned index = 0; index < match->path_count; index++) {
        if (same_image(&image, &match->paths[index], match->directory)) { selected = TRUE; break; }
    }
    release_path(&image);
    if (!selected) return TRUE;
    RECT rectangle;
    if (IsIconic(window)) {
        WINDOWPLACEMENT placement = { .length = sizeof(WINDOWPLACEMENT) };
        if (!GetWindowPlacement(window, &placement)) return TRUE;
        rectangle = placement.rcNormalPosition;
    } else if (!GetWindowRect(window, &rectangle)) { return TRUE; }
    LONG width = rectangle.right - rectangle.left, height = rectangle.bottom - rectangle.top;
    if (width <= 0 || height <= 0) return TRUE;
    unsigned long long area = (unsigned long long)width * (unsigned long long)height;
    if (!match->window || area > match->area) {
        match->window = window;
        match->pid = pid;
        match->area = area;
    }
    return TRUE;
}

static void request_mac_activation(const WindowMatch *match) {
    if (!match->mac_activation_message) return;
    // Wine 11 macdrv.h's WM_MACDRV_ACTIVATE_ON_FOLLOWING_FOCUS marks the
    // window owner's next focus request as an activation of its Cocoa app.
    // Ordinary SetForegroundWindow may otherwise change only Wine's focus.
    DWORD_PTR ignored = 0;
    SendMessageTimeoutW(match->window, 0x80001001u, 0, 0,
                        SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &ignored);
}

static BOOL activate_window(const WindowMatch *match) {
    AllowSetForegroundWindow(match->pid);
    request_mac_activation(match);
    if (IsIconic(match->window)) ShowWindowAsync(match->window, SW_RESTORE);
    BringWindowToTop(match->window);
    if (SetForegroundWindow(match->window)) return TRUE;

    DWORD current = GetCurrentThreadId();
    DWORD target = GetWindowThreadProcessId(match->window, NULL);
    DWORD foreground = GetWindowThreadProcessId(GetForegroundWindow(), NULL);
    MSG message;
    PeekMessageW(&message, NULL, 0, 0, PM_NOREMOVE);
    BOOL attached_foreground = foreground && foreground != current && foreground != target &&
        AttachThreadInput(current, foreground, TRUE);
    BOOL attached_target = target && target != current && AttachThreadInput(current, target, TRUE);
    request_mac_activation(match);
    BringWindowToTop(match->window);
    BOOL activated = SetForegroundWindow(match->window);
    if (attached_target) AttachThreadInput(current, target, FALSE);
    if (attached_foreground) AttachThreadInput(current, foreground, FALSE);
    return activated || GetForegroundWindow() == match->window;
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 3 || (wcscmp(argv[1], L"--executable") && wcscmp(argv[1], L"--directory") &&
                      wcscmp(argv[1], L"--steam") && wcscmp(argv[1], L"--shortcut"))) {
        fprintf(stderr, "Use: window-activate --executable|--directory|--steam|--shortcut <Windows path>\n");
        return 2;
    }
    WindowMatch *match = calloc(1, sizeof(WindowMatch));
    if (!match) return 2;
    match->unix_name = (wine_unix_name_fn)(void *)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "wine_get_unix_file_name");
    wine_version_fn version = (wine_version_fn)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version");
    match->directory = wcscmp(argv[1], L"--directory") == 0;
    wchar_t target[PATH_CAPACITY] = {0};
    BOOL initialized = FALSE;
    if (wcscmp(argv[1], L"--shortcut") == 0) {
        HRESULT result = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
        initialized = SUCCEEDED(result);
        if (initialized) result = shortcut_target(argv[2], target);
        if (result != S_OK || !target[0]) {
            fprintf(stderr, "The shortcut target could not be resolved (HRESULT 0x%08lx).\n", (unsigned long)result);
            if (initialized) CoUninitialize();
            free(match);
            return 3;
        }
    } else {
        if (wcslen(argv[2]) >= PATH_CAPACITY) { free(match); return 2; }
        wcscpy(target, argv[2]);
    }
    if (initialized) CoUninitialize();
    if (!resolve_path(target, &match->paths[0], match->unix_name)) { free(match); return 2; }
    match->path_count = 1;
    if (wcscmp(argv[1], L"--steam") == 0) {
        wchar_t *separator = wcsrchr(target, L'\\');
        if (!separator) { release_path(&match->paths[0]); free(match); return 2; }
        *separator = 0;
        const wchar_t *browsers[] = {
            L"\\bin\\cef\\cef.win64\\steamwebhelper.exe",
            L"\\bin\\cef\\cef.win64\\steamwebhelper_original.exe",
            L"\\bin\\cef\\cef.win7x64\\steamwebhelper.exe",
            L"\\bin\\cef\\cef.win7x64\\steamwebhelper_original.exe"
        };
        for (unsigned index = 0; index < 4; index++) {
            wchar_t browser[PATH_CAPACITY];
            if (wcslen(target) + wcslen(browsers[index]) >= PATH_CAPACITY) continue;
            swprintf(browser, PATH_CAPACITY, L"%ls%ls", target, browsers[index]);
            if (resolve_path(browser, &match->paths[match->path_count], match->unix_name)) match->path_count++;
        }
    }
    // The internal driver message is verified against the packaged Wine 11 ABI.
    int status;
    if (!EnumWindows(find_window, (LPARAM)match)) {
        fprintf(stderr, "Window enumeration failed (error %lu).\n", (unsigned long)GetLastError());
        status = 4;
    } else if (!match->window) { status = 1; }
    else {
        match->mac_activation_message = version && strncmp(version(), "11.", 3) == 0 &&
            GetModuleHandleW(L"winemac.drv") != NULL;
        if (activate_window(match)) {
            printf("{\"pid\":%lu,\"hwnd\":%llu}\n", (unsigned long)match->pid,
                   (unsigned long long)(uintptr_t)match->window);
            status = 0;
        } else {
            fprintf(stderr, "The application window could not be activated (PID %lu).\n", (unsigned long)match->pid);
            status = 4;
        }
    }
    for (unsigned index = 0; index < match->path_count; index++) release_path(&match->paths[index]);
    free(match);
    return status;
}
