import Foundation

public enum ApplicationOpenRequest: Equatable, Sendable {
    case library
    case settings
    case application(String)
    case file(URL)

    public init(url: URL) throws {
        if url.isFileURL {
            guard ["exe", "msi", "lnk", "jar"].contains(url.pathExtension.lowercased()) else {
                throw TraverseError.message("Choose a Windows executable, installer, shortcut, or Java application.")
            }
            self = .file(url.standardizedFileURL.resolvingSymlinksInPath())
            return
        }
        guard url.scheme?.lowercased() == "traverse",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TraverseError.message("This link cannot be opened by Traverse.")
        }
        switch components.host {
        case "library": self = .library
        case "settings": self = .settings
        case "launch":
            guard let id = components.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else {
                throw TraverseError.message("This application link is missing its application ID.")
            }
            self = .application(id)
        default:
            throw TraverseError.message("This Traverse link is not recognized.")
        }
    }

    public static func launchURL(applicationID: String) -> URL {
        var components = URLComponents()
        components.scheme = "traverse"
        components.host = "launch"
        components.queryItems = [URLQueryItem(name: "id", value: applicationID)]
        return components.url!
    }
}
