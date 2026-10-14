import CryptoKit
import Foundation

public struct GraphicsBenchmarkWorkload: Codable, Sendable, Equatable {
    public let name: String
    public let task: String
    public let drawCallsPerRender: Int
    public let verticesPerRender: Int
    public let cpuSubmissionMilliseconds: [Double]
    public let gpuMilliseconds: [Double?]
    public let gpuTimingUnavailableReasons: [String?]
    public let completionMilliseconds: [Double]
}

public struct WindowsGraphicsBenchmarkResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let workloadVersion: String
    public let pointerBits: Int
    public let width: Int
    public let height: Int
    public let rendersPerBatch: Int
    public let adapterDescription: String
    public let vendorID: UInt32
    public let deviceID: UInt32
    public let featureLevel: UInt32
    public let d3d11Module: String
    public let dxgiModule: String
    public let workloads: [GraphicsBenchmarkWorkload]

    func validate() throws {
        let expected = [("draw-calls", "tiled-image", 2_560, 15_360),
                        ("instanced-draw", "tiled-image", 1, 15_360),
                        ("shader-fill", "integer-shader-image", 1, 3)]
        guard schemaVersion == 1, workloadVersion == "d3d11-v1", pointerBits == 64,
              width == 1_280, height == 720, rendersPerBatch == 8,
              featureLevel >= 0xb000, !adapterDescription.isEmpty,
              !d3d11Module.isEmpty, !dxgiModule.isEmpty, workloads.count == expected.count else {
            throw TraverseError.message("The graphics benchmark returned an unsupported workload or device.")
        }
        for (workload, spec) in zip(workloads, expected) {
            guard workload.name == spec.0, workload.task == spec.1,
                  workload.drawCallsPerRender == spec.2, workload.verticesPerRender == spec.3,
                  workload.cpuSubmissionMilliseconds.count == 5,
                  workload.completionMilliseconds.count == 5,
                  workload.gpuMilliseconds.count == 5, workload.gpuTimingUnavailableReasons.count == 5,
                  workload.cpuSubmissionMilliseconds.allSatisfy({ $0.isFinite && $0 > 0 }),
                  workload.completionMilliseconds.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw TraverseError.message("The graphics benchmark returned incomplete measurements.")
            }
            for index in 0..<5 {
                if let gpu = workload.gpuMilliseconds[index] {
                    guard gpu.isFinite, gpu > 0, workload.gpuTimingUnavailableReasons[index] == nil else {
                        throw TraverseError.message("The graphics benchmark returned an invalid GPU timestamp.")
                    }
                } else if workload.gpuTimingUnavailableReasons[index]?.isEmpty != false {
                    throw TraverseError.message("The graphics benchmark did not explain an unavailable GPU timestamp.")
                }
            }
        }
    }
}

public struct GraphicsBenchmarkReport: Codable, Sendable {
    public let id: String
    public let label: String
    public let startedAt: Date
    public let host: BenchmarkHost
    public let engineVersion: String
    public let enginePath: String
    public let backend: GraphicsBackend
    public let backendFileSHA256: [String: String]
    public let environment: [String: String]
    public let probeSHA256: String
    public let result: WindowsGraphicsBenchmarkResult
    public let reportPath: String
    public let logPath: String

    public static func load(from url: URL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(Self.self, from: Data(contentsOf: url))
        try report.result.validate()
        return report
    }
}

public struct GraphicsBenchmarkComparison: Codable, Sendable {
    public struct Measurement: Codable, Sendable {
        public let workload: String
        public let metric: String
        public let baselineMedianMilliseconds: Double
        public let candidateMedianMilliseconds: Double
        public let baselineRangeMilliseconds: [Double]
        public let candidateRangeMilliseconds: [Double]
        public let medianTimeChangePercent: Double
        public let speedup: Double
    }

    public let baselineID: String
    public let candidateID: String
    public let baselineBackend: GraphicsBackend
    public let candidateBackend: GraphicsBackend
    public let measurements: [Measurement]

