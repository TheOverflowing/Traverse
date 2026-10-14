import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class FusionFileAssociations {
    private let paths: TraversePaths
    private let hostBundleURL: URL
    private let contentTypes: [UTType]
    private let defaultApplication: (UTType) -> URL?
    private let setDefaultApplication: (URL, UTType) async throws -> Void
    private var legacySnapshotURL: URL { paths.root.appendingPathComponent("fusion-associations.json") }

    public convenience init(paths: TraversePaths, hostBundleURL: URL) {
        let types = [
            UTType.exe,
            UTType(filenameExtension: "msi") ?? UTType(importedAs: "com.microsoft.msi-installer"),
            UTType(filenameExtension: "lnk") ?? UTType(importedAs: "com.microsoft.windows-shortcut"),
        ]
        self.init(paths: paths, hostBundleURL: hostBundleURL, contentTypes: types,
                  defaultApplication: { contentType in
            // NSWorkspace's content-type lookup can keep the pre-change result in this process.
            guard let identifier = LSCopyDefaultRoleHandlerForContentType(
                contentType.identifier as CFString, .all)?.takeRetainedValue() else { return nil }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier as String)
        },
                  setDefaultApplication: { applicationURL, contentType in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: contentType) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        })
    }

    init(paths: TraversePaths, hostBundleURL: URL, contentTypes: [UTType],
         defaultApplication: @escaping (UTType) -> URL?,
         setDefaultApplication: @escaping (URL, UTType) async throws -> Void) {
        self.paths = paths
        self.hostBundleURL = hostBundleURL
        self.contentTypes = contentTypes
        self.defaultApplication = defaultApplication
        self.setDefaultApplication = setDefaultApplication
    }

    public func enable() async throws {
        for contentType in contentTypes {
            if isTraverse(defaultApplication(contentType)) { continue }
            try await setDefaultApplication(hostBundleURL, contentType)
            try await verifyDefault(for: contentType)
        }
        if FileManager.default.fileExists(atPath: legacySnapshotURL.path) {
            try FileManager.default.removeItem(at: legacySnapshotURL)
        }
    }

    private func verifyDefault(for contentType: UTType) async throws {
        // Launch Services can publish the accepted change shortly after completion.
        for attempt in 0..<20 {
            if isTraverse(defaultApplication(contentType)) { return }
            if attempt < 19 { try await Task.sleep(for: .milliseconds(100)) }
        }
        let filenameExtension = contentType.preferredFilenameExtension ?? contentType.identifier
        throw TraverseError.message("macOS did not set Traverse as the default app for .\(filenameExtension). Try again in Settings.")
    }

    private func isTraverse(_ applicationURL: URL?) -> Bool {
        guard let applicationURL else { return false }
        if applicationURL.resolvingSymlinksInPath().standardizedFileURL
            == hostBundleURL.resolvingSymlinksInPath().standardizedFileURL { return true }
        guard let identifier = Bundle(url: hostBundleURL)?.bundleIdentifier else { return false }
        return Bundle(url: applicationURL)?.bundleIdentifier == identifier
    }
}
