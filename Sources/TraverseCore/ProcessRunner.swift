import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let seconds: Double
    public let log: URL
}

public enum ProcessRunner {
    // File-backed output lets Wine's children inherit stdout without holding a pipe open.
    public static func run(
        executable: URL, arguments: [String], environment: [String: String]? = nil,
        directory: URL? = nil, log: URL, qualityOfService: QualityOfService = .default
    ) async throws -> ProcessResult {
        let process = Process()
        process.qualityOfService = qualityOfService
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let start = ContinuousClock.now
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try output.close()
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return ProcessResult(status: status, seconds: seconds, log: log)
    }
}