    public init(baseline: GraphicsBenchmarkReport, candidate: GraphicsBenchmarkReport) throws {
        try baseline.result.validate()
        try candidate.result.validate()
        guard baseline.host == candidate.host, baseline.probeSHA256 == candidate.probeSHA256,
              ["WINEMSYNC", "WINEARCH", "WINEDEBUG"].allSatisfy({ baseline.environment[$0] == candidate.environment[$0] }) else {
            throw TraverseError.message("Compare graphics runs on the same host and probe with the same synchronization settings.")
        }
        baselineID = baseline.id
        candidateID = candidate.id
        baselineBackend = baseline.backend
        candidateBackend = candidate.backend
        var measurements: [Measurement] = []
        for (original, changed) in zip(baseline.result.workloads, candidate.result.workloads) {
            let metrics = [("cpu-submission", original.cpuSubmissionMilliseconds, changed.cpuSubmissionMilliseconds),
                           ("completion", original.completionMilliseconds, changed.completionMilliseconds)]
                + ((original.gpuMilliseconds.allSatisfy { $0 != nil } && changed.gpuMilliseconds.allSatisfy { $0 != nil })
                   ? [("gpu", original.gpuMilliseconds.compactMap { $0 }, changed.gpuMilliseconds.compactMap { $0 })] : [])
            for (metric, before, after) in metrics {
                let beforeMedian = before.sorted()[2]
                let afterMedian = after.sorted()[2]
                measurements.append(Measurement(workload: original.name, metric: metric,
                    baselineMedianMilliseconds: beforeMedian, candidateMedianMilliseconds: afterMedian,
                    baselineRangeMilliseconds: [before.min()!, before.max()!],
                    candidateRangeMilliseconds: [after.min()!, after.max()!],
                    medianTimeChangePercent: (afterMedian / beforeMedian - 1) * 100,
                    speedup: beforeMedian / afterMedian))
            }
        }
        self.measurements = measurements
    }
}

public struct GraphicsBenchmarkRuntime: Sendable {
    public let paths: TraversePaths

    public init(paths: TraversePaths = TraversePaths()) { self.paths = paths }

