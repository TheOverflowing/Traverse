// SPDX-License-Identifier: MIT
#define COBJMACROS
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define IMAGE_WIDTH 1280
#define IMAGE_HEIGHT 720
#define TILE_COLUMNS 64
#define TILE_ROWS 40
#define TILE_COUNT (TILE_COLUMNS * TILE_ROWS)
#define RENDERS_PER_BATCH 8
#define SAMPLE_COUNT 5
#define QUERY_TIMEOUT_MS 30000
#define GPU_DATA_TIMEOUT_MS 1000
#define MODULE_PATH_CAPACITY 32768
#define JSON_CAPACITY 524288
#define GPU_REASON_CAPACITY 192

static const char tiled_shader[] =
    "cbuffer Parameters : register(b0) { uint drawMode; uint3 padding; };\n"
    "struct Vertex { float4 position : SV_POSITION; nointerpolation uint tile : TEXCOORD0; };\n"
    "Vertex vs_main(uint inputTile : TILE, uint inputCorner : CORNER, uint instanceID : SV_InstanceID) {\n"
    "  static const uint2 corners[6] = { uint2(0,0), uint2(1,0), uint2(0,1),\n"
    "                                  uint2(0,1), uint2(1,0), uint2(1,1) };\n"
    "  uint tile = drawMode == 0 ? inputTile : instanceID;\n"
    "  float2 origin = float2((tile % 64) * 20, (tile / 64) * 18);\n"
    "  float2 pixel = origin + float2(corners[inputCorner]) * float2(20,18);\n"
    "  Vertex output;\n"
    "  output.position = float4(pixel.x * (2.0/1280.0) - 1.0,\n"
    "                           1.0 - pixel.y * (2.0/720.0), 0.0, 1.0);\n"
    "  output.tile = tile;\n"
    "  return output;\n"
    "}\n"
    "float4 ps_main(Vertex input) : SV_TARGET {\n"
    "  uint tile = input.tile;\n"
    "  return float4(tile % 251, (tile / 64) * 5, (tile * 17) % 251, 255) / 255.0;\n"
    "}\n";

static const char fill_shader[] =
    "float4 vs_main(uint vertexID : SV_VertexID) : SV_POSITION {\n"
    "  static const float2 corners[3] = { float2(-1,-1), float2(-1,3), float2(3,-1) };\n"
    "  return float4(corners[vertexID], 0.0, 1.0);\n"
    "}\n"
    "float4 ps_main(float4 position : SV_POSITION) : SV_TARGET {\n"
    "  uint value = uint(position.x) | (uint(position.y) << 16);\n"
    "  [unroll] for (uint round = 0; round < 64; round++)\n"
    "    value = (value ^ (value >> 16)) * 1664525u + 1013904223u + round;\n"
    "  return float4(value & 255u, (value >> 8) & 255u, (value >> 16) & 255u, 255) / 255.0;\n"
    "}\n";

typedef struct {
    double cpu_submission;
    double completion;
    double gpu;
    int gpu_valid;
    char gpu_reason[GPU_REASON_CAPACITY];
} Sample;

typedef struct {
    const char *name;
    const char *task;
    UINT draw_calls;
    UINT vertices;
    int kind;
    Sample samples[SAMPLE_COUNT];
} Workload;

typedef struct {
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    ID3D11Texture2D *targets[RENDERS_PER_BATCH];
    ID3D11Texture2D *staging;
    ID3D11RenderTargetView *views[RENDERS_PER_BATCH];
    ID3D11VertexShader *tiled_vertex;
    ID3D11PixelShader *tiled_pixel;
    ID3D11VertexShader *fill_vertex;
    ID3D11PixelShader *fill_pixel;
    ID3D11Buffer *parameters;
    ID3D11Buffer *vertices;
    ID3D11InputLayout *input_layout;
    ID3D11RasterizerState *rasterizer;
    ID3D11DepthStencilState *depth_state;
    ID3D11Query *completion;
    ID3D11Query *disjoint;
    ID3D11Query *gpu_start;
    ID3D11Query *gpu_end;
    int gpu_available;
    char gpu_disabled_reason[GPU_REASON_CAPACITY];
    DXGI_ADAPTER_DESC adapter;
    wchar_t *d3d11_module;
    wchar_t *dxgi_module;
    LARGE_INTEGER frequency;
} Graphics;

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} JSONBuffer;

static int windows_failure(const char *operation) {
    fprintf(stderr, "%s failed (Windows error %lu).\n", operation, GetLastError());
    return 0;
}

static int hresult_failure(const char *operation, HRESULT result) {
    fprintf(stderr, "%s failed (HRESULT 0x%08lx).\n", operation, (unsigned long)result);
    return 0;
}

static int performance_counter(LARGE_INTEGER *value) {
    if (!QueryPerformanceCounter(value)) return windows_failure("QueryPerformanceCounter");
    return 1;
}

