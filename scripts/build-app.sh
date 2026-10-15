#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-bridge.sh
bash scripts/build-benchmark.sh
bash scripts/build-graphics-benchmark.sh
bash scripts/build-window-activate.sh
bash scripts/build-dock-identity.sh
bash scripts/build-ffxiv-dxgi.sh
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Traverse.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Traverse" "$app/Contents/MacOS/Traverse"
cp "$bin_dir/TraverseLauncher" "$app/Contents/Resources/TraverseLauncher"
codesign --force --sign - "$app/Contents/Resources/TraverseLauncher"
cp assets/brand/Traverse.icns "$app/Contents/Resources/TraverseFold.icns"
cp "$bin_dir/traverse-cli" dist/traverse
for resource in "$bin_dir"/*.bundle; do
    cp -R "$resource" "$app/Contents/Resources/"
    cp -R "$resource" dist/
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Traverse</string>
<key>CFBundleIdentifier</key><string>org.traverse.Traverse</string>
<key>CFBundleName</key><string>Traverse</string>
<key>CFBundleDisplayName</key><string>Traverse</string>
<key>CFBundleIconFile</key><string>TraverseFold.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><true/>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>org.traverse.launch</string>
<key>CFBundleURLSchemes</key><array><string>traverse</string></array>
<key>CFBundleTypeRole</key><string>Viewer</string>
</dict></array>
<key>CFBundleDocumentTypes</key><array>
<dict>
<key>CFBundleTypeName</key><string>Windows Application</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.microsoft.windows-executable</string></array>
<key>CFBundleTypeExtensions</key><array><string>exe</string></array>
</dict>
<dict>
<key>CFBundleTypeName</key><string>Windows Installer</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.microsoft.msi-installer</string></array>
<key>CFBundleTypeExtensions</key><array><string>msi</string></array>
</dict>
<dict>
<key>CFBundleTypeName</key><string>Windows Shortcut</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.microsoft.windows-shortcut</string></array>
<key>CFBundleTypeExtensions</key><array><string>lnk</string></array>
</dict>
<dict>
<key>CFBundleTypeName</key><string>Java Application</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.sun.java-archive</string></array>
<key>CFBundleTypeExtensions</key><array><string>jar</string></array>
</dict>
</array>
<key>UTImportedTypeDeclarations</key><array>
<dict>
<key>UTTypeIdentifier</key><string>com.microsoft.msi-installer</string>
<key>UTTypeDescription</key><string>Windows Installer</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
<key>UTTypeTagSpecification</key><dict>
<key>public.filename-extension</key><array><string>msi</string></array>
</dict>
</dict>
<dict>
<key>UTTypeIdentifier</key><string>com.microsoft.windows-shortcut</string>
<key>UTTypeDescription</key><string>Windows Shortcut</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
<key>UTTypeTagSpecification</key><dict>
<key>public.filename-extension</key><array><string>lnk</string></array>
</dict>
</dict>
</array>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>org.traverse.application-id</string>
<key>UTTypeDescription</key><string>Traverse Application</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf 'Built %s\n' "$app"
