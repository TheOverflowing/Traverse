#!/bin/bash
set -euo pipefail

if test "$#" -ne 4 && test "$#" -ne 5; then
    printf 'Usage: bash scripts/build-dxmt-local.sh DXMT_SOURCE LLVM15_PREFIX WINE_SDK BUILD_DIR [STAGE_DIR]\n' >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DXMT_SOURCE="$(cd "$1" && pwd -P)"
LLVM15_PREFIX="$(cd "$2" && pwd -P)"
WINE_SDK="$(cd "$3" && pwd -P)"
if test "$(git -C "$DXMT_SOURCE" rev-parse HEAD)" != 589adb780354b461645b29999cefaf533594ee99; then
    printf 'Use a DXMT source checkout at the exact v0.80 commit.\n' >&2
    exit 1
fi
if test ! -f "$LLVM15_PREFIX/lib/libLLVMCore.a"; then
    printf 'LLVM15_PREFIX must contain x86_64 LLVM 15 headers and static libraries.\n' >&2
    exit 1
fi
if test "$(meson --version)" != 1.10.0; then
    printf 'Use Meson 1.10.0 from the prepared build environment.\n' >&2
    exit 1
fi

for dxmt_patch in "$REPO_ROOT/native/patches/dxmt-xcode27-metal.patch" \
                  "$REPO_ROOT/native/patches/dxmt-v0.80-div-reciprocal.patch" \
                  "$REPO_ROOT/native/patches/dxmt-v0.80-redundant-state.patch" \
                  "$REPO_ROOT/native/patches/dxmt-v0.80-background-frame-rate.patch"; do
    if ! git -C "$DXMT_SOURCE" apply --reverse --check "$dxmt_patch" >/dev/null 2>&1; then
        git -C "$DXMT_SOURCE" apply --check "$dxmt_patch"
        git -C "$DXMT_SOURCE" apply "$dxmt_patch"
    fi
done

mkdir -p "$4"
BUILD_PATH="$(cd "$4" && pwd -P)"
mkdir -p "${5:-$BUILD_PATH/stage}"
STAGE_PATH="$(cd "${5:-$BUILD_PATH/stage}" && pwd -P)"
LLVM_STATIC_PREFIX="$BUILD_PATH/llvm-static"
mkdir -p "$LLVM_STATIC_PREFIX/lib"
ln -sfn "$LLVM15_PREFIX/include" "$LLVM_STATIC_PREFIX/include"
# The official LLVM archive also ships libc++/libunwind dylibs. Keep the
# converter linked to the macOS system C++ runtime, as in the measured builds.
for llvm_archive in "$LLVM15_PREFIX"/lib/libLLVM*.a; do
    ln -sf "$llvm_archive" "$LLVM_STATIC_PREFIX/lib/"
done

cat > "$BUILD_PATH/uniform-win64.ini" <<'CROSS'
[binaries]
c = 'x86_64-w64-mingw32-gcc'
cpp = 'x86_64-w64-mingw32-g++'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
windres = 'x86_64-w64-mingw32-windres'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[built-in options]
cpp_args = ['-include', 'iomanip']
CROSS

cat > "$BUILD_PATH/uniform-native.ini" <<'NATIVE'
[binaries]
c = '/usr/bin/clang'
cpp = '/usr/bin/clang++'

[built-in options]
c_args = ['-mmacosx-version-min=14.0']
cpp_args = ['-mmacosx-version-min=14.0']
c_link_args = ['-mmacosx-version-min=14.0']
cpp_link_args = ['-mmacosx-version-min=14.0']
NATIVE

unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ARCHFLAGS
SETUP_ARGS=(setup)
if test -f "$BUILD_PATH/meson-private/coredata.dat"; then SETUP_ARGS+=(--reconfigure); fi
meson "${SETUP_ARGS[@]}" "$BUILD_PATH" "$DXMT_SOURCE" \
    --cross-file "$BUILD_PATH/uniform-win64.ini" \
    --native-file "$BUILD_PATH/uniform-native.ini" \
    -Dnative_llvm_path="$LLVM_STATIC_PREFIX" -Dwine_install_path="$WINE_SDK" \
    -Dwine_builtin_dll=true -Denable_nvapi=false -Denable_nvngx=false \
    "-Dcpp_args=['-include', 'iomanip']" \
    -Denable_tests=false --buildtype release --prefix "$STAGE_PATH" --strip
meson compile -C "$BUILD_PATH" -j 2
meson install -C "$BUILD_PATH"
find "$STAGE_PATH" -name '*.a' -delete
git -C "$DXMT_SOURCE" diff --binary > "$BUILD_PATH/source.diff"
printf 'Built local DXMT payload: %s\n' "$STAGE_PATH"
