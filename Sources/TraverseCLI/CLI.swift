import Foundation
import TraverseCore

@main
struct TraverseCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var root: URL?
        if let index = arguments.firstIndex(of: "--root"), arguments.indices.contains(index + 1) {
            root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            arguments.removeSubrange(index...index + 1)
        }
        let paths = TraversePaths(root: root)
        let runtime = SteamRuntime(paths: paths)
        let library = ApplicationLibrary(paths: paths)
        let command = arguments.first ?? "help"
        do {
            switch command {
            case "doctor": try printJSON(await runtime.doctor())
            case "status": try printJSON(await runtime.status())
            case "benchmark":
                if (arguments.count == 3 || arguments.count == 5), arguments[1] == "run" {
                    let qualityOfService: QualityOfService
                    if arguments.count == 3 { qualityOfService = .default }
                    else if arguments[3] == "--qos", arguments[4] == "default" { qualityOfService = .default }
                    else if arguments[3] == "--qos", arguments[4] == "user-initiated" { qualityOfService = .userInitiated }
                    else { throw TraverseError.message("Use: traverse benchmark run <label> [--qos default|user-initiated]") }
                    try printJSON(try await BenchmarkRuntime(paths: paths).run(label: arguments[2], qualityOfService: qualityOfService) {
                        FileHandle.standardError.write(Data("\($0)\n".utf8))
                    })
                } else if arguments.count == 4, arguments[1] == "compare" {
                    let baseline = try BenchmarkReport.load(from: URL(fileURLWithPath: arguments[2]))
                    let candidate = try BenchmarkReport.load(from: URL(fileURLWithPath: arguments[3]))
                    try printJSON(BenchmarkComparison(baseline: baseline, candidate: candidate))
                } else {
                    throw TraverseError.message("Use: traverse benchmark run <label> [--qos default|user-initiated] | benchmark compare <baseline.json> <candidate.json>")
                }
            case "graphics-benchmark":
                if arguments.count == 4, arguments[1] == "run", let backend = GraphicsBackend(rawValue: arguments[2]) {
                    try printJSON(try await GraphicsBenchmarkRuntime(paths: paths).run(label: arguments[3], backend: backend) {
                        FileHandle.standardError.write(Data("\($0)\n".utf8))
                    })
                } else if arguments.count == 4, arguments[1] == "compare" {
                    try printJSON(GraphicsBenchmarkComparison(
                        baseline: GraphicsBenchmarkReport.load(from: URL(fileURLWithPath: arguments[2])),
                        candidate: GraphicsBenchmarkReport.load(from: URL(fileURLWithPath: arguments[3]))))
                } else {
                    throw TraverseError.message("Use: traverse graphics-benchmark run auto|d3dmetal|dxmt|dxvk|wine <label> | graphics-benchmark compare <baseline.json> <candidate.json>")
                }
            case "graphics":
                if arguments.count == 3, arguments[1] == "default" {
                    if arguments[2] == "status" { try printJSON(try await runtime.status().graphicsBackend) }
                    else if let backend = GraphicsBackend(rawValue: arguments[2]) {
                        try await runtime.setGraphicsBackend(backend)
                        try printJSON(backend)
                    } else { throw TraverseError.message("Choose auto, d3dmetal, dxmt, dxvk, or wine.") }
                    break
                }
                guard arguments.count == 3 || arguments.count == 4,
                      let application = try library.applications().first(where: { $0.id == arguments[1] }) else {
                    throw TraverseError.message("Use: traverse graphics <application-id> status|auto|d3dmetal|dxmt|dxvk|wine|gdi [/path/to/game.exe]")
                }
                let applications = WindowsApplicationRuntime(steam: runtime)
                if arguments[2] == "status", arguments.count == 3 {
                    try printJSON(try await applications.graphicsProfile(for: application))
                } else if let backend = GraphicsBackend(rawValue: arguments[2]) {
                    try printJSON(try await applications.setGraphicsBackend(backend, for: application,
                        targetExecutable: arguments.count == 4 ? URL(fileURLWithPath: arguments[3]) : nil) {
                            FileHandle.standardError.write(Data("\($0)\n".utf8))
                        })
                } else { throw TraverseError.message("Choose status, auto, d3dmetal, dxmt, dxvk, or wine.") }
            case "keyboard":
                guard arguments.count == 3,
                      let application = try library.applications().first(where: { $0.id == arguments[1] }) else {
                    throw TraverseError.message("Use: traverse keyboard <application-id> status|direct|text")
                }
                let applications = WindowsApplicationRuntime(steam: runtime)
                if arguments[2] == "direct" || arguments[2] == "text" {
                    try await applications.setDirectKeyboardInput(arguments[2] == "direct", for: application)
                } else if arguments[2] != "status" {
                    throw TraverseError.message("Choose status, direct, or text.")
                }
                try printJSON(try await applications.directKeyboardInput(for: application))
            case "dotnet-startup":
                guard arguments.count == 3,
                      let application = try library.applications().first(where: { $0.id == arguments[1] }) else {
                    throw TraverseError.message("Use: traverse dotnet-startup <application-id> status|on|off")
                }
                let applications = WindowsApplicationRuntime(steam: runtime)
                if arguments[2] == "on" || arguments[2] == "off" {
                    try await applications.setDotnetStartupCompatibility(arguments[2] == "on", for: application)
                } else if arguments[2] != "status" {
                    throw TraverseError.message("Choose status, on, or off.")
                }
                try printJSON(try await applications.dotnetStartupCompatibility(for: application))
            case "apps":
                guard arguments.count == 1 else { throw TraverseError.message("Use: traverse apps") }
                try printJSON(library.applications())
            case "prepare-text":
                guard arguments.count == 1 else { throw TraverseError.message("Use: traverse prepare-text") }
                try await runtime.prepareChineseText { print($0) }
                print("Chinese text support is ready. Restart running Windows applications to apply it.")
            case "text-font":
                guard arguments.count == 2 else { throw TraverseError.message("Use: traverse text-font list|default|<font-id>") }
                if arguments[1] == "list" { try printJSON(WindowsTextFont.available()) }
                else {
                    try await runtime.setWindowsTextFont(arguments[1] == "default" ? nil : arguments[1]) { print($0) }
                    print("Font saved. Restart Windows applications to apply it.")
                }
            case "add":
                guard arguments.count == 2 || arguments.count == 3 else {
                    throw TraverseError.message("Use: traverse add /path/to/application.exe [name]")
                }
                let application = try library.addExecutable(at: URL(fileURLWithPath: arguments[1]),
                    name: arguments.count == 3 ? arguments[2] : nil)
                try printJSON(application)
            case "remove":
                guard arguments.count == 2 else { throw TraverseError.message("Use: traverse remove application-id") }
                try library.remove(id: arguments[1])
                print("Application removed from Traverse.")
            case "open":
                guard arguments.count >= 2, arguments.count <= 4,
                      arguments.dropFirst(2).allSatisfy({ ["--debug", "--wait"].contains($0) }) else {
                    throw TraverseError.message("Use: traverse open application-id [--debug] [--wait]")
                }
                guard let application = try library.applications().first(where: { $0.id == arguments[1] }) else {
                    throw TraverseError.message("That application is not in Traverse. Run traverse apps to list applications.")
                }
                let applications = WindowsApplicationRuntime(steam: runtime)
                let debug = arguments.contains("--debug")
                if arguments.contains("--wait") {
                    guard application.kind == .executable,
                          ["exe", "com", "jar", "msi"].contains(URL(fileURLWithPath: application.executablePath ?? "").pathExtension.lowercased()) else {
                        throw TraverseError.message("Waiting is available for Windows executables, Java applications, and MSI installers.")
                    }
                    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                        Task {
                            do {
                                let session = try await applications.launch(application, debug: debug, requireNewProcess: true,
                                    progress: { FileHandle.standardError.write(Data("\($0)\n".utf8)) },
                                    onExit: { status, _ in continuation.resume(returning: status) })
                                try printJSON(session)
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    exit(status)
                    }
                let session = try await applications.launch(application, debug: debug) {
                    FileHandle.standardError.write(Data("\($0)\n".utf8))
                }
                try printJSON(session)
            case "game-support":
                guard arguments.count == 2, arguments[1] == "bad-end-theater" else {
                    throw TraverseError.message("Use: traverse game-support bad-end-theater")
                }
                try await runtime.installGameSupport { print($0) }
            case "game-status": try printJSON(await runtime.gameSupportStatus())
            case "install-engine":
                if arguments.count == 1 { try await runtime.installEngine { print($0) } }
                else if arguments.count == 2, arguments[1] == "msync" {
                    try await runtime.installMSyncEngine { print($0) }
                } else { throw TraverseError.message("Use: traverse install-engine [msync]") }
            case "install": try await runtime.installSteam { print($0) }
            case "launch":
                let session = try await runtime.launch(debug: arguments.contains("--debug")) {
                    FileHandle.standardError.write(Data("\($0)\n".utf8))
                }
                try printJSON(session)
            case "stop": try await runtime.stop(); print("Traverse Steam stopped.")
            case "frame-limit":
                guard arguments.count == 2 else {
                    throw TraverseError.message("Use: traverse frame-limit status|off|60|120|<fps>")
                }
                switch arguments[1] {
                case "status": try printJSON(try await runtime.status().frameRateLimit)
                case "off": try await runtime.setFrameRateLimit(nil); try printJSON(Int?.none)
                default:
                    guard let limit = Int(arguments[1]) else {
                        throw TraverseError.message("Use: traverse frame-limit status|off|60|120|<fps>")
                    }
                    try await runtime.setFrameRateLimit(limit)
                    try printJSON(limit)
                }
            case "rendering":
                guard arguments.count == 2, let rendering = SteamRendering(rawValue: arguments[1]) else {
                    throw TraverseError.message("Use: traverse rendering automatic|software")
                }
                try await runtime.setRendering(rendering)
            case "engine":
                guard arguments.count == 2 else {
                    throw TraverseError.message("Use: traverse engine managed|msync|/absolute/path/to/wine")
                }
                let wine: URL?
                switch arguments[1] {
                case "managed": wine = nil
                case "msync":
                    guard MSyncEngine.installed(in: paths) else {
                        throw TraverseError.message("Install the MSync engine first: traverse install-engine msync")
                    }
                    wine = MSyncEngine.engine(in: paths).wine
                default: wine = URL(fileURLWithPath: arguments[1])
                }
                try await runtime.setEngine(wine)
            case "synchronization":
                guard arguments.count == 2, ["server", "msync"].contains(arguments[1]) else {
                    throw TraverseError.message("Use: traverse synchronization server|msync")
                }
                try await runtime.setMSync(arguments[1] == "msync")
            case "help", "--help", "-h":
                print("""
                Traverse — Windows applications on macOS

                traverse apps                   List applications in the launchpad
                traverse prepare-text           Prepare Chinese fonts in existing Windows environments
                traverse text-font list|default|<font-id>  Choose a macOS font for Chinese text
                traverse add <path> [name]       Add a Windows application, installer, or shortcut
                traverse remove <id>             Remove an application from the launchpad
                traverse open <id> [--debug] [--wait] Launch an application and record the session
                traverse keyboard <id> status|direct|text Configure input method handling
                traverse dotnet-startup <id> status|on|off Configure .NET startup compatibility
                traverse doctor                 Check the host and selected engine
                traverse benchmark run <label>   Measure fixed Windows workloads in an isolated environment
                                             [--qos default|user-initiated]
                traverse benchmark compare <baseline.json> <candidate.json>
                traverse graphics-benchmark run auto|d3dmetal|dxmt|dxvk|wine <label>
                traverse graphics-benchmark compare <baseline.json> <candidate.json>
                traverse graphics <id> status|auto|d3dmetal|dxmt|dxvk|wine|gdi [/path/to/game.exe]
                traverse graphics default status|auto|d3dmetal|dxmt|dxvk|wine|gdi
                traverse frame-limit status|off|60|120|<fps>  Cap D3DMetal, DXMT, and DXVK games; restart applications and Steam to apply
                traverse install-engine         Install the default MSync engine with updated DXMT
                traverse install-engine msync   Install and select the MSync engine
                traverse install                Create a Windows environment and install Steam
                traverse launch [--debug]        Start Windows Steam and record the session
                traverse stop                   Stop only Traverse's Windows environment
                traverse status                 Print installation state
                traverse game-support bad-end-theater
                traverse game-status             Print game compatibility state
                traverse rendering automatic|software
                traverse engine managed|msync|/absolute/path/to/wine
                traverse synchronization server|msync

                Use --root /absolute/path for a separate test environment.
                """)
            default: throw TraverseError.message("Unknown command: \(command). Run traverse --help.")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
