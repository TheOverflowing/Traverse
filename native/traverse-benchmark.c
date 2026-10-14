// SPDX-License-Identifier: MIT
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define SAMPLE_COUNT 5
#define INTEGER_ITERATIONS UINT64_C(10000000)
#define EVENT_ROUND_TRIPS 5000
#define FILE_BUFFER_BYTES 65536
#define FILE_TOTAL_BYTES 8388608

static volatile uint64_t integer_sink;

typedef struct {
    HANDLE request;
    HANDLE response;
    volatile LONG stopping;
    volatile LONG completed;
} EventWorker;

static int windows_failure(const char *operation) {
    fprintf(stderr, "%s failed (Windows error %lu).\n", operation, GetLastError());
    return 0;
}

static int begin_measurement(LARGE_INTEGER *start) {
    if (!QueryPerformanceCounter(start)) return windows_failure("QueryPerformanceCounter");
    return 1;
}

static int end_measurement(LARGE_INTEGER start, LARGE_INTEGER frequency, double *milliseconds) {
    LARGE_INTEGER end;
    if (!QueryPerformanceCounter(&end)) return windows_failure("QueryPerformanceCounter");
    if (end.QuadPart <= start.QuadPart) {
        fprintf(stderr, "The performance counter did not advance.\n");
        return 0;
    }
    *milliseconds = (double)(end.QuadPart - start.QuadPart) * 1000.0 / (double)frequency.QuadPart;
    return 1;
}

static uint64_t integer_mix(void) {
    uint64_t value = UINT64_C(0x243f6a8885a308d3);
    for (uint64_t index = 0; index < INTEGER_ITERATIONS; index++) {
        value ^= value >> 30;
        value *= UINT64_C(0xbf58476d1ce4e5b9);
        value ^= value >> 27;
        value *= UINT64_C(0x94d049bb133111eb);
        value ^= value >> 31;
        value += index + UINT64_C(0x9e3779b97f4a7c15);
    }
    integer_sink = value;
    return value;
}

static int benchmark_integer(LARGE_INTEGER frequency, double samples[SAMPLE_COUNT]) {
    uint64_t checksum = integer_mix();
    for (int sample = 0; sample < SAMPLE_COUNT; sample++) {
        LARGE_INTEGER start;
        if (!begin_measurement(&start)) return 0;
        uint64_t measured_checksum = integer_mix();
        if (!end_measurement(start, frequency, &samples[sample])) return 0;
        if (measured_checksum != checksum || integer_sink != checksum) {
            fprintf(stderr, "The integer-mix checksum changed between runs.\n");
            return 0;
        }
    }
    return 1;
}

static DWORD WINAPI event_worker(void *argument) {
    EventWorker *worker = argument;
    for (;;) {
        if (InterlockedCompareExchange(&worker->stopping, 0, 0)) return 0;
        // A finite wait permits shutdown if signaling the request event fails.
        DWORD wait = WaitForSingleObject(worker->request, 1000);
        if (wait == WAIT_TIMEOUT) continue;
        if (wait != WAIT_OBJECT_0) {
            windows_failure("The event worker wait");
            return 1;
        }
        if (InterlockedCompareExchange(&worker->stopping, 0, 0)) return 0;
        InterlockedIncrement(&worker->completed);
        if (!SetEvent(worker->response)) {
            windows_failure("The event worker response");
            return 1;
        }
    }
}

static int event_round_trips(EventWorker *worker, HANDLE thread) {
    HANDLE handles[2] = {worker->response, thread};
    for (int iteration = 0; iteration < EVENT_ROUND_TRIPS; iteration++) {
        if (!SetEvent(worker->request)) return windows_failure("The event request");
        DWORD wait = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
        if (wait == WAIT_OBJECT_0 + 1) {
            fprintf(stderr, "The event worker exited before completing a round trip.\n");
            return 0;
        }
        if (wait != WAIT_OBJECT_0) return windows_failure("The event response wait");
    }
    return 1;
}

static int benchmark_events(LARGE_INTEGER frequency, double samples[SAMPLE_COUNT]) {
    EventWorker worker = {0};
    HANDLE thread = NULL;
    int success = 0;
    worker.request = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!worker.request) return windows_failure("CreateEventW for requests");
    worker.response = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!worker.response) {
        windows_failure("CreateEventW for responses");
        goto cleanup;
    }
    thread = CreateThread(NULL, 0, event_worker, &worker, 0, NULL);
    if (!thread) {
        windows_failure("CreateThread");
        goto cleanup;
    }
    for (int run = 0; run <= SAMPLE_COUNT; run++) {
        LARGE_INTEGER start;
        if (run && !begin_measurement(&start)) goto cleanup;
        if (!event_round_trips(&worker, thread)) goto cleanup;
        if (run && !end_measurement(start, frequency, &samples[run - 1])) goto cleanup;
        LONG expected = (LONG)((run + 1) * EVENT_ROUND_TRIPS);
        if (InterlockedCompareExchange(&worker.completed, 0, 0) != expected) {
            fprintf(stderr, "The event worker completed an unexpected number of round trips.\n");
            goto cleanup;
        }
    }
    success = 1;

