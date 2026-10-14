/* FFXIV experiment: preserve D3DMetal objects and normalize enumerated modes. */
#define COBJMACROS
#include <windows.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <stdarg.h>

static void trace(const char *format, ...) {
    char path[2048];
    DWORD length = GetEnvironmentVariableA("TRAVERSE_DXGI_LOG", path, sizeof(path));
    FILE *file = length && length < sizeof(path) ? fopen(path, "a") : NULL;
    va_list args;
    va_start(args, format);
    vfprintf(file ? file : stderr, format, args);
    va_end(args);
    if (file) fclose(file);
    else fflush(stderr);
}

typedef HRESULT (WINAPI *FactoryFn)(REFIID, void **);
typedef HRESULT (STDMETHODCALLTYPE *AdaptersFn)(IDXGIFactory *, UINT, IDXGIAdapter **);
typedef HRESULT (STDMETHODCALLTYPE *OutputsFn)(IDXGIAdapter *, UINT, IDXGIOutput **);
typedef HRESULT (STDMETHODCALLTYPE *ModesFn)(IDXGIOutput *, DXGI_FORMAT, UINT, UINT *, DXGI_MODE_DESC *);
static AdaptersFn original_adapters;
static AdaptersFn original_adapters1;
static OutputsFn original_outputs;
static ModesFn original_modes;
typedef struct HookRecord {
    void *object;
    void **original_table;
    void **allocation;
    struct HookRecord *next;
} HookRecord;
static HookRecord *records;
static BOOL enumeration_done;

static void restore_objects(void) {
    enumeration_done = TRUE;
    while (records) {
        HookRecord *record = records;
        records = record->next;
        *(void ***)record->object = record->original_table;
        IUnknown_Release((IUnknown *)record->object);
        HeapFree(GetProcessHeap(), 0, record->allocation);
        HeapFree(GetProcessHeap(), 0, record);
    }
    trace("scanline-fix: original object tables restored before device creation\n");
}

static BOOL hook(void *object, UINT index, UINT entries, void *replacement, void **original) {
    void **table = *(void ***)object;
    void **slot = &table[index];
    if (*slot == replacement) return TRUE;
    /* This experiment targets the single D3DMetal implementation in the fixture. */
    if (*original && *original != *slot) {
        trace("scanline-fix: unexpected vtable implementation\n");
        return FALSE;
    }
    /* D3DMetal's table can lie outside memory managed by VirtualProtect.
       Keep a private copy until startup enumeration finishes. */
    /* Preserve the Itanium RTTI prefix used by native D3DMetal dynamic_cast. */
    void **allocation = HeapAlloc(GetProcessHeap(), 0, (entries + 2) * sizeof(*allocation));
    if (!allocation) return FALSE;
    HookRecord *record = HeapAlloc(GetProcessHeap(), 0, sizeof(*record));
    if (!record) {
        HeapFree(GetProcessHeap(), 0, allocation);
        return FALSE;
    }
    memcpy(allocation, table - 2, (entries + 2) * sizeof(*allocation));
    void **copy = allocation + 2;
    *original = *slot;
    copy[index] = replacement;
    IUnknown_AddRef((IUnknown *)object);
    *record = (HookRecord){object, table, allocation, records};
    records = record;
    *(void ***)object = copy;
    return TRUE;
}

static HRESULT STDMETHODCALLTYPE modes(IDXGIOutput *output, DXGI_FORMAT format,
        UINT flags, UINT *count, DXGI_MODE_DESC *list) {
    UINT capacity = list && count ? *count : 0;
    HRESULT result = original_modes(output, format, flags, count, list);
    UINT changed = 0;
    if (SUCCEEDED(result) && list && count) {
        UINT length = *count < capacity ? *count : capacity;
        for (UINT i = 0; i < length; i++) {
            if (list[i].ScanlineOrdering == DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED) {
                list[i].ScanlineOrdering = DXGI_MODE_SCANLINE_ORDER_PROGRESSIVE;
                changed++;
            }
        }
    }
    trace("scanline-fix: GetDisplayModeList format=%u flags=%u hr=%08lx count=%u normalized=%u\n",
        format, flags, (unsigned long)result, count ? *count : 0, changed);
    fflush(stderr);
    if (SUCCEEDED(result) && list && count && *count) restore_objects();
    return result;
}

static HRESULT STDMETHODCALLTYPE outputs(IDXGIAdapter *adapter, UINT index, IDXGIOutput **output) {
    HRESULT result = original_outputs(adapter, index, output);
    trace("scanline-fix: EnumOutputs index=%u hr=%08lx\n", index, (unsigned long)result);
    if (SUCCEEDED(result) && output && *output) {
        if (!hook(*output, 8, 29, (void *)modes, (void **)&original_modes)) return E_FAIL;
    }
    return result;
}

static HRESULT STDMETHODCALLTYPE adapters(IDXGIFactory *factory, UINT index, IDXGIAdapter **adapter) {
    HRESULT result = original_adapters(factory, index, adapter);
    trace("scanline-fix: EnumAdapters index=%u hr=%08lx\n", index, (unsigned long)result);
    if (SUCCEEDED(result) && adapter && *adapter) {
        if (!hook(*adapter, 7, 19, (void *)outputs, (void **)&original_outputs)) return E_FAIL;
    }
    return result;
}

static HRESULT STDMETHODCALLTYPE adapters1(IDXGIFactory *factory, UINT index, IDXGIAdapter **adapter) {
    HRESULT result = original_adapters1(factory, index, adapter);
    trace("scanline-fix: EnumAdapters1 index=%u hr=%08lx\n", index, (unsigned long)result);
    if (SUCCEEDED(result) && adapter && *adapter) {
        if (!hook(*adapter, 7, 19, (void *)outputs, (void **)&original_outputs)) return E_FAIL;
    }
    return result;
}

__declspec(dllexport) HRESULT WINAPI CreateDXGIFactory(REFIID iid, void **factory) {
#ifdef TRAVERSE_D3DMETAL
    HMODULE real = LoadLibraryW(L"tdxg.dll");
#else
    HMODULE real = LoadLibraryW(L"dxgi.dll");
#endif
    FactoryFn create = real ? (FactoryFn)(void *)GetProcAddress(real, "CreateDXGIFactory") : NULL;
    if (!create) {
        trace("scanline-fix: real DXGI factory unavailable module=%p error=%lu\n", (void *)real, GetLastError());
        return E_FAIL;
    }
    HRESULT result = create(iid, factory);
    if (!enumeration_done && SUCCEEDED(result) && factory && *factory) {
        if (!hook(*factory, 7, 33, (void *)adapters, (void **)&original_adapters)) return E_FAIL;
        IDXGIFactory1 *newer = NULL;
        if (SUCCEEDED(IDXGIFactory_QueryInterface((IDXGIFactory *)*factory, &IID_IDXGIFactory1, (void **)&newer))) {
            BOOL ok = hook(newer, 12, 33, (void *)adapters1, (void **)&original_adapters1);
            IDXGIFactory1_Release(newer);
            if (!ok) return E_FAIL;
        }
    }
    trace("scanline-fix: CreateDXGIFactory hr=%08lx\n", (unsigned long)result);
    fflush(stderr);
    return result;
}
