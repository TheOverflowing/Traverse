#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror -shared -static-libgcc \
    -DTRAVERSE_D3DMETAL native/ffxiv-dxgi-scanline.c native/ffxiv-dxgi-scanline.def \
    -ldxguid -o Sources/TraverseCore/Resources/ffxiv-dxgi.dll
