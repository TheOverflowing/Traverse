#!/bin/bash
set -euo pipefail

if test "$#" -ne 2 && test "$#" -ne 3; then
    printf 'Usage: bash scripts/build-dxvk-local.sh DXVK_SOURCE BUILD_ROOT [STAGE_DIR]\n' >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DXVK_SOURCE="$(cd "$1" && pwd -P)"
if test "$(git -C "$DXVK_SOURCE" rev-parse HEAD)" != 8f1e28deed3ad30802f7e1bdff428ec14e6e7817; then
    printf 'Use the Gcenx/DXVK-macOS v1.10.3-20230507-repack source checkout.\n' >&2
    exit 1
fi
if test "$(meson --version)" != 1.10.0; then
    printf 'Use Meson 1.10.0 from the prepared build environment.\n' >&2
    exit 1
fi
command -v glslangValidator >/dev/null

for dxvk_patch in "$REPO_ROOT/native/patches/dxvk-v1.10.3-wine-frame-wait.patch" \
                  "$REPO_ROOT/native/patches/dxvk-v1.10.3-background-frame-rate.patch"; do
    if ! git -C "$DXVK_SOURCE" apply --reverse --check "$dxvk_patch" >/dev/null 2>&1; then
        git -C "$DXVK_SOURCE" apply --check "$dxvk_patch"
        git -C "$DXVK_SOURCE" apply "$dxvk_patch"
    fi
done

mkdir -p "$2"
BUILD_ROOT="$(cd "$2" && pwd -P)"
mkdir -p "${3:-$BUILD_ROOT/stage}"
STAGE_PATH="$(cd "${3:-$BUILD_ROOT/stage}" && pwd -P)"

unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ARCHFLAGS
for bits in 64 32; do
    BUILD_PATH="$BUILD_ROOT/build-$bits"
    SETUP_ARGS=(setup)
    if test -f "$BUILD_PATH/meson-private/coredata.dat"; then SETUP_ARGS+=(--reconfigure); fi
    meson "${SETUP_ARGS[@]}" "$BUILD_PATH" "$DXVK_SOURCE" \
        --cross-file "$DXVK_SOURCE/build-win$bits.txt" \
        --buildtype release --prefix "$STAGE_PATH" --strip \
        --bindir "x$bits" --libdir "x$bits" \
        -Denable_dxgi=false -Denable_d3d9=false \
        -Denable_d3d10=true -Denable_d3d11=true -Dbuild_id=false
    meson compile -C "$BUILD_PATH" -j 2 d3d11 d3d10core
    meson install -C "$BUILD_PATH" --no-rebuild
done
git -C "$DXVK_SOURCE" diff --binary > "$BUILD_ROOT/source.diff"
printf 'Built local DXVK payloads: %s\n' "$STAGE_PATH"
