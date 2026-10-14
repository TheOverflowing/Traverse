import AppKit
import Foundation

@MainActor
public final class ApplicationIconResolver {
    public init() {}
    private struct CachedImage {
        let modified: Date?
        let size: Int?
        let image: NSImage?
    }

    private var cache: [String: CachedImage] = [:]

    public func image(for application: LauncherApplication) -> NSImage? {
        for path in candidatePaths(for: application) {
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let cached = cache[path], cached.modified == values?.contentModificationDate,
               cached.size == values?.fileSize {
                if let image = cached.image { return image }
                continue
            }
            let image: NSImage?
            if ["exe", "dll"].contains(url.pathExtension.lowercased()) {
                if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                   let icon = WindowsExecutableIcon(data: data)?.iconData() {
                    image = NSImage(data: icon)
                } else {
                    image = nil
                }
            } else {
                image = NSImage(contentsOf: url)
            }
            let normalized = image.flatMap { normalizedIcon($0) }
            cache[path] = CachedImage(modified: values?.contentModificationDate,
                                      size: values?.fileSize, image: normalized)
            if let normalized { return normalized }
        }
        return nil
    }

    public func clearCache() {
        cache.removeAll()
    }

    func icnsData(for application: LauncherApplication) -> Data? {
        if let path = application.customIconPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           data.starts(with: Data("icns".utf8)), NSImage(data: data)?.isValid == true {
            return data
        }
        guard let image = image(for: application),
              let representation = image.representations.first as? NSBitmapImageRep,
              let png = representation.representation(using: .png, properties: [:]) else { return nil }
        // An ic08 element holds a 256-pixel PNG, matching the launcher's artwork.
        var data = Data("icns".utf8)
        var length = UInt32(16 + png.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(Data("ic08".utf8))
        length = UInt32(8 + png.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(png)
        return data
    }

    func normalizedIcon(_ image: NSImage, pixelSize: Int = 256) -> NSImage? {
        let size = NSSize(width: pixelSize, height: pixelSize)
        let bounds = NSRect(origin: .zero, size: size)
        guard image.size.width > 0, image.size.height > 0,
              let source = bitmap(size: pixelSize), let sourceContext = NSGraphicsContext(bitmapImageRep: source),
              let output = bitmap(size: pixelSize), let outputContext = NSGraphicsContext(bitmapImageRep: output) else { return nil }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let contentSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let content = NSRect(x: (size.width - contentSize.width) / 2,
                             y: (size.height - contentSize.height) / 2,
                             width: contentSize.width, height: contentSize.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = sourceContext
        sourceContext.imageInterpolation = .high
        sourceContext.cgContext.clear(bounds)
        image.draw(in: content, from: .zero, operation: .copy, fraction: 1)

        var top: [NSColor] = []
        var bottom: [NSColor] = []
        for x in stride(from: pixelSize / 32, to: pixelSize, by: pixelSize / 16) {
            for y in stride(from: 0, to: pixelSize, by: pixelSize / 64) {
                if let color = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 {
                    top.append(color)
                    break
                }
            }
            for y in stride(from: pixelSize - 1, through: 0, by: -pixelSize / 64) {
                if let color = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 {
                    bottom.append(color)
                    break
                }
            }
        }
        guard !top.isEmpty, !bottom.isEmpty else { return nil }
        var opaque = 0
        for x in stride(from: pixelSize / 32, to: pixelSize, by: pixelSize / 16) {
            for y in stride(from: pixelSize / 32, to: pixelSize, by: pixelSize / 16) {
                if (source.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 { opaque += 1 }
            }
        }
        // Dense icons keep their edge colors. Sparse marks need a lighter plate
        // so their original outline remains distinguishable from its background.
        let lightening = opaque < 160 ? 0.9 : 0.0
        let topColor = medianColor(top).blended(withFraction: lightening, of: .white) ?? .white
        let bottomColor = medianColor(bottom).blended(withFraction: lightening, of: .white) ?? .white
        NSGraphicsContext.current = outputContext
        outputContext.imageInterpolation = .high
        outputContext.cgContext.clear(bounds)
        NSBezierPath(roundedRect: bounds, xRadius: size.width * 0.21875, yRadius: size.height * 0.21875).addClip()
        NSGradient(starting: bottomColor, ending: topColor)?.draw(in: bounds, angle: 90)
        image.draw(in: content, from: .zero, operation: .sourceOver, fraction: 1)
        let normalized = NSImage(size: size)
        normalized.addRepresentation(output)
        return normalized
    }

    private func bitmap(size: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }

    private func medianColor(_ colors: [NSColor]) -> NSColor {
        let index = colors.count / 2
        return NSColor(deviceRed: colors.map(\.redComponent).sorted()[index],
                       green: colors.map(\.greenComponent).sorted()[index],
                       blue: colors.map(\.blueComponent).sorted()[index], alpha: 1)
    }

    private func candidatePaths(for application: LauncherApplication) -> [String] {
        var paths: [String] = []
        if let path = application.customIconPath { paths.append(path) }
        if let path = application.iconPath { paths.append(path) }
        if let executable = application.executablePath {
            let url = URL(fileURLWithPath: executable)
            let directory = url.deletingLastPathComponent()
            let stem = url.deletingPathExtension()
            paths += [stem.appendingPathExtension("ico").path,
                      stem.appendingPathExtension("png").path,
                      directory.appendingPathComponent("game/gui/window_icon.png").path,
                      executable]
            if application.kind == .steam {
                paths.append(directory.appendingPathComponent("public/steam_tray.ico").path)
            }
        }
        return paths
    }
}

// PE icon groups refer to separate image resources. Reassembling them as an ICO
// lets AppKit choose a suitable resolution without executing the Windows file.
private struct WindowsExecutableIcon {
    let data: Data
    let resourceRoot: Int
    private let sections: [Section]

    private struct Section {
        let virtualAddress: Int
        let rawOffset: Int
        let rawSize: Int
    }

    init?(data: Data) {
        guard data.uint16(at: 0) == 0x5A4D,
              let header = data.uint32(at: 0x3C).map(Int.init),
              data.uint32(at: header) == 0x00004550,
              let sectionCount = data.uint16(at: header + 6).map(Int.init),
              let optionalSize = data.uint16(at: header + 20).map(Int.init) else { return nil }
        let optional = header + 24
        let directoryOffset: Int
        switch data.uint16(at: optional) {
        case 0x10B: directoryOffset = 96
        case 0x20B: directoryOffset = 112
        default: return nil
        }
        guard optionalSize >= directoryOffset + 24,
              let resourceAddress = data.uint32(at: optional + directoryOffset + 16).map(Int.init),
              resourceAddress != 0 else { return nil }
        let sectionTable = optional + optionalSize
        guard data.containsBytes(at: sectionTable, count: sectionCount * 40) else { return nil }
        var sections: [Section] = []
        for index in 0..<sectionCount {
            let start = sectionTable + index * 40
            guard let address = data.uint32(at: start + 12).map(Int.init),
                  let size = data.uint32(at: start + 16).map(Int.init),
                  let offset = data.uint32(at: start + 20).map(Int.init) else { return nil }
            sections.append(Section(virtualAddress: address, rawOffset: offset, rawSize: size))
        }
        guard let resourceSection = sections.first(where: {
            resourceAddress >= $0.virtualAddress && resourceAddress - $0.virtualAddress < $0.rawSize
        }) else { return nil }
        let resourceRoot = resourceSection.rawOffset + resourceAddress - resourceSection.virtualAddress
        guard data.containsBytes(at: resourceRoot, count: 16) else { return nil }
        self.data = data
        self.sections = sections
        self.resourceRoot = resourceRoot
    }

    func iconData() -> Data? {
        guard let group = resource(type: 14), group.uint16(at: 2) == 1,
              let count = group.uint16(at: 4).map(Int.init), count > 0,
              group.containsBytes(at: 6, count: count * 14) else { return nil }
        var images: [Data] = []
        for index in 0..<count {
            guard let id = group.uint16(at: 6 + index * 14 + 12).map(Int.init),
                  let image = resource(type: 3, id: id) else { return nil }
            images.append(image)
        }
        var icon = group.subdata(in: 0..<6)
        var offset = 6 + count * 16
        for index in 0..<count {
            let start = 6 + index * 14
            icon.append(group.subdata(in: start..<(start + 8)))
            icon.appendLittleEndian(UInt32(images[index].count))
            icon.appendLittleEndian(UInt32(offset))
            offset += images[index].count
        }
        for image in images { icon.append(image) }
        return icon
    }

    private func resource(type: Int, id: Int? = nil) -> Data? {
        guard let typeDirectory = entry(in: resourceRoot, id: type), typeDirectory.isDirectory,
              let nameDirectory = entry(in: typeDirectory.offset, id: id), nameDirectory.isDirectory,
              let leaf = entry(in: nameDirectory.offset, id: nil), !leaf.isDirectory,
              let address = data.uint32(at: leaf.offset).map(Int.init),
              let size = data.uint32(at: leaf.offset + 4).map(Int.init),
              let section = sections.first(where: {
                  address >= $0.virtualAddress && address - $0.virtualAddress < $0.rawSize
              }) else { return nil }
        let offset = section.rawOffset + address - section.virtualAddress
        guard data.containsBytes(at: offset, count: size) else { return nil }
        return data.subdata(in: offset..<(offset + size))
    }

    private func entry(in directory: Int, id: Int?) -> (offset: Int, isDirectory: Bool)? {
        guard let named = data.uint16(at: directory + 12).map(Int.init),
              let identified = data.uint16(at: directory + 14).map(Int.init) else { return nil }
        let count = named + identified
        guard data.containsBytes(at: directory + 16, count: count * 8) else { return nil }
        for index in 0..<count {
            let start = directory + 16 + index * 8
            guard let name = data.uint32(at: start), let target = data.uint32(at: start + 4) else { return nil }
            if let id, name != UInt32(id) { continue }
            return (resourceRoot + Int(target & 0x7FFFFFFF), target & 0x80000000 != 0)
        }
        return nil
    }
}

private extension Data {
    func containsBytes(at offset: Int, count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= self.count && count <= self.count - offset
    }

    func uint16(at offset: Int) -> UInt16? {
        guard containsBytes(at: offset, count: 2) else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32? {
        guard containsBytes(at: offset, count: 4) else { return nil }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
