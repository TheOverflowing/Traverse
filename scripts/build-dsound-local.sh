#!/bin/bash
set -euo pipefail

if [[ $# != 3 ]]; then
    echo "Usage: $0 WINE_SOURCE WINE_SDK BUILD_DIR" >&2
    exit 1
fi
wine_source=$(cd "$1" && pwd)
wine_sdk=$(cd "$2" && pwd)
mkdir -p "$3"
build_dir=$(cd "$3" && pwd)
module="$wine_source/dlls/dsound"
mkdir -p "$build_dir/generated"
for name in objidl objidlbase unknwn oaidl ocidl propidl propsys mmdeviceapi audioclient \
    audiopolicy devicetopology wtypes oleidl servprov urlmon msxml shtypes structuredquerycondition; do
    "$wine_sdk/bin/widl" --win32 --nostdinc -I "$wine_source/include" -h \
        -o "$build_dir/generated/$name.h" "$wine_source/include/$name.idl"
done

"$wine_sdk/bin/widl" -m32 -r -o "$build_dir/dsound_classes.res" "$module/dsound_classes.idl"
"$wine_sdk/bin/wrc" -I "$wine_source/include" -I "$wine_sdk/include/wine/windows" \
    -o "$build_dir/version.res" "$module/version.rc"
sources=()
for name in buffer capture dsound dsound_convert dsound_main duplex mixer primary propset sound3d; do
    sources+=("$module/$name.c")
done
# WoW64 runs these floating-point loops through Rosetta. SSE2 avoids the
# expensive x87 path while preserving the existing resampler and filter.
"$wine_sdk/bin/winegcc" -b i686-w64-mingw32 -shared -O2 -msse2 -mfpmath=sse \
    -D__WINESRC__ -I "$wine_source/include" -I "$build_dir/generated" -I "$wine_sdk/include/wine/windows" \
    "$module/dsound.spec" "${sources[@]}" "$build_dir/dsound_classes.res" "$build_dir/version.res" \
    -ldxguid -luuid -lwinmm -lole32 -ladvapi32 -luser32 -o "$build_dir/dsound.dll"
"$wine_sdk/bin/winebuild" --builtin "$build_dir/dsound.dll"
