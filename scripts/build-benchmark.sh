#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    printf 'Install the Windows compiler first: brew install mingw-w64\n' >&2
    exit 1
fi
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror -municode -static -Wl,--no-insert-timestamp \
    native/traverse-benchmark.c \
    -o Sources/TraverseCore/Resources/traverse-benchmark.exe