static double elapsed_milliseconds(LARGE_INTEGER start, LARGE_INTEGER end, LARGE_INTEGER frequency) {
    return (double)(end.QuadPart - start.QuadPart) * 1000.0 / (double)frequency.QuadPart;
}

static int get_query_data(Graphics *graphics, ID3D11Query *query, void *data, UINT size,
                          DWORD timeout, char reason[GPU_REASON_CAPACITY]) {
    ULONGLONG started = GetTickCount64();
    for (;;) {
        HRESULT result = ID3D11DeviceContext_GetData(graphics->context,
            (ID3D11Asynchronous *)query, data, size, D3D11_ASYNC_GETDATA_DONOTFLUSH);
        if (result == S_OK) return 1;
        if (result != S_FALSE) {
            snprintf(reason, GPU_REASON_CAPACITY, "GetData failed (HRESULT 0x%08lx).", (unsigned long)result);
            return 0;
        }
        if (GetTickCount64() - started >= timeout) {
            snprintf(reason, GPU_REASON_CAPACITY, "Query data was unavailable after %lu milliseconds.", timeout);
            return 0;
        }
        Sleep(0);
    }
}

static int wait_for_completion(Graphics *graphics, const char *operation) {
    ULONGLONG started = GetTickCount64();
    for (;;) {
        BOOL completed = FALSE;
        HRESULT result = ID3D11DeviceContext_GetData(graphics->context,
            (ID3D11Asynchronous *)graphics->completion, &completed, sizeof(completed),
            D3D11_ASYNC_GETDATA_DONOTFLUSH);
        // Some translation layers return S_OK before setting the EVENT's BOOL.
        // The completed-work measurement requires both signals.
        if (result == S_OK && completed) return 1;
        if (result != S_OK && result != S_FALSE) return hresult_failure(operation, result);
        if (GetTickCount64() - started >= QUERY_TIMEOUT_MS) {
            fprintf(stderr, "%s EVENT did not signal completion after %u milliseconds.\n", operation, QUERY_TIMEOUT_MS);
            HRESULT removed = ID3D11Device_GetDeviceRemovedReason(graphics->device);
            if (FAILED(removed)) hresult_failure("The Direct3D device", removed);
            return 0;
        }
        Sleep(0);
    }
}

static int compile_shader(const char *source, const char *entry, const char *profile, ID3DBlob **code) {
    ID3DBlob *errors = NULL;
    HRESULT result = D3DCompile(source, strlen(source), "traverse-graphics.hlsl", NULL, NULL,
        entry, profile, D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, code, &errors);
    if (FAILED(result)) {
        hresult_failure("D3DCompile", result);
        if (errors) fwrite(ID3D10Blob_GetBufferPointer(errors), 1, ID3D10Blob_GetBufferSize(errors), stderr);
    }
    if (errors) ID3D10Blob_Release(errors);
    return SUCCEEDED(result);
}

