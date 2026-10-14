#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
clang -arch x86_64 -mmacosx-version-min=14.0 -O2 -Wall -Wextra \
    -dynamiclib native/application-dock-identity.c -lobjc \
    -o Sources/TraverseCore/Resources/application-dock-identity.dylib
codesign --force --sign - Sources/TraverseCore/Resources/application-dock-identity.dylib