cleanup:
    if (thread) {
        InterlockedExchange(&worker.stopping, 1);
        if (!SetEvent(worker.request)) {
            windows_failure("The event worker shutdown signal");
            success = 0;
        }
        if (WaitForSingleObject(thread, INFINITE) != WAIT_OBJECT_0) {
            windows_failure("The event worker shutdown wait");
            success = 0;
        }
        DWORD exit_code = 1;
        if (!GetExitCodeThread(thread, &exit_code)) {
            windows_failure("GetExitCodeThread");
            success = 0;
        } else if (exit_code != 0) {
            fprintf(stderr, "The event worker reported a failure.\n");
            success = 0;
        }
        if (!CloseHandle(thread)) {
            windows_failure("CloseHandle for the event worker");
            success = 0;
        }
    }
    if (worker.response && !CloseHandle(worker.response)) {
        windows_failure("CloseHandle for the response event");
        success = 0;
    }
    if (!CloseHandle(worker.request)) {
        windows_failure("CloseHandle for the request event");
        success = 0;
    }
    return success;
}

static int file_write_flush(const wchar_t *path, const BYTE buffer[FILE_BUFFER_BYTES],
                            LARGE_INTEGER frequency, double *milliseconds) {
    HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) return windows_failure("CreateFileW for the data file");
    int success = 0;
    LARGE_INTEGER start;
    if (milliseconds && !begin_measurement(&start)) goto cleanup;
    for (DWORD written_total = 0; written_total < FILE_TOTAL_BYTES; written_total += FILE_BUFFER_BYTES) {
        DWORD written = 0;
        if (!WriteFile(file, buffer, FILE_BUFFER_BYTES, &written, NULL)) {
            windows_failure("WriteFile for the data file");
            goto cleanup;
        }
        if (written != FILE_BUFFER_BYTES) {
            fprintf(stderr, "The data file write was incomplete.\n");
            goto cleanup;
        }
    }
    if (!FlushFileBuffers(file)) {
        windows_failure("FlushFileBuffers for the data file");
        goto cleanup;
    }
    if (milliseconds && !end_measurement(start, frequency, milliseconds)) goto cleanup;

    LARGE_INTEGER beginning = {0};
    LARGE_INTEGER size;
    if (!GetFileSizeEx(file, &size)) {
        windows_failure("GetFileSizeEx");
        goto cleanup;
    }
    if (size.QuadPart != FILE_TOTAL_BYTES) {
        fprintf(stderr, "The data file has an unexpected length.\n");
        goto cleanup;
    }
    if (!SetFilePointerEx(file, beginning, NULL, FILE_BEGIN)) {
        windows_failure("SetFilePointerEx");
        goto cleanup;
    }
    BYTE verification[FILE_BUFFER_BYTES];
    for (DWORD read_total = 0; read_total < FILE_TOTAL_BYTES; read_total += FILE_BUFFER_BYTES) {
        DWORD bytes_read = 0;
        if (!ReadFile(file, verification, FILE_BUFFER_BYTES, &bytes_read, NULL)) {
            windows_failure("ReadFile for verification");
            goto cleanup;
        }
        if (bytes_read != FILE_BUFFER_BYTES || memcmp(buffer, verification, FILE_BUFFER_BYTES)) {
            fprintf(stderr, "The data file did not match the bytes written.\n");
            goto cleanup;
        }
    }
    success = 1;

cleanup:
    if (!CloseHandle(file)) {
        windows_failure("CloseHandle for the data file");
        success = 0;
    }
    if (!DeleteFileW(path)) {
        windows_failure("DeleteFileW for the data file");
        success = 0;
    }
    return success;
}

static int benchmark_file(const wchar_t *path, LARGE_INTEGER frequency, double samples[SAMPLE_COUNT]) {
    BYTE buffer[FILE_BUFFER_BYTES];
    for (DWORD index = 0; index < FILE_BUFFER_BYTES; index++) {
        buffer[index] = (BYTE)((index * 31 + index / 251) & 255);
    }
    if (!file_write_flush(path, buffer, frequency, NULL)) return 0;
    for (int sample = 0; sample < SAMPLE_COUNT; sample++) {
        if (!file_write_flush(path, buffer, frequency, &samples[sample])) return 0;
    }
    return 1;
}

