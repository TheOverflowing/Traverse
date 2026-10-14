# Traverse

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/brand/traverse-logo-inverse.png">
  <img src="assets/brand/traverse-logo.png" alt="Traverse" width="320">
</picture>

A native macOS launchpad for Windows applications on Apple Silicon, built with
SwiftUI and Wine.

Traverse discovers installed Steam games and Windows shortcuts, keeps a searchable
application library, and launches applications through a managed Wine 11 MSync
engine. It supports per-application graphics settings, Windows installers,
executable Java archives, and framework-dependent x64 .NET 8 applications.

## Requirements

- Apple Silicon Mac with macOS 14 or later.
- Xcode command-line tools with Swift 6 or later.
- MinGW-w64 to build the Windows helpers.
- Rosetta 2 to run the Wine engine's x86-64 macOS components.
- Internet access for the first engine installation and optional runtime downloads.

The managed DXMT and D3DMetal graphics backends require macOS 26 or later.
D3DMetal requires a 64-bit Windows executable; Auto falls back for 32-bit apps.
Application compatibility depends on the application and selected backend.

## Build and run

Install the build tools and Rosetta if needed:

```sh
xcode-select --install
brew install mingw-w64
softwareupdate --install-rosetta
```

Build the app from the repository root:

```sh
bash scripts/build-app.sh
open dist/Traverse.app
```

The build creates `dist/Traverse.app` and the `dist/traverse` CLI. It compiles the
native helpers, builds all Swift executables, packages the icon and runtime
resources, and signs the application locally with an ad-hoc signature.

The app downloads its managed Wine engine and matching source archive when needed.
Steam, Java, .NET, and D3DMetal are downloaded separately when their features are
used. Downloads are checked against pinned hashes.

## Use

Choose **Steam** to install or open Windows Steam. Sign in through Steam's own
window, then refresh the library to discover installed games.

Choose **Add Application** to select an executable, installer, Java archive, or
Windows shortcut. Imported files remain in their original locations. Removing a
library entry hides or removes its launcher; it does not uninstall the application.

Right-click an application to change its icon or graphics settings. Available
backends are Auto, D3DMetal, DXMT, DXVK, and Wine. Application Auto follows the
default in **Settings → Graphics**. Restart applications after changing graphics,
frame limits, fonts, display scaling, or engine settings.

**Settings → Fusion Mode** adds a menu bar icon and macOS launchers under
`~/Applications/Traverse` for Finder and Spotlight. It also offers Windows file
associations through macOS's default-application controls. Turning Fusion Mode
off removes the generated launchers; existing file associations stay assigned.

**Settings → Windows Display** enables optional Retina rendering with 200%
scaling. **Settings → Windows Text** selects a Chinese-capable font installed on
the Mac. Java applications use the managed Windows x64 Temurin 17 runtime;
applications requiring newer Java versions need a different runtime.

## CLI

```sh
dist/traverse doctor
dist/traverse install
dist/traverse launch
dist/traverse apps
dist/traverse add "/absolute/path/Application.exe" "Application"
dist/traverse open <application-id>
dist/traverse graphics <application-id> status
dist/traverse frame-limit 60
```

Use an application ID returned by `apps` or `add`. Run `dist/traverse help` for
available commands. `dist/traverse stop` stops the Steam environment through its
selected engine's wineserver.

Engine files, Windows environments, downloaded runtimes, the catalog, and logs
live in `~/Library/Application Support/Traverse/`. Steam uses `Bottles/Steam`;
applications outside an existing managed environment use `Bottles/Windows`.

## Source layout

- `Sources/TraverseApp`: native SwiftUI application.
- `Sources/TraverseCore`: shared application catalog, runtime, and graphics support.
- `Sources/TraverseCLI`: command-line interface.
- `Sources/TraverseLauncher`: macOS application launcher executable.
- `Sources/TraverseCore/Resources`: required graphics and audio overlays and their
  corresponding source and license archives.
- `native`: helper source and patches for bundled components.
- `scripts`: application build and component rebuild scripts.
- `assets/brand`: packaged app icon and README logos.

The component rebuild scripts accept external upstream source trees and SDKs;
run each script without arguments to see its required inputs. The ordinary app
build uses the bundled graphics and audio overlays and does not require rebuilding
Wine, DXMT, or DXVK. The resource archives retain component source information,
build records, and license notices.

## License

Traverse's own source is [MIT licensed](LICENSE). Wine and other third-party
components retain their upstream licenses. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the bundled source archives
for component notices and corresponding source information.
