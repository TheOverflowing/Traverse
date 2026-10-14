import AppKit
import CryptoKit
import Foundation

public enum ApplicationIconPreset: String, CaseIterable, Identifiable, Sendable {
    case fold
    case blue
    case violet
    case graphite
    case sunrise

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    @MainActor public func image(size: CGFloat = 256) -> NSImage {
        let pixels = max(1, Int(size.rounded(.up)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return NSImage() }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 256, y: CGFloat(pixels) / 256)
        context.cgContext.setShouldAntialias(true)
        let palette: [UInt32]
        switch self {
        case .fold: palette = [0xEAF0F8, 0xFCFDFF, 0x023ED9, 0x2384FF, 0x8BB6FF, 0x305AC7]
        case .blue: palette = [0x133976, 0x388DEC, 0xB9D6FF, 0xF3FAFF, 0x82AFF2, 0xD0E5FF]
        case .violet: palette = [0x493084, 0xAA85E2, 0xC6B4F8, 0xFAF6FF, 0x9982D7, 0xE7DAFF]
        case .graphite: palette = [0x242B38, 0x626D80, 0xBAC5D8, 0xF7F9FC, 0x8795AD, 0xD9E0EB]
        case .sunrise: palette = [0xF68E72, 0xF4D59A, 0xFFE3C6, 0xFFFBEE, 0xEBAC92, 0xFFE8CF]
        }
        func color(_ hex: UInt32) -> NSColor {
            NSColor(deviceRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        let bounds = NSRect(x: 6, y: 6, width: 244, height: 244)
        let tile = NSBezierPath(roundedRect: bounds, xRadius: 54, yRadius: 54)
        NSGradient(starting: color(palette[0]), ending: color(palette[1]))?.draw(in: tile, angle: 90)

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: 256 - y) }
        let lower = NSBezierPath()
        lower.move(to: point(104, 122))
        lower.line(to: point(181, 191))
        lower.curve(to: point(174, 213), controlPoint1: point(197, 205), controlPoint2: point(187, 213))
        lower.line(to: point(122, 213))
        lower.curve(to: point(104, 206), controlPoint1: point(114, 213), controlPoint2: point(110, 212))
        lower.line(to: point(68, 170))
        lower.curve(to: point(64, 133), controlPoint1: point(54, 156), controlPoint2: point(55, 145))
        lower.curve(to: point(104, 122), controlPoint1: point(74, 121), controlPoint2: point(87, 122))
        lower.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(self == .fold ? 0.13 : 0.2)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        color(palette[4]).setFill()
        lower.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: color(palette[4]), ending: color(palette[5]))?.draw(in: lower, angle: 90)

        let upper = NSBezierPath()
        upper.move(to: point(64, 137))
        upper.curve(to: point(104, 122), controlPoint1: point(76, 124), controlPoint2: point(88, 122))
        upper.line(to: point(151, 122))
        upper.curve(to: point(178, 110), controlPoint1: point(165, 122), controlPoint2: point(169, 118))
        upper.line(to: point(210, 70))
        upper.curve(to: point(197, 51), controlPoint1: point(219, 59), controlPoint2: point(211, 51))
        upper.line(to: point(140, 51))
        upper.curve(to: point(119, 61), controlPoint1: point(130, 51), controlPoint2: point(126, 53))
        upper.line(to: point(64, 127))
        upper.curve(to: point(64, 137), controlPoint1: point(61, 131), controlPoint2: point(61, 134))
        upper.close()
        NSGradient(starting: color(palette[2]), ending: color(palette[3]))?.draw(in: upper, angle: 75)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        tile.lineWidth = 0.5
        tile.stroke()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(bitmap)
        return image
    }
}

@MainActor
public final class ApplicationIconCustomization {
    private let paths: TraversePaths
    private let manager = FileManager.default

    public init(paths: TraversePaths = TraversePaths()) { self.paths = paths }

    @discardableResult
    public func setPreset(_ preset: ApplicationIconPreset, for application: LauncherApplication) throws -> LauncherApplication {
        try save(preset.image(size: 1024), for: application)
    }

    @discardableResult
    public func importImage(at url: URL, for application: LauncherApplication) throws -> LauncherApplication {
        guard let image = NSImage(contentsOf: url), image.isValid,
              let normalized = ApplicationIconResolver().normalizedIcon(image, pixelSize: 1024) else {
            throw TraverseError.message("Choose a valid image for this application's icon.")
        }
        return try save(normalized, for: application)
    }

    @discardableResult
    public func reset(for application: LauncherApplication) throws -> LauncherApplication {
        let library = ApplicationLibrary(paths: paths)
        let current = try library.applicationForIconCustomization(id: application.id)
        let updated = try library.setCustomIconPath(nil, for: application.id)
        try removePreviousIcon(current.customIconPath, for: application.id)
        return updated
    }

    private func save(_ image: NSImage, for application: LauncherApplication) throws -> LauncherApplication {
        let library = ApplicationLibrary(paths: paths)
        let current = try library.applicationForIconCustomization(id: application.id)
        let data = try icnsData(image)
        let directory = iconDirectory(for: application.id)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(token(data)).icns")
        let existed = manager.fileExists(atPath: url.path)
        if !existed { try data.write(to: url, options: .atomic) }
        let updated: LauncherApplication
        do {
            updated = try library.setCustomIconPath(url.path, for: application.id)
        } catch {
            if !existed { try? manager.removeItem(at: url) }
            throw error
        }
        if current.customIconPath != url.path {
            try removePreviousIcon(current.customIconPath, for: application.id)
        }
        return updated
    }

    private func iconDirectory(for id: String) -> URL {
        paths.root.appendingPathComponent("Application Icons/\(token(Data(id.utf8)))", isDirectory: true)
    }

    private func removePreviousIcon(_ path: String?, for id: String) throws {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "icns",
              url.deletingLastPathComponent().resolvingSymlinksInPath()
                == iconDirectory(for: id).resolvingSymlinksInPath(),
              manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
    }

    private func icnsData(_ image: NSImage) throws -> Data {
        var body = Data()
        for (pixels, type) in [(256, "ic08"), (512, "ic09"), (1024, "ic10")] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw TraverseError.message("The icon could not be created.")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
                       operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw TraverseError.message("The icon could not be created.")
            }
            body.append(Data(type.utf8))
            var length = UInt32(png.count + 8).bigEndian
            withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
            body.append(png)
        }
        var result = Data("icns".utf8)
        var length = UInt32(body.count + 8).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(body)
        return result
    }

    private func token(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
