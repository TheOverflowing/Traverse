import CryptoKit
import Darwin
import Foundation

public struct BenchmarkWorkload: Codable, Sendable, Equatable {
    public let name: String
    public let unit: String
    public let operations: Int
    public let samplesMilliseconds: [Double]

    public var medianMilliseconds: Double {
        let sorted = samplesMilliseconds.sorted()
        return sorted[sorted.count / 2]
    }
}

public struct WindowsBenchmarkResult: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let workloadVersion: String
    public let pointerBits: Int
    public let workloads: [BenchmarkWorkload]

    func validate() throws {
        let expected: [(String, String, Int)] = [
            ("integer-mix", "iteration", 10_000_000),
            ("event-round-trip", "round-trip", 5_000),
            ("file-write-flush", "byte", 8_388_608),
        ]
        guard schemaVersion == 1, workloadVersion == "win32-v1", pointerBits == 64,
              workloads.count == expected.count else {
            throw TraverseError.message("The Windows benchmark returned an unsupported workload version.")
        }
        for (workload, specification) in zip(workloads, expected) {
            guard workload.name == specification.0, workload.unit == specification.1,
                  workload.operations == specification.2, workload.samplesMilliseconds.count == 5,
                  workload.samplesMilliseconds.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw TraverseError.message("The Windows benchmark returned invalid or incomplete measurements.")
            }
        }
    }
}

public struct BenchmarkHost: Codable, Sendable, Equatable {
    public let hardwareModel: String
    public let operatingSystem: String
    public let architecture: String
    public let processorCount: Int
    public let memoryBytes: UInt64

    static func current() -> Self {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let info = ProcessInfo.processInfo
        let hardwareModel = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return Self(hardwareModel: hardwareModel,
            operatingSystem: info.operatingSystemVersionString, architecture: architecture,
            processorCount: info.processorCount, memoryBytes: info.physicalMemory)
    }
}

public struct BenchmarkReport: Codable, Sendable {
    public let id: String
    public let label: String
    public let startedAt: Date
    public let host: BenchmarkHost
    public let engineVersion: String
    public let enginePath: String
    public let environment: [String: String]
    public let probeSHA256: String
    public let storageDeviceID: Int32
    public let launchQualityOfService: Int?
    public let result: WindowsBenchmarkResult
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

public struct BenchmarkComparison: Codable, Sendable {
    public struct Measurement: Codable, Sendable {
        public let workload: String
        public let unit: String
        public let operations: Int
        public let baselineMedianMilliseconds: Double
        public let candidateMedianMilliseconds: Double
        public let baselineRangeMilliseconds: [Double]
        public let candidateRangeMilliseconds: [Double]
        public let medianTimeChangePercent: Double
        public let speedup: Double
    }

    public let baselineID: String
    public let baselineLabel: String
    public let candidateID: String
    public let candidateLabel: String
    public let measurements: [Measurement]

    public init(baseline: BenchmarkReport, candidate: BenchmarkReport) throws {
        try baseline.result.validate()
        try candidate.result.validate()
        guard baseline.host == candidate.host, baseline.probeSHA256 == candidate.probeSHA256,
              baseline.storageDeviceID == candidate.storageDeviceID,
              baseline.result.workloadVersion == candidate.result.workloadVersion else {
            throw TraverseError.message("Compare runs with the same host configuration, storage volume, and benchmark executable.")
        }
        baselineID = baseline.id
        baselineLabel = baseline.label
        candidateID = candidate.id
        candidateLabel = candidate.label
        measurements = zip(baseline.result.workloads, candidate.result.workloads).map { original, changed in
            Measurement(workload: original.name, unit: original.unit, operations: original.operations,
                baselineMedianMilliseconds: original.medianMilliseconds,
                candidateMedianMilliseconds: changed.medianMilliseconds,
                baselineRangeMilliseconds: [original.samplesMilliseconds.min()!, original.samplesMilliseconds.max()!],
                candidateRangeMilliseconds: [changed.samplesMilliseconds.min()!, changed.samplesMilliseconds.max()!],
                medianTimeChangePercent: (changed.medianMilliseconds / original.medianMilliseconds - 1) * 100,
                speedup: original.medianMilliseconds / changed.medianMilliseconds)
        }
    }
}

public struct BenchmarkRuntime: Sendable {
    public let paths: TraversePaths

    public init(paths: TraversePaths = TraversePaths()) { self.paths = paths }

