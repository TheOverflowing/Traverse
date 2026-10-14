# Third-party components

The separately supported stock Wine 11.0_1 macOS binary package comes from
[Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds).
Wine is licensed under LGPL-2.1-or-later. Its source and license are available
from the [Wine 11.0 source tree](https://github.com/wine-mirror/wine/tree/wine-11.0)
and [COPYING.LIB](https://github.com/wine-mirror/wine/blob/wine-11.0/COPYING.LIB).
The macOS package also contains dependencies whose licenses remain applicable;
see the packager's dependency list. This repository distributes Traverse source,
and does not vendor or relicense the downloaded Wine archive.

Steam and its original webhelper are Valve software. They are downloaded from
Valve's official servers, remain subject to Valve's terms, and are not included
in this source repository.

The single-process CEF workaround was informed by the original investigation in
[3Shain/dxmt issue 141](https://github.com/3Shain/dxmt/issues/141) and
[notpop/steam-on-m1-wine](https://github.com/notpop/steam-on-m1-wine), which is MIT
licensed, copyright 2026 notpop. Traverse's bridge uses the Win32 process APIs
and preserves the original command-line arguments.

The Windows helpers are built with MinGW-w64. The compiler and runtime licenses, including
the GCC Runtime Library Exception where applicable, remain applicable to that
build toolchain and its runtime code.

The bundled DXVK profile uses
[Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) release
`v1.10.3-20230507-repack`, commit `8f1e28deed3ad30802f7e1bdff428ec14e6e7817`.
DXVK is licensed under the
[Zlib license](https://github.com/Gcenx/DXVK-macOS/blob/1.10.x/LICENSE).
The native x64/x32 D3D11 DLLs include Traverse's Wine frame-wait and
minimized/hidden-window pacing patches; both
D3D10 core DLLs are retained from the original release. The resource archive
includes the source patch, upstream source URL, build records, and DXVK,
OpenVR, MinGW-w64, and GCC runtime notices. The generic DXVK backend and
BAD END THEATER compatibility profile share this package.
Wine's packaged MoltenVK supplies Vulkan-to-Metal support;
its [Apache-2.0 license](https://github.com/KhronosGroup/MoltenVK/blob/main/LICENSE)
and dependency notices remain applicable.

The default MSync engine downloads the independently built
[Grapple Wine 1.0.2 engine and matching source](https://github.com/MartijnBud/grapple-releases/releases/tag/v0.2.5-beta.1).
It is based on CodeWeavers' published
[CrossOver 26.3.0 FOSS source](https://www.codeweavers.com/crossover/source),
using its Wine 11.0 tree under LGPL-2.1-or-later. This is an independent Wine
package rather than a copy of the installed CrossOver application. Its three
Wine patches change Steam browser arguments, launcher Dock grouping, and
directory change notifications; the corresponding source and build scripts
are retained with the installation. Traverse enables the existing
[MSync implementation](https://github.com/marzent/wine-msync), whose original
patch set is LGPL-2.1-or-later.

Traverse's managed CoreAudio companion applies the device-period correction
from [Wine MR11681](https://gitlab.winehq.org/wine/wine/-/merge_requests/11681)
to the retained Wine 11 source. The modified driver is LGPL-2.1-or-later.
Its corresponding source, build inputs, patch, and licenses are bundled in
`wine-coreaudio-device-period-source.tar.gz` and retained beside the installed
engine. The original driver is preserved in `Originals/winecoreaudio.so`.

The managed 32-bit DirectSound companion rebuilds the same Wine 11 source
with SSE2 floating-point arithmetic. It retains Wine's existing resampler,
COM registration, and version resources. Corresponding module source, build
inputs, the linked Wine 8.17 SDK WineCRT0 source, and LGPL licenses are bundled
in `wine-dsound-sse2-source.tar.gz`. Installation retains that archive under
`Sources/wine-11-dsound-sse2-1/` and the original DLL in `Originals/dsound.dll`.

The package stages DXMT v0.80, whose
[version-specific LICENSE](https://github.com/3Shain/dxmt/blob/v0.80/LICENSE)
is MIT, with separate Zlib notices for DXVK-derived code. Its LLVM 15.0.7 code
uses [Apache-2.0 with the LLVM exception](https://github.com/llvm/llvm-project/blob/llvmorg-15.0.7/llvm/LICENSE.TXT).
Wine Mono 10.4.1 uses MIT/BSD terms; Wine Gecko 2.47.4 uses MPL-2.0. GStreamer
1.28.7, GLib, and the bundled FFmpeg LGPL build retain their respective LGPL
terms. The matching source package's `DEPENDENCIES.md` provides the remaining
library origins, licenses, and source links. Some dependency versions in that
table are approximate; for example, the actual libpng binary is 1.6.56.

Traverse also bundles a locally rebuilt DXMT v0.80 graphics update for both
Windows architectures. It applies the documented DIV/cache-version patch and
upstream Xcode 27 compatibility change, state submission deduplication, and
optional background frame rate limits. The resource archive includes the
DXMT MIT, DXVK Zlib, LLVM 15, Wine SDK, MinGW-w64, and GCC runtime license texts,
matching source references, build metadata, and exact patches. The installer
retains these beside the original source package. This update replaces DXMT
payloads and their Wine companions; it does not replace the Wine core.

The installer preserves the complete matching source archive, its contents,
and the actual Wine, DXMT, and DXVK-derived license texts beside the engine.
The source package contains the original Wine source, all three supplied Wine
patches, DXMT source, and the build/package scripts. Grapple's older
source-offer prose claiming an unmodified Wine tree is superseded by those
supplied patch files and build script. The proprietary D3DMetal component is a
separate release asset. Selecting D3DMetal downloads the SHA-256 pinned
`d3dmetal-4.0-beta-2.tar.xz` component from the matching Grapple release.
It is stored separately from the Wine engine, with Apple's notices and license
files retained unchanged. Traverse's app bundle does not include that archive.
The locally built FFXIV DXGI shim is Traverse source under the MIT license.

## Managed Java runtime

Opening a Java archive downloads the Windows x64 Eclipse Temurin JRE
17.0.20.1+1 from the official
[Temurin release](https://github.com/adoptium/temurin17-binaries/releases/tag/jdk-17.0.20.1%2B1).
The ZIP is pinned to SHA-256
`bc21a93923103cdaac93ee337b0ae4365e739fde36df823dd456bc67c8a9d352`.
Its complete `legal` directory, release metadata, and runtime files remain
under Traverse's `Runtimes/Java` directory. OpenJDK is licensed under GPLv2
with the Classpath Exception, with component-specific notices included there;
source packages are available from the same Temurin release. The Java package
is downloaded separately and is not embedded in Traverse's app bundle.
Java reads the selected Wine engine's existing TrueType fonts and the macOS
system fonts in place. Traverse does not copy, bundle, or relicense those fonts.
The generated logical-font configuration retains the pinned JRE template's
original copyright and GPLv2 with Classpath Exception notice.

## Managed modern .NET runtime

Framework-dependent x64 .NET 8 applications can download Microsoft's .NET runtime
and Windows Desktop runtime 8.0.32 ZIPs separately from the application bundle.
The packages come from Microsoft's dotnetcli.blob.core.windows.net distribution
and are verified against the published SHA-512 hashes in
[Microsoft's release metadata](https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/8.0/releases.json).
The extracted runtime retains its `LICENSE.txt` and `ThirdPartyNotices.txt`.
.NET is MIT-licensed, with component notices included in the distribution.
[Runtime source](https://github.com/dotnet/runtime) and
[Windows Desktop source](https://github.com/dotnet/windowsdesktop) are available
from Microsoft. Neither runtime package is embedded in Traverse's app bundle.
