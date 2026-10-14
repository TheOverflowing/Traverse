import CoreText
import Foundation

public struct WindowsTextFont: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let family: String
    public let fullName: String
    public let file: URL

    static let `default` = WindowsTextFont(id: "STHeitiSC-Light", family: "Heiti SC",
        fullName: "Heiti SC Light", file: URL(fileURLWithPath: "/System/Library/Fonts/STHeiti Light.ttc"))

    public static func available() -> [Self] {
        let families = CTFontManagerCopyAvailableFontFamilyNames() as! [String]
        return families.compactMap { family in
            let font = CTFontCreateWithName(family as CFString, 16, nil)
            guard let file = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
                  ["ttf", "ttc", "otf", "otc"].contains(file.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: file.path) else { return nil }
            let characters: [UniChar] = [0x4e2d, 0x6587, 0x7e41, 0x9ad4]
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return nil }
            return Self(id: CTFontCopyPostScriptName(font) as String, family: CTFontCopyFamilyName(font) as String,
                fullName: CTFontCopyFullName(font) as String, file: file)
        }.sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    static func resolve(_ identifier: String?) throws -> Self {
        guard let identifier else { return .default }
        guard let font = available().first(where: { $0.id == identifier }) else {
            throw TraverseError.message("The selected Chinese font is unavailable. Choose another font in Settings.")
        }
        return font
    }
}