static int publish_json(const wchar_t *output_path, const wchar_t *temporary_path,
                        const double samples[3][SAMPLE_COUNT]) {
    char json[4096];
    int length = snprintf(json, sizeof(json),
        "{\"schemaVersion\":1,\"workloadVersion\":\"win32-v1\",\"pointerBits\":64,\"workloads\":["
        "{\"name\":\"integer-mix\",\"unit\":\"iteration\",\"operations\":10000000,"
        "\"samplesMilliseconds\":[%.17g,%.17g,%.17g,%.17g,%.17g]},"
        "{\"name\":\"event-round-trip\",\"unit\":\"round-trip\",\"operations\":5000,"
        "\"samplesMilliseconds\":[%.17g,%.17g,%.17g,%.17g,%.17g]},"
        "{\"name\":\"file-write-flush\",\"unit\":\"byte\",\"operations\":8388608,"
        "\"samplesMilliseconds\":[%.17g,%.17g,%.17g,%.17g,%.17g]}]}\n",
        samples[0][0], samples[0][1], samples[0][2], samples[0][3], samples[0][4],
        samples[1][0], samples[1][1], samples[1][2], samples[1][3], samples[1][4],
        samples[2][0], samples[2][1], samples[2][2], samples[2][3], samples[2][4]);
    if (length <= 0 || (size_t)length >= sizeof(json)) {
        fprintf(stderr, "The benchmark JSON could not be formatted.\n");
        return 0;
    }
    HANDLE file = CreateFileW(temporary_path, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return windows_failure("CreateFileW for the JSON file");
    DWORD written = 0;
    int success = 1;
    if (!WriteFile(file, json, (DWORD)length, &written, NULL)) {
        windows_failure("WriteFile for the JSON file");
        success = 0;
    } else if (written != (DWORD)length) {
        fprintf(stderr, "The benchmark JSON write was incomplete.\n");
        success = 0;
    }
    if (success && !FlushFileBuffers(file)) {
        windows_failure("FlushFileBuffers for the JSON file");
        success = 0;
    }
    if (!CloseHandle(file)) {
        windows_failure("CloseHandle for the JSON file");
        success = 0;
    }
    if (success && !MoveFileExW(temporary_path, output_path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        windows_failure("MoveFileExW for the completed JSON file");
        success = 0;
    }
    if (!success && !DeleteFileW(temporary_path)) windows_failure("DeleteFileW for the incomplete JSON file");
    return success;
}

static int is_absolute_windows_path(const wchar_t *path) {
    size_t length = wcslen(path);
    if (length < 3) return 0;
    int drive_letter = (path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z');
    return (drive_letter && path[1] == L':' && (path[2] == L'\\' || path[2] == L'/')) ||
           (path[0] == L'\\' && path[1] == L'\\' && path[2] != L'\\');
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 2 || !is_absolute_windows_path(argv[1])) {
        fprintf(stderr, "Usage: traverse-benchmark.exe <absolute Windows output JSON path>\n");
        return 1;
    }
    if (sizeof(void *) * 8 != 64) {
        fprintf(stderr, "This benchmark requires a 64-bit Windows build.\n");
        return 1;
    }
    LARGE_INTEGER frequency;
    if (!QueryPerformanceFrequency(&frequency)) {
        windows_failure("QueryPerformanceFrequency");
        return 1;
    }
    if (frequency.QuadPart <= 0) {
        fprintf(stderr, "The performance counter frequency is invalid.\n");
        return 1;
    }
    size_t capacity = wcslen(argv[1]) + 64;
    wchar_t *temporary_path = calloc(capacity, sizeof(wchar_t));
    if (!temporary_path) {
        fprintf(stderr, "The temporary file path could not be allocated.\n");
        return 1;
    }
    if (swprintf(temporary_path, capacity, L"%ls.traverse-%lu.tmp", argv[1], GetCurrentProcessId()) < 0) {
        fprintf(stderr, "The temporary file path could not be formatted.\n");
        free(temporary_path);
        return 1;
    }
    double samples[3][SAMPLE_COUNT];
    int success = benchmark_integer(frequency, samples[0]) &&
                  benchmark_events(frequency, samples[1]) &&
                  benchmark_file(temporary_path, frequency, samples[2]) &&
                  publish_json(argv[1], temporary_path, samples);
    free(temporary_path);
    return success ? 0 : 1;
}
