import Foundation

public struct TraversePaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Traverse", isDirectory: true)
    }

    public var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    public var prefix: URL { root.appendingPathComponent("Bottles/Steam", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public var steam: URL {
        prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    }

    public func prepare() throws {
        for directory in [root, downloads, engines, logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

public enum SteamRendering: String, Codable, CaseIterable, Sendable {
    case automatic
    case software

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .software: "Software rendering"
        }
    }

    public var arguments: [String] {
        switch self {
        case .automatic: []
        case .software: ["-cef-disable-gpu"]
        }
    }
}

public struct TraverseSettings: Codable, Sendable {
    public var customWine: String?
    // The Steam bridge keeps CEF's software renderer inside its browser process;
    // software rendering alone still loses frames across Wine process boundaries.
    public var rendering: SteamRendering = .software
    public var msync = true
    public var graphicsBackend = GraphicsBackend.automatic
    // Frames per second; nil leaves the frame rate uncapped. Kept outside graphics
    // profiles so changing a backend does not reset it.
    public var frameRateLimit: Int?
    public var windowsTextFont: String?
    public var retinaMode = false
    public var fusionMode = false
    public var customBackground = false
    public var backgroundFrosted = true
    public var backgroundBlur: Double = 38
    public var backgroundImagePath: String?
    public var directKeyboardApplications: Set<String> = []
    public var dotnetStartupApplications: Set<String> = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case customWine, rendering, msync, graphicsBackend, frameRateLimit, windowsTextFont, retinaMode, fusionMode, directKeyboardApplications, dotnetStartupApplications, customBackground, backgroundFrosted, backgroundBlur, backgroundImagePath }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        customWine = try values.decodeIfPresent(String.self, forKey: .customWine)
        rendering = try values.decodeIfPresent(SteamRendering.self, forKey: .rendering) ?? .software
        msync = try values.decodeIfPresent(Bool.self, forKey: .msync) ?? (customWine == nil)
        graphicsBackend = try values.decodeIfPresent(GraphicsBackend.self, forKey: .graphicsBackend) ?? .automatic
        frameRateLimit = try values.decodeIfPresent(Int.self, forKey: .frameRateLimit)
            .flatMap { FrameRateLimit.range.contains($0) ? $0 : nil }
        windowsTextFont = try values.decodeIfPresent(String.self, forKey: .windowsTextFont)
        retinaMode = try values.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? false
        fusionMode = try values.decodeIfPresent(Bool.self, forKey: .fusionMode) ?? false
        customBackground = try values.decodeIfPresent(Bool.self, forKey: .customBackground) ?? false
        backgroundFrosted = try values.decodeIfPresent(Bool.self, forKey: .backgroundFrosted) ?? true
        backgroundBlur = try values.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 38
        backgroundImagePath = try values.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        directKeyboardApplications = try values.decodeIfPresent(Set<String>.self, forKey: .directKeyboardApplications) ?? []
        dotnetStartupApplications = try values.decodeIfPresent(Set<String>.self, forKey: .dotnetStartupApplications) ?? []
    }

    public static func load(from paths: TraversePaths) throws -> Self {
        guard FileManager.default.fileExists(atPath: paths.settings.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: paths.settings))
    }

    public func save(to paths: TraversePaths) throws {
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: paths.settings, options: .atomic)
    }
}

public enum TraverseError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