    public func run(label: String, backend selection: GraphicsBackend,
                    progress: @Sendable (String) async -> Void = { _ in }) async throws -> GraphicsBenchmarkReport {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TraverseError.message("Give the graphics benchmark run a label.")
        }
        let settings = try TraverseSettings.load(from: paths)
        let engine = WineEngine(wine: settings.customWine.map { URL(fileURLWithPath: $0) }
            ?? MSyncEngine.engine(in: paths).wine, msync: settings.msync)
        guard engine.installed else { throw TraverseError.message("Install or select a Wine engine first.") }
        try await MSyncEngine.prepareGraphics(for: engine, progress: progress)
        let engineData = try Data(contentsOf: engine.wine, options: .mappedIfSafe)
        if engineData.starts(with: [0x23, 0x21]) {
            let wrapper = String(decoding: engineData, as: UTF8.self)
            if wrapper.contains("CX_BOTTLE") && wrapper.contains("setup_wine_environment") {
                throw TraverseError.message("Select CrossOver's native wineloader for an isolated graphics experiment.")
            }
        }
        guard let resource = Bundle.module.url(forResource: "traverse-graphics-benchmark", withExtension: "exe",
                                               subdirectory: "Resources") else {
            throw TraverseError.message("Build scripts/build-graphics-benchmark.sh, then rebuild Traverse.")
        }
        try paths.prepare()
        let id = UUID().uuidString.lowercased()
        let prefix = paths.root.appendingPathComponent("Bottles/GraphicsBenchmark-\(id)", isDirectory: true)
        let directory = prefix.appendingPathComponent("drive_c/traverse-graphics", isDirectory: true)
        let reports = paths.root.appendingPathComponent("GraphicsBenchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent("traverse-graphics-benchmark.exe")
        try FileManager.default.copyItem(at: resource, to: probe)
        let backend = try GraphicsSupport.resolve(selection, executable: probe, engine: engine, globalBackend: settings.graphicsBackend)
        let log = paths.logs.appendingPathComponent("graphics-benchmark-\(id).log")
        var environment = engine.environment(prefix: prefix)
        // Each run uses explicit defaults, rather than inherited renderer tuning.
        for key in environment.keys where key.hasPrefix("DXVK_") || key.hasPrefix("DXMT_")
            || key.hasPrefix("MTL_") || key == "WINE_D3D_CONFIG" {
            environment.removeValue(forKey: key)
        }
        let report: GraphicsBenchmarkReport
        do {
            let payloads = try await GraphicsSupport.payloads(backend: backend, executable: probe,
                engine: engine, paths: paths, progress: progress)
            for (name, data) in payloads { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
            if backend != .wine {
                environment["WINEDLLOVERRIDES"] = backend.environmentOverrides
            }
            let versionLog = paths.logs.appendingPathComponent("graphics-benchmark-\(id)-version.log")
            let version = try await ProcessRunner.run(executable: engine.wine, arguments: ["--version"],
                environment: environment, log: versionLog)
            guard version.status == 0 else { throw TraverseError.message("The selected Wine engine could not start.") }
            let engineVersion = try String(contentsOf: versionLog, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await progress("Preparing an isolated graphics environment…")
            let prepareLog = paths.logs.appendingPathComponent("graphics-benchmark-\(id)-prepare.log")
            let prepare = try await ProcessRunner.run(executable: engine.wine, arguments: ["wineboot", "--init"],
                environment: engine.environment(prefix: prefix), log: prepareLog)
            guard prepare.status == 0 else {
                throw TraverseError.message("The graphics environment could not be prepared. Open \(prepareLog.path).")
            }
            let output = prefix.appendingPathComponent("graphics-result.json")
            let startedAt = Date()
            await progress("Measuring D3D11 draws, instancing, and shader execution with \(backend.rawValue)…")
            let execution = try await ProcessRunner.run(executable: engine.wine,
                arguments: [probe.path, "Z:" + output.path.replacingOccurrences(of: "/", with: "\\")],
                environment: environment, directory: directory, log: log)
            guard execution.status == 0 else {
                throw TraverseError.message("The graphics benchmark failed (exit \(execution.status)). Open \(log.path).")
            }
            let result = try JSONDecoder().decode(WindowsGraphicsBenchmarkResult.self, from: Data(contentsOf: output))
            try result.validate()
            let keys = ["WINEARCH", "WINEDEBUG", "WINEMSYNC", "WINEDLLOVERRIDES"]
            report = GraphicsBenchmarkReport(id: id, label: label, startedAt: startedAt, host: .current(),
                engineVersion: engineVersion, enginePath: engine.wine.path, backend: backend,
                backendFileSHA256: payloads.mapValues(Self.digest),
                environment: environment.filter { keys.contains($0.key) }, probeSHA256: Self.digest(try Data(contentsOf: resource)),
                result: result, reportPath: reports.appendingPathComponent("\(id).json").path, logPath: log.path)
        } catch {
            do { try await cleanUp(prefix: prefix, engine: engine, id: id) }
            catch let cleanupError {
                throw TraverseError.message("\(error.localizedDescription) \(cleanupError.localizedDescription)")
            }
            throw error
        }
        try await cleanUp(prefix: prefix, engine: engine, id: id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: report.reportPath), options: .atomic)
        return report
    }

    private func cleanUp(prefix: URL, engine: WineEngine, id: String) async throws {
        for argument in ["-k", "-w"] {
            let result = try await ProcessRunner.run(executable: engine.server, arguments: [argument],
                environment: engine.environment(prefix: prefix),
                log: paths.logs.appendingPathComponent("graphics-benchmark-\(id)-stop\(argument).log"))
            guard result.status == 0 else {
                throw TraverseError.message("The graphics environment could not stop. It was kept at \(prefix.path).")
            }
        }
        try FileManager.default.removeItem(at: prefix)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}
