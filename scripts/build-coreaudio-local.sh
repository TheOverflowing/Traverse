#!/bin/bash
set -euo pipefail
if [ "$#" -ne 4 ]; then
    printf 'Usage: bash scripts/build-coreaudio-local.sh WINE_SOURCE WINE_SDK ENGINE_ROOT BUILD_DIR\n' >&2
    exit 1
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
wine_source="$(cd "$1" && pwd -P)"
wine_sdk="$(cd "$2" && pwd -P)"
engine_root="$(cd "$3" && pwd -P)"
mkdir -p "$4"
build_root="$(cd "$4" && pwd -P)"
mkdir -p "$build_root/generated"
cp "$wine_source/dlls/winecoreaudio.drv/coreaudio.c" "$build_root/coreaudio.c"
patch "$build_root/coreaudio.c" "$repo_root/native/patches/wine-11-coreaudio-device-period.patch"
cat > "$build_root/config.h" <<'CONFIG'
#define HAVE_AVFOUNDATION_AVFOUNDATION_H 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_UNISTD_H 1
#define HAVE_PTHREAD_H 1
#define PACKAGE_VERSION "11.0"
#define WIN32_LEAN_AND_MEAN
#define _WINE 1
CONFIG
for interface in objidl objidlbase unknwn oaidl ocidl propidl propsys mmdeviceapi \
    audioclient audiopolicy devicetopology wtypes oleidl servprov urlmon msxml shtypes \
    structuredquerycondition; do
    "$wine_sdk/bin/widl" --win64 --nostdinc -I "$wine_source/include" -h \
        -o "$build_root/generated/$interface.h" "$wine_source/include/$interface.idl"
done
cd "$build_root"
flags=(-arch x86_64 -mmacosx-version-min=14.0 -O2 -fPIC -D__WINESRC__ -DWINE_UNIX_LIB -D_WIN64 \
    -I . -I generated -I "$wine_source/include" -I "$wine_sdk/include/wine/windows" \
    -I "$wine_source/dlls/winecoreaudio.drv" -Wno-pragma-pack)
clang "${flags[@]}" -c coreaudio.c -o coreaudio.o
clang "${flags[@]}" -c "$wine_source/dlls/winecoreaudio.drv/coremidi.c" -o coremidi.o
clang "${flags[@]}" -fblocks -c "$wine_source/dlls/winecoreaudio.drv/authorization.m" -o authorization.o
clang -arch x86_64 -mmacosx-version-min=14.0 -dynamiclib coreaudio.o coremidi.o authorization.o \
    "$engine_root/lib/wine/x86_64-unix/ntdll.so" -framework CoreAudio -framework AudioUnit \
    -framework AudioToolbox -framework CoreMIDI -framework AppKit -framework AVFoundation \
    -Wl,-install_name,@rpath/winecoreaudio.so -Wl,-rpath,@loader_path -o winecoreaudio.so
codesign --force --sign - winecoreaudio.so
for source in coreaudio.c "$wine_source/dlls/winecoreaudio.drv/coremidi.c" \
    "$wine_source/dlls/winecoreaudio.drv/authorization.m"; do
    clang "${flags[@]}" -MM "$source" > "$(basename "$source").d"
done
printf 'Built %s\n' "$build_root/winecoreaudio.so"
