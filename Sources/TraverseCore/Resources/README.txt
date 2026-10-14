steamwebhelper-bridge.exe is generated from native/steamwebhelper-bridge.c by
scripts/build-bridge.sh. The bridge is Traverse source under the MIT license.

window-activate.exe is generated from native/window-activate.c by
scripts/build-window-activate.sh. It activates an existing application window
within the selected Wine prefix.

application-dock-identity.dylib is generated from
native/application-dock-identity.c by scripts/build-dock-identity.sh. It selects
the macOS identity for Wine child processes and preserves the launcher's icon
when Wine updates its Dock artwork.

winecoreaudio-traverse-period.so applies the Wine 11 CoreAudio device-period
repair to the managed Grapple engine. wine-coreaudio-device-period-source.tar.gz
retains its modified source, headers, patch, build script, build record, and
LGPL license. scripts/build-coreaudio-local.sh rebuilds the driver. The installer
keeps the original driver and installs the corresponding source archive beside
the engine.

dsound-traverse-sse2.dll rebuilds the retained Wine 11 DirectSound source with
SSE2 arithmetic for 32-bit Rosetta playback. wine-dsound-sse2-source.tar.gz
retains its source, build inputs, script, record, and LGPL licenses. The
installer preserves the original i386 dsound.dll and installs the source
archive beside the engine. scripts/build-dsound-local.sh rebuilds the DLL.

ffxiv-dxgi.dll is generated from native/ffxiv-dxgi-scanline.c and its .def
file by scripts/build-ffxiv-dxgi.sh. It forwards to the installed D3DMetal DXGI
builtin and normalizes FFXIV's initial display-mode list. The game EXE is not
modified. This shim is Traverse source under the MIT license.

traverse-benchmark.exe is generated from native/traverse-benchmark.c by
scripts/build-benchmark.sh. It measures fixed Win32 CPU, event synchronization,
and file-write workloads.

traverse-graphics-benchmark.exe is generated from
native/traverse-graphics-benchmark.c by scripts/build-graphics-benchmark.sh.
It measures completed offscreen D3D11 workloads and verifies rendered pixels.
All helpers are built by scripts/build-app.sh.

dxmt-v0.80-traverse-div-reciprocal.tar.gz contains the patched DXMT v0.80
x86/x64 builtin DLLs and matching Unix companion. The default MSync installer
verifies this bundled archive and retains its manifest, source patches, build
metadata, and component licenses beside the engine. Build provenance is retained in the archive's Sources/ directory.
Overlay revision 2 adds unchanged-state submission deduplication to both D3D11
DLLs. The DIV repair and shader cache version 19 remain in place. The other
seven payloads and component licenses are unchanged.

Overlay revision 3 adds optional DXMT background frame rate limits to both
D3D11 DLLs. Traverse enables a limit of at most 30 FPS in the background when
the user enables a foreground cap. The other seven payloads, existing repairs,
shader-cache version, and licenses are retained.

Overlay revision 4 applies the background cap only to minimized or hidden
windows. Visible windows retain their selected cap even when another window
has input focus. Only the two D3D11 DLLs change from revision 3.

dxvk-v1.10.3-traverse-power.tar.gz contains native x64/x32 DXVK D3D11 DLLs
with the Wine frame-wait patch and the original D3D10 core DLLs. Generic
graphics profiles and BAD END THEATER use the same verified package. Its
Sources/ and Licenses/ directories retain the exact upstream commit, patch,
build helper, build records, mechanism tests, and component notices. DXVK
revision 2 adds an optional minimized/hidden-window cap using
DXVK_BACKGROUND_FRAME_RATE, preserving the original visible-window limiter.