    public func run(label: String, qualityOfService: QualityOfService = .default,
                    progress: @Sendable (String) async -> Void = { _ in }) async throws -> BenchmarkReport {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TraverseError.message("Give the benchmark run a label.")
        }
        let settings = try TraverseSettings.load(from: paths)
        let wine = settings.customWine.map { URL(fileURLWithPath: $0) } ?? MSyncEngine.engine(in: paths).wine
        let engine = WineEngine(wine: wine, msync: settings.msync)
        guard engine.installed else {
            throw TraverseError.message("Install or select a Wine engine before running the benchmark.")
        }
        try await MSyncEngine.prepareGraphics(for: engine, progress: progress)
        let engineData = try Data(contentsOf: engine.wine, options: .mappedIfSafe)
        if engineData.starts(with: [0x23, 0x21]) {
            let wrapper = String(decoding: engineData, as: UTF8.self)
            if wrapper.contains("CX_BOTTLE") && wrapper.contains("setup_wine_environment") {
                throw TraverseError.message("CrossOver's wine wrapper selects a CrossOver bottle. Select its native wineloader for an isolated engine experiment.")
            }
        }
        guard let probe = Bundle.module.url(forResource: "traverse-benchmark", withExtension: "exe",
                                            subdirectory: "Resources") else {
            throw TraverseError.message("Build the benchmark with scripts/build-benchmark.sh, then rebuild Traverse.")
        }
        try paths.prepare()
        let id = UUID().uuidString.lowercased()
        let prefix = paths.root.appendingPathComponent("Bottles/Benchmark-\(id)", isDirectory: true)
        let reports = paths.root.appendingPathComponent("Benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let environment = engine.environment(prefix: prefix)
        let versionLog = paths.logs.appendingPathComponent("benchmark-\(id)-version.log")
        let version = try await ProcessRunner.run(executable: engine.wine, arguments: ["--version"],
            environment: environment, log: versionLog, qualityOfService: qualityOfService)
        guard version.status == 0 else {
            throw TraverseError.message("The Wine engine could not start. Open \(versionLog.path) for details.")
        }
        let engineVersion = try String(contentsOf: versionLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let probeHash = SHA256.hash(data: try Data(contentsOf: probe)).map { String(format: "%02x", $0) }.joined()
        let log = paths.logs.appendingPathComponent("benchmark-\(id).log")
        let preparationLog = paths.logs.appendingPathComponent("benchmark-\(id)-prepare.log")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let report: BenchmarkReport
        do {
            var storage = stat()
            guard stat(prefix.path, &storage) == 0 else {
                throw TraverseError.message("The benchmark storage volume could not be identified.")
            }
            await progress("Preparing an isolated benchmark environment…")
            let preparation = try await ProcessRunner.run(executable: engine.wine, arguments: ["wineboot", "--init"],
                environment: environment, log: preparationLog, qualityOfService: qualityOfService)
            guard preparation.status == 0 else {
                throw TraverseError.message("The benchmark environment could not be prepared. Open \(preparationLog.path) for details.")
            }
            let output = prefix.appendingPathComponent("benchmark-result.json")
            let windowsOutput = "Z:" + output.path.replacingOccurrences(of: "/", with: "\\")
            let startedAt = Date()
            await progress("Measuring Windows CPU, event synchronization, and file writes…")
            let execution = try await ProcessRunner.run(executable: engine.wine,
                arguments: [probe.path, windowsOutput], environment: environment, log: log,
                qualityOfService: qualityOfService)
            guard execution.status == 0 else {
                throw TraverseError.message("The Windows benchmark failed (exit \(execution.status)). Open \(log.path) for details.")
            }
            let result = try JSONDecoder().decode(WindowsBenchmarkResult.self, from: Data(contentsOf: output))
            try result.validate()
            let recordedKeys = ["WINEARCH", "WINEDEBUG", "WINEESYNC", "WINEFSYNC", "WINEMSYNC", "WINE_MSYNC"]
            report = BenchmarkReport(id: id, label: label, startedAt: startedAt, host: .current(),
                engineVersion: engineVersion, enginePath: engine.wine.path,
                environment: environment.filter { recordedKeys.contains($0.key) }, probeSHA256: probeHash,
                storageDeviceID: storage.st_dev, launchQualityOfService: qualityOfService.rawValue, result: result,
                reportPath: reports.appendingPathComponent("\(id).json").path, logPath: log.path)
        } catch {
            // Only this run's newly created prefix is eligible for cleanup.
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
        let environment = engine.environment(prefix: prefix)
        for argument in ["-k", "-w"] {
            let result = try await ProcessRunner.run(executable: engine.server, arguments: [argument],
                environment: environment, log: paths.logs.appendingPathComponent("benchmark-\(id)-stop\(argument).log"))
            guard result.status == 0 else {
                throw TraverseError.message("The benchmark environment could not be stopped. It was kept at \(prefix.path).")
            }
        }
        try FileManager.default.removeItem(at: prefix)
    }
}