static int create_vertex_shader(Graphics *graphics, const char *source, ID3D11VertexShader **shader,
                                ID3D11InputLayout **layout) {
    ID3DBlob *code = NULL;
    if (!compile_shader(source, "vs_main", "vs_5_0", &code)) return 0;
    HRESULT result = ID3D11Device_CreateVertexShader(graphics->device,
        ID3D10Blob_GetBufferPointer(code), ID3D10Blob_GetBufferSize(code), NULL, shader);
    if (SUCCEEDED(result) && layout) {
        const D3D11_INPUT_ELEMENT_DESC elements[2] = {
            {"TILE", 0, DXGI_FORMAT_R32_UINT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
            {"CORNER", 0, DXGI_FORMAT_R32_UINT, 0, 4, D3D11_INPUT_PER_VERTEX_DATA, 0},
        };
        result = ID3D11Device_CreateInputLayout(graphics->device, elements, 2,
            ID3D10Blob_GetBufferPointer(code), ID3D10Blob_GetBufferSize(code), layout);
    }
    ID3D10Blob_Release(code);
    if (FAILED(result)) return hresult_failure("CreateVertexShader or its input layout", result);
    return 1;
}

static int create_pixel_shader(Graphics *graphics, const char *source, ID3D11PixelShader **shader) {
    ID3DBlob *code = NULL;
    if (!compile_shader(source, "ps_main", "ps_5_0", &code)) return 0;
    HRESULT result = ID3D11Device_CreatePixelShader(graphics->device,
        ID3D10Blob_GetBufferPointer(code), ID3D10Blob_GetBufferSize(code), NULL, shader);
    ID3D10Blob_Release(code);
    if (FAILED(result)) return hresult_failure("CreatePixelShader", result);
    return 1;
}

static wchar_t *module_path(const wchar_t *name) {
    HMODULE module = GetModuleHandleW(name);
    if (!module) {
        windows_failure("GetModuleHandleW for a graphics module");
        return NULL;
    }
    wchar_t *path = calloc(MODULE_PATH_CAPACITY, sizeof(wchar_t));
    if (!path) {
        fprintf(stderr, "The graphics module path could not be allocated.\n");
        return NULL;
    }
    DWORD length = GetModuleFileNameW(module, path, MODULE_PATH_CAPACITY);
    if (!length || length >= MODULE_PATH_CAPACITY) {
        windows_failure("GetModuleFileNameW for a graphics module");
        free(path);
        return NULL;
    }
    return path;
}

static int read_adapter(Graphics *graphics) {
    IDXGIDevice *device = NULL;
    IDXGIAdapter *adapter = NULL;
    HRESULT result = ID3D11Device_QueryInterface(graphics->device, &IID_IDXGIDevice, (void **)&device);
    if (FAILED(result)) return hresult_failure("QueryInterface for IDXGIDevice", result);
    result = IDXGIDevice_GetAdapter(device, &adapter);
    if (SUCCEEDED(result)) result = IDXGIAdapter_GetDesc(adapter, &graphics->adapter);
    if (adapter) IDXGIAdapter_Release(adapter);
    IDXGIDevice_Release(device);
    if (FAILED(result)) return hresult_failure("Read the DXGI adapter", result);
    graphics->d3d11_module = module_path(L"d3d11.dll");
    graphics->dxgi_module = module_path(L"dxgi.dll");
    return graphics->d3d11_module && graphics->dxgi_module;
}

static void create_optional_gpu_queries(Graphics *graphics) {
    const D3D11_QUERY types[3] = {D3D11_QUERY_TIMESTAMP_DISJOINT, D3D11_QUERY_TIMESTAMP, D3D11_QUERY_TIMESTAMP};
    const char *names[3] = {"TIMESTAMP_DISJOINT", "start TIMESTAMP", "end TIMESTAMP"};
    ID3D11Query **queries[3] = {&graphics->disjoint, &graphics->gpu_start, &graphics->gpu_end};
    for (int index = 0; index < 3; index++) {
        D3D11_QUERY_DESC description = {types[index], 0};
        HRESULT result = ID3D11Device_CreateQuery(graphics->device, &description, queries[index]);
        if (FAILED(result)) {
            snprintf(graphics->gpu_disabled_reason, sizeof(graphics->gpu_disabled_reason),
                "%s query creation failed (HRESULT 0x%08lx).", names[index], (unsigned long)result);
            fprintf(stderr, "GPU timestamps unavailable: %s\n", graphics->gpu_disabled_reason);
            return;
        }
    }
    graphics->gpu_available = 1;
}

static int initialize_graphics(Graphics *graphics) {
    D3D_FEATURE_LEVEL requested = D3D_FEATURE_LEVEL_11_0;
    D3D_FEATURE_LEVEL actual;
    HRESULT result = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &requested, 1,
        D3D11_SDK_VERSION, &graphics->device, &actual, &graphics->context);
    if (FAILED(result)) return hresult_failure("D3D11CreateDevice at feature level 11_0", result);
    if (actual != requested) {
        fprintf(stderr, "The device did not provide Direct3D feature level 11_0.\n");
        return 0;
    }
    if (!read_adapter(graphics)) return 0;
    if (!QueryPerformanceFrequency(&graphics->frequency)) return windows_failure("QueryPerformanceFrequency");
    if (graphics->frequency.QuadPart <= 0) {
        fprintf(stderr, "The performance counter frequency is invalid.\n");
        return 0;
    }

    D3D11_TEXTURE2D_DESC texture = {0};
    texture.Width = IMAGE_WIDTH;
    texture.Height = IMAGE_HEIGHT;
    texture.MipLevels = 1;
    texture.ArraySize = 1;
    texture.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    texture.SampleDesc.Count = 1;
    texture.Usage = D3D11_USAGE_DEFAULT;
    texture.BindFlags = D3D11_BIND_RENDER_TARGET;
    for (UINT render = 0; render < RENDERS_PER_BATCH; render++) {
        result = ID3D11Device_CreateTexture2D(graphics->device, &texture, NULL, &graphics->targets[render]);
        if (FAILED(result)) return hresult_failure("CreateTexture2D for a render target", result);
        result = ID3D11Device_CreateRenderTargetView(graphics->device, (ID3D11Resource *)graphics->targets[render],
                                                     NULL, &graphics->views[render]);
        if (FAILED(result)) return hresult_failure("CreateRenderTargetView", result);
    }
    texture.Usage = D3D11_USAGE_STAGING;
    texture.BindFlags = 0;
    texture.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    result = ID3D11Device_CreateTexture2D(graphics->device, &texture, NULL, &graphics->staging);
    if (FAILED(result)) return hresult_failure("CreateTexture2D for pixel readback", result);

    if (!create_vertex_shader(graphics, tiled_shader, &graphics->tiled_vertex, &graphics->input_layout) ||
        !create_pixel_shader(graphics, tiled_shader, &graphics->tiled_pixel) ||
        !create_vertex_shader(graphics, fill_shader, &graphics->fill_vertex, NULL) ||
        !create_pixel_shader(graphics, fill_shader, &graphics->fill_pixel)) return 0;

    D3D11_BUFFER_DESC buffer = {0};
    buffer.ByteWidth = 16;
    buffer.Usage = D3D11_USAGE_DEFAULT;
    buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    result = ID3D11Device_CreateBuffer(graphics->device, &buffer, NULL, &graphics->parameters);
    if (FAILED(result)) return hresult_failure("CreateBuffer for shader parameters", result);
    UINT *vertices = malloc((size_t)TILE_COUNT * 6 * 2 * sizeof(UINT));
    if (!vertices) {
        fprintf(stderr, "The tiled vertex input could not be allocated.\n");
        return 0;
    }
    for (UINT vertex = 0; vertex < TILE_COUNT * 6; vertex++) {
        vertices[vertex * 2] = vertex / 6;
        vertices[vertex * 2 + 1] = vertex % 6;
    }
    buffer.ByteWidth = TILE_COUNT * 6 * 2 * sizeof(UINT);
    buffer.Usage = D3D11_USAGE_IMMUTABLE;
    buffer.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA vertex_data = {vertices, 0, 0};
    result = ID3D11Device_CreateBuffer(graphics->device, &buffer, &vertex_data, &graphics->vertices);
    free(vertices);
    if (FAILED(result)) return hresult_failure("CreateBuffer for tiled vertex input", result);
    D3D11_RASTERIZER_DESC rasterizer = {0};
    rasterizer.FillMode = D3D11_FILL_SOLID;
    rasterizer.CullMode = D3D11_CULL_NONE;
    rasterizer.DepthClipEnable = TRUE;
    result = ID3D11Device_CreateRasterizerState(graphics->device, &rasterizer, &graphics->rasterizer);
    if (FAILED(result)) return hresult_failure("CreateRasterizerState", result);
    D3D11_DEPTH_STENCIL_DESC depth = {0};
    depth.DepthEnable = FALSE;
    depth.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
    depth.DepthFunc = D3D11_COMPARISON_ALWAYS;
    result = ID3D11Device_CreateDepthStencilState(graphics->device, &depth, &graphics->depth_state);
    if (FAILED(result)) return hresult_failure("CreateDepthStencilState", result);
    D3D11_QUERY_DESC completion = {D3D11_QUERY_EVENT, 0};
    result = ID3D11Device_CreateQuery(graphics->device, &completion, &graphics->completion);
    if (FAILED(result)) return hresult_failure("CreateQuery for GPU completion", result);
    create_optional_gpu_queries(graphics);

    D3D11_VIEWPORT viewport = {0, 0, IMAGE_WIDTH, IMAGE_HEIGHT, 0, 1};
    ID3D11DeviceContext_RSSetViewports(graphics->context, 1, &viewport);
    ID3D11DeviceContext_RSSetState(graphics->context, graphics->rasterizer);
    ID3D11DeviceContext_OMSetDepthStencilState(graphics->context, graphics->depth_state, 0);
    ID3D11DeviceContext_OMSetBlendState(graphics->context, NULL, NULL, ~0u);
    ID3D11DeviceContext_IASetPrimitiveTopology(graphics->context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_IASetInputLayout(graphics->context, NULL);
    return 1;
}

static void release_graphics(Graphics *graphics) {
    if (graphics->context) ID3D11DeviceContext_ClearState(graphics->context);
    if (graphics->gpu_end) ID3D11Query_Release(graphics->gpu_end);
    if (graphics->gpu_start) ID3D11Query_Release(graphics->gpu_start);
    if (graphics->disjoint) ID3D11Query_Release(graphics->disjoint);
    if (graphics->completion) ID3D11Query_Release(graphics->completion);
    if (graphics->depth_state) ID3D11DepthStencilState_Release(graphics->depth_state);
    if (graphics->rasterizer) ID3D11RasterizerState_Release(graphics->rasterizer);
    if (graphics->parameters) ID3D11Buffer_Release(graphics->parameters);
    if (graphics->vertices) ID3D11Buffer_Release(graphics->vertices);
    if (graphics->input_layout) ID3D11InputLayout_Release(graphics->input_layout);
    if (graphics->fill_pixel) ID3D11PixelShader_Release(graphics->fill_pixel);
    if (graphics->fill_vertex) ID3D11VertexShader_Release(graphics->fill_vertex);
    if (graphics->tiled_pixel) ID3D11PixelShader_Release(graphics->tiled_pixel);
    if (graphics->tiled_vertex) ID3D11VertexShader_Release(graphics->tiled_vertex);
    for (UINT render = 0; render < RENDERS_PER_BATCH; render++) {
        if (graphics->views[render]) ID3D11RenderTargetView_Release(graphics->views[render]);
    }
    if (graphics->staging) ID3D11Texture2D_Release(graphics->staging);
    for (UINT render = 0; render < RENDERS_PER_BATCH; render++) {
        if (graphics->targets[render]) ID3D11Texture2D_Release(graphics->targets[render]);
    }
    if (graphics->context) ID3D11DeviceContext_Release(graphics->context);
    if (graphics->device) ID3D11Device_Release(graphics->device);
    free(graphics->d3d11_module);
    free(graphics->dxgi_module);
}

static uint32_t fill_value(UINT x, UINT y) {
    uint32_t value = x | (y << 16);
    for (uint32_t round = 0; round < 64; round++) {
        value = (value ^ (value >> 16)) * UINT32_C(1664525) + UINT32_C(1013904223) + round;
    }
    return value;
}

static BYTE *reference_image(int fill) {
    BYTE *pixels = malloc((size_t)IMAGE_WIDTH * IMAGE_HEIGHT * 4);
    if (!pixels) {
        fprintf(stderr, "The reference image could not be allocated.\n");
        return NULL;
    }
    for (UINT y = 0; y < IMAGE_HEIGHT; y++) {
        for (UINT x = 0; x < IMAGE_WIDTH; x++) {
            BYTE *pixel = pixels + ((size_t)y * IMAGE_WIDTH + x) * 4;
            if (fill) {
                uint32_t value = fill_value(x, y);
                pixel[0] = (BYTE)value;
                pixel[1] = (BYTE)(value >> 8);
                pixel[2] = (BYTE)(value >> 16);
            } else {
                UINT tile = (y / 18) * TILE_COLUMNS + x / 20;
                pixel[0] = (BYTE)(tile % 251);
                pixel[1] = (BYTE)((tile / TILE_COLUMNS) * 5);
                pixel[2] = (BYTE)((tile * 17) % 251);
            }
            pixel[3] = 255;
        }
    }
    return pixels;
}

static int verify_pixels(Graphics *graphics, const BYTE *reference, const char *workload, UINT render) {
    ID3D11DeviceContext_CopyResource(graphics->context, (ID3D11Resource *)graphics->staging,
                                    (ID3D11Resource *)graphics->targets[render]);
    ID3D11DeviceContext_End(graphics->context, (ID3D11Asynchronous *)graphics->completion);
    ID3D11DeviceContext_Flush(graphics->context);
    if (!wait_for_completion(graphics, "Pixel readback completion")) return 0;
    D3D11_MAPPED_SUBRESOURCE mapped;
    ULONGLONG started = GetTickCount64();
    for (;;) {
        HRESULT result = ID3D11DeviceContext_Map(graphics->context, (ID3D11Resource *)graphics->staging,
            0, D3D11_MAP_READ, D3D11_MAP_FLAG_DO_NOT_WAIT, &mapped);
        if (SUCCEEDED(result)) break;
        if (result != DXGI_ERROR_WAS_STILL_DRAWING) return hresult_failure("Map for pixel readback", result);
        if (GetTickCount64() - started >= QUERY_TIMEOUT_MS) {
            fprintf(stderr, "Map for pixel readback was still drawing after %u milliseconds.\n", QUERY_TIMEOUT_MS);
            return 0;
        }
        Sleep(0);
    }
    int valid = 1;
    if (!mapped.pData || mapped.RowPitch < IMAGE_WIDTH * 4) {
        fprintf(stderr, "Pixel readback returned an invalid row layout.\n");
        valid = 0;
    }
    for (UINT y = 0; valid && y < IMAGE_HEIGHT; y++) {
        const BYTE *actual = (const BYTE *)mapped.pData + (size_t)y * mapped.RowPitch;
        const BYTE *expected = reference + (size_t)y * IMAGE_WIDTH * 4;
        if (!memcmp(actual, expected, IMAGE_WIDTH * 4)) continue;
        for (UINT x = 0; x < IMAGE_WIDTH; x++) {
            if (memcmp(actual + x * 4, expected + x * 4, 4)) {
                fprintf(stderr, "%s render %u pixel mismatch at (%u,%u): expected RGBA %u,%u,%u,%u; got %u,%u,%u,%u.\n",
                    workload, render, x, y, expected[x * 4], expected[x * 4 + 1], expected[x * 4 + 2], expected[x * 4 + 3],
                    actual[x * 4], actual[x * 4 + 1], actual[x * 4 + 2], actual[x * 4 + 3]);
                valid = 0;
                break;
            }
        }
    }
    ID3D11DeviceContext_Unmap(graphics->context, (ID3D11Resource *)graphics->staging, 0);
    return valid;
}

static int verify_batch_pixels(Graphics *graphics, const BYTE *reference, const char *workload) {
    for (UINT render = 0; render < RENDERS_PER_BATCH; render++) {
        if (!verify_pixels(graphics, reference, workload, render)) return 0;
    }
    return 1;
}

static void read_gpu_timing(Graphics *graphics, Sample *sample) {
    if (!graphics->gpu_available) {
        snprintf(sample->gpu_reason, sizeof(sample->gpu_reason), "%s", graphics->gpu_disabled_reason);
        return;
    }
    D3D11_QUERY_DATA_TIMESTAMP_DISJOINT disjoint;
    UINT64 start;
    UINT64 end;
    char reason[GPU_REASON_CAPACITY];
    if (!get_query_data(graphics, graphics->disjoint, &disjoint, sizeof(disjoint), GPU_DATA_TIMEOUT_MS, reason) ||
        !get_query_data(graphics, graphics->gpu_start, &start, sizeof(start), GPU_DATA_TIMEOUT_MS, reason) ||
        !get_query_data(graphics, graphics->gpu_end, &end, sizeof(end), GPU_DATA_TIMEOUT_MS, reason)) {
        graphics->gpu_available = 0;
        snprintf(graphics->gpu_disabled_reason, sizeof(graphics->gpu_disabled_reason), "%s", reason);
        snprintf(sample->gpu_reason, sizeof(sample->gpu_reason), "%s", graphics->gpu_disabled_reason);
        fprintf(stderr, "GPU timestamps unavailable: %s\n", sample->gpu_reason);
        return;
    }
    if (disjoint.Disjoint) {
        snprintf(sample->gpu_reason, sizeof(sample->gpu_reason), "The GPU timestamp interval was disjoint.");
        return;
    }
    if (!disjoint.Frequency || end <= start) {
        snprintf(sample->gpu_reason, sizeof(sample->gpu_reason), "GPU timestamps had an invalid frequency or nonpositive interval.");
        return;
    }
    sample->gpu = (double)(end - start) * 1000.0 / (double)disjoint.Frequency;
    sample->gpu_valid = 1;
}

static void set_workload(Graphics *graphics, int kind) {
    if (kind == 2) {
        ID3D11DeviceContext_IASetInputLayout(graphics->context, NULL);
        ID3D11DeviceContext_VSSetShader(graphics->context, graphics->fill_vertex, NULL, 0);
        ID3D11DeviceContext_PSSetShader(graphics->context, graphics->fill_pixel, NULL, 0);
    } else {
        UINT parameters[4] = {(UINT)kind, 0, 0, 0};
        UINT stride = 2 * sizeof(UINT);
        UINT offset = 0;
        ID3D11DeviceContext_IASetInputLayout(graphics->context, graphics->input_layout);
        ID3D11DeviceContext_IASetVertexBuffers(graphics->context, 0, 1, &graphics->vertices, &stride, &offset);
        ID3D11DeviceContext_UpdateSubresource(graphics->context, (ID3D11Resource *)graphics->parameters,
                                             0, NULL, parameters, 0, 0);
        ID3D11DeviceContext_VSSetConstantBuffers(graphics->context, 0, 1, &graphics->parameters);
        ID3D11DeviceContext_VSSetShader(graphics->context, graphics->tiled_vertex, NULL, 0);
        ID3D11DeviceContext_PSSetShader(graphics->context, graphics->tiled_pixel, NULL, 0);
    }
}

static int render_batch(Graphics *graphics, int kind, Sample *sample) {
    LARGE_INTEGER start;
    LARGE_INTEGER submitted;
    LARGE_INTEGER completed;
    if (graphics->gpu_available) {
        ID3D11DeviceContext_Begin(graphics->context, (ID3D11Asynchronous *)graphics->disjoint);
        ID3D11DeviceContext_End(graphics->context, (ID3D11Asynchronous *)graphics->gpu_start);
    }
    if (sample && !performance_counter(&start)) return 0;
    const FLOAT clear[4] = {0, 0, 0, 0};
    for (UINT render = 0; render < RENDERS_PER_BATCH; render++) {
        // Every image remains observable, so later clears cannot discard earlier renders.
        ID3D11DeviceContext_OMSetRenderTargets(graphics->context, 1, &graphics->views[render], NULL);
        ID3D11DeviceContext_ClearRenderTargetView(graphics->context, graphics->views[render], clear);
        if (kind == 0) {
            for (UINT tile = 0; tile < TILE_COUNT; tile++) {
                ID3D11DeviceContext_Draw(graphics->context, 6, tile * 6);
            }
        } else if (kind == 1) {
            ID3D11DeviceContext_DrawInstanced(graphics->context, 6, TILE_COUNT, 0, 0);
        } else {
            ID3D11DeviceContext_Draw(graphics->context, 3, 0);
        }
    }
    if (sample && !performance_counter(&submitted)) return 0;
    if (graphics->gpu_available) {
        ID3D11DeviceContext_End(graphics->context, (ID3D11Asynchronous *)graphics->gpu_end);
        ID3D11DeviceContext_End(graphics->context, (ID3D11Asynchronous *)graphics->disjoint);
    }
    ID3D11DeviceContext_End(graphics->context, (ID3D11Asynchronous *)graphics->completion);
    ID3D11DeviceContext_Flush(graphics->context);
    if (!wait_for_completion(graphics, "Render batch completion")) return 0;
    if (sample) {
        if (!performance_counter(&completed)) return 0;
        if (submitted.QuadPart <= start.QuadPart || completed.QuadPart < submitted.QuadPart) {
            fprintf(stderr, "The render batch performance counter interval is invalid.\n");
            return 0;
        }
        sample->cpu_submission = elapsed_milliseconds(start, submitted, graphics->frequency);
        sample->completion = elapsed_milliseconds(start, completed, graphics->frequency);
        read_gpu_timing(graphics, sample);
    } else {
        Sample warmup = {0};
        read_gpu_timing(graphics, &warmup);
    }
    return 1;
}

static int benchmark_workload(Graphics *graphics, Workload *workload, const BYTE *reference) {
    set_workload(graphics, workload->kind);
    if (!render_batch(graphics, workload->kind, NULL) ||
        !verify_batch_pixels(graphics, reference, workload->name)) return 0;
    for (int index = 0; index < SAMPLE_COUNT; index++) {
        if (!render_batch(graphics, workload->kind, &workload->samples[index]) ||
            !verify_batch_pixels(graphics, reference, workload->name)) return 0;
    }
    return 1;
}

static int json_append(JSONBuffer *json, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int written = vsnprintf(json->data + json->length, json->capacity - json->length, format, arguments);
    va_end(arguments);
    if (written < 0 || (size_t)written >= json->capacity - json->length) {
        fprintf(stderr, "The graphics benchmark JSON could not be formatted.\n");
        return 0;
    }
    json->length += (size_t)written;
    return 1;
}

static int json_wide_string(JSONBuffer *json, const wchar_t *value) {
    if (!json_append(json, "\"")) return 0;
    for (; *value; value++) {
        unsigned int character = (unsigned int)*value;
        if (character == '"' || character == '\\') {
            if (!json_append(json, "\\%c", (char)character)) return 0;
        } else if (character >= 32 && character <= 126) {
            if (!json_append(json, "%c", (char)character)) return 0;
        } else {
            // Windows paths use UTF-16; escaping code units preserves surrogate pairs.
            if (!json_append(json, "\\u%04x", character)) return 0;
        }
    }
    return json_append(json, "\"");
}

static int json_ascii_string(JSONBuffer *json, const char *value) {
    if (!json_append(json, "\"")) return 0;
    for (; *value; value++) {
        unsigned char character = (unsigned char)*value;
        if (character == '"' || character == '\\') {
            if (!json_append(json, "\\%c", character)) return 0;
        } else if (character < 32) {
            if (!json_append(json, "\\u%04x", character)) return 0;
        } else if (!json_append(json, "%c", character)) return 0;
    }
    return json_append(json, "\"");
}

static int format_workload(JSONBuffer *json, const Workload *workload) {
    if (!json_append(json, "{\"name\":\"%s\",\"task\":\"%s\",\"drawCallsPerRender\":%u,"
        "\"verticesPerRender\":%u,\"cpuSubmissionMilliseconds\":[", workload->name, workload->task,
        workload->draw_calls, workload->vertices)) return 0;
    for (int index = 0; index < SAMPLE_COUNT; index++) {
        if (!json_append(json, "%s%.17g", index ? "," : "", workload->samples[index].cpu_submission)) return 0;
    }
    if (!json_append(json, "],\"completionMilliseconds\":[")) return 0;
    for (int index = 0; index < SAMPLE_COUNT; index++) {
        if (!json_append(json, "%s%.17g", index ? "," : "", workload->samples[index].completion)) return 0;
    }
    if (!json_append(json, "],\"gpuMilliseconds\":[")) return 0;
    for (int index = 0; index < SAMPLE_COUNT; index++) {
        if (index && !json_append(json, ",")) return 0;
        if (workload->samples[index].gpu_valid) {
            if (!json_append(json, "%.17g", workload->samples[index].gpu)) return 0;
        } else if (!json_append(json, "null")) return 0;
    }
    if (!json_append(json, "],\"gpuTimingUnavailableReasons\":[")) return 0;
    for (int index = 0; index < SAMPLE_COUNT; index++) {
        if (index && !json_append(json, ",")) return 0;
        if (workload->samples[index].gpu_valid) {
            if (!json_append(json, "null")) return 0;
        } else if (!json_ascii_string(json, workload->samples[index].gpu_reason)) return 0;
    }
    return json_append(json, "]}");
}

static int publish_json(const wchar_t *output, const wchar_t *temporary, const Graphics *graphics,
                        const Workload workloads[3]) {
    JSONBuffer json = {calloc(JSON_CAPACITY, 1), 0, JSON_CAPACITY};
    if (!json.data) {
        fprintf(stderr, "The graphics benchmark JSON could not be allocated.\n");
        return 0;
    }
    int formatted = json_append(&json, "{\"schemaVersion\":1,\"workloadVersion\":\"d3d11-v1\","
        "\"pointerBits\":64,\"width\":%u,\"height\":%u,\"rendersPerBatch\":%u,\"featureLevel\":45056,"
        "\"vendorID\":%u,\"deviceID\":%u,\"adapterDescription\":", IMAGE_WIDTH, IMAGE_HEIGHT,
        RENDERS_PER_BATCH, graphics->adapter.VendorId, graphics->adapter.DeviceId) &&
        json_wide_string(&json, graphics->adapter.Description) &&
        json_append(&json, ",\"d3d11Module\":") && json_wide_string(&json, graphics->d3d11_module) &&
        json_append(&json, ",\"dxgiModule\":") && json_wide_string(&json, graphics->dxgi_module) &&
        json_append(&json, ",\"workloads\":[");
    for (int index = 0; formatted && index < 3; index++) {
        formatted = (!index || json_append(&json, ",")) && format_workload(&json, &workloads[index]);
    }
    formatted = formatted && json_append(&json, "]}\n");
    if (!formatted) {
        free(json.data);
        return 0;
    }
    HANDLE file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        free(json.data);
        return windows_failure("CreateFileW for graphics benchmark JSON");
    }
    DWORD written;
    int success = 1;
    if (!WriteFile(file, json.data, (DWORD)json.length, &written, NULL)) {
        windows_failure("WriteFile for graphics benchmark JSON");
        success = 0;
    } else if (written != json.length) {
        fprintf(stderr, "The graphics benchmark JSON write was incomplete.\n");
        success = 0;
    }
    free(json.data);
    if (success && !FlushFileBuffers(file)) {
        windows_failure("FlushFileBuffers for graphics benchmark JSON");
        success = 0;
    }
    if (!CloseHandle(file)) {
        windows_failure("CloseHandle for graphics benchmark JSON");
        success = 0;
    }
    if (success && !MoveFileExW(temporary, output, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        windows_failure("MoveFileExW for completed graphics benchmark JSON");
        success = 0;
    }
    if (!success && !DeleteFileW(temporary)) windows_failure("DeleteFileW for incomplete graphics benchmark JSON");
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
        fprintf(stderr, "Usage: traverse-graphics-benchmark.exe <absolute Windows output JSON path>\n");
        return 1;
    }
    if (sizeof(void *) * 8 != 64) {
        fprintf(stderr, "This graphics benchmark requires a 64-bit Windows build.\n");
        return 1;
    }
    Graphics graphics = {0};
    Workload workloads[3] = {
        {.name = "draw-calls", .task = "tiled-image", .draw_calls = TILE_COUNT, .vertices = TILE_COUNT * 6, .kind = 0},
        {.name = "instanced-draw", .task = "tiled-image", .draw_calls = 1, .vertices = TILE_COUNT * 6, .kind = 1},
        {.name = "shader-fill", .task = "integer-shader-image", .draw_calls = 1, .vertices = 3, .kind = 2},
    };
    BYTE *tiled_reference = NULL;
    BYTE *fill_reference = NULL;
    wchar_t *temporary = NULL;
    int success = 0;
    if (!initialize_graphics(&graphics)) goto cleanup;
    tiled_reference = reference_image(0);
    fill_reference = reference_image(1);
    if (!tiled_reference || !fill_reference) goto cleanup;
    for (int index = 0; index < 3; index++) {
        if (!benchmark_workload(&graphics, &workloads[index], index == 2 ? fill_reference : tiled_reference)) goto cleanup;
    }
    size_t capacity = wcslen(argv[1]) + 64;
    temporary = calloc(capacity, sizeof(wchar_t));
    if (!temporary) {
        fprintf(stderr, "The graphics benchmark temporary path could not be allocated.\n");
        goto cleanup;
    }
    if (swprintf(temporary, capacity, L"%ls.traverse-graphics-%lu.tmp", argv[1], GetCurrentProcessId()) < 0) {
        fprintf(stderr, "The graphics benchmark temporary path could not be formatted.\n");
        goto cleanup;
    }
    success = publish_json(argv[1], temporary, &graphics, workloads);

cleanup:
    free(temporary);
    free(fill_reference);
    free(tiled_reference);
    release_graphics(&graphics);
    if (success) puts("Direct3D 11 graphics benchmark passed.");
    return success ? 0 : 1;
}
