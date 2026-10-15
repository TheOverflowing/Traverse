#include <windows.h>
#include <stddef.h>

/* Steam Audio 4.x ABI prefix; the remaining parameters pass through untouched. */
struct path_parameters {
    float eq[3];
    float *sh_coefficients;
};
struct audio_buffer {
    int channels;
    int samples;
    float **data;
};
_Static_assert(offsetof(struct path_parameters, sh_coefficients) == 16, "Steam Audio x64 ABI");

typedef int (*apply_function)(void *, struct path_parameters *, struct audio_buffer *, struct audio_buffer *);
typedef int (*tail_function)(void *, struct audio_buffer *);
static apply_function original_apply;
static tail_function original_tail;
static INIT_ONCE initialized = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK resolve_original(PINIT_ONCE once, void *parameter, void **context)
{
    (void)once;
    (void)parameter;
    (void)context;
    /* Forwarded context/effect exports have already loaded the original DLL. */
    HMODULE original = GetModuleHandleW(L"phonon_traverse_original.dll");
    if (!original) return FALSE;
    original_apply = (apply_function)(void *)GetProcAddress(original, "iplPathEffectApply");
    original_tail = (tail_function)(void *)GetProcAddress(original, "iplPathEffectGetTail");
    return original_apply && original_tail;
}

int traverse_path_effect_apply(void *effect, struct path_parameters *parameters,
                              struct audio_buffer *input, struct audio_buffer *output)
{
    if (!InitOnceExecuteOnce(&initialized, resolve_original, NULL, NULL)) {
        RaiseException(0xc0000135 /* STATUS_DLL_NOT_FOUND */, EXCEPTION_NONCONTINUABLE, 0, NULL);
    }
    /* UE's old spatializer can render once more after its simulation source is
       removed. Drain the existing effect instead of dereferencing absent SH data. */
    if (parameters && !parameters->sh_coefficients)
        return original_tail(effect, output);
    return original_apply(effect, parameters, input, output);
}
