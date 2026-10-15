import AppKit
import SwiftUI
import TraverseCore
import UniformTypeIdentifiers

extension AppModel {
    func setBackground(enabled: Bool? = nil, frosted: Bool? = nil, useDesktop: Bool = false) {
        do {
            var settings = try TraverseSettings.load(from: runtime.paths)
            settings.customBackground = enabled ?? customBackground
            settings.backgroundFrosted = frosted ?? backgroundFrosted
            settings.backgroundBlur = backgroundBlur
            if useDesktop { settings.backgroundImagePath = nil }
            try settings.save(to: runtime.paths)
            customBackground = settings.customBackground
            backgroundFrosted = settings.backgroundFrosted
            if useDesktop { backgroundImage = nil }
        } catch { self.error = error.localizedDescription }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Background Image"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            guard let image = NSImage(contentsOf: source),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else {
                throw TraverseError.message("This image could not be opened. Choose another image.")
            }
            var settings = try TraverseSettings.load(from: runtime.paths)
            try runtime.paths.prepare()
            let destination = runtime.paths.root.appendingPathComponent("Background.png")
            try data.write(to: destination, options: .atomic)
            settings.backgroundImagePath = destination.path
            settings.customBackground = true
            try settings.save(to: runtime.paths)
            backgroundImage = image
            customBackground = true
        } catch { self.error = error.localizedDescription }
    }
}

struct LauncherBackgroundMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Toggle("Custom Background", isOn: Binding(get: { model.customBackground },
            set: { model.setBackground(enabled: $0) }))
        Toggle("Frosted Glass", isOn: Binding(get: { model.backgroundFrosted },
            set: { model.setBackground(frosted: $0) })).disabled(!model.customBackground)
        Button("Choose Background Image…") { model.chooseBackgroundImage() }
        Button("Use Desktop Wallpaper") { model.setBackground(enabled: true, useDesktop: true) }
            .disabled(model.backgroundImage == nil)
        Divider()
        Button("Background Settings…") { model.showingSettings = true }
    }
}

struct LauncherBackgroundControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        LauncherBackdrop(image: model.customBackground ? model.backgroundImage : nil,
                         frosted: !model.customBackground || model.backgroundFrosted,
                         blur: model.customBackground ? model.backgroundBlur : 38)
            .frame(height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                Text(model.customBackground && model.backgroundImage != nil ? "Custom Image" : "Desktop Wallpaper")
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(10)
            }
            .accessibilityLabel("Background preview")
        Toggle("Custom Background", isOn: Binding(get: { model.customBackground },
            set: { model.setBackground(enabled: $0) }))
        Toggle("Frosted Glass", isOn: Binding(get: { model.backgroundFrosted },
            set: { model.setBackground(frosted: $0) })).disabled(!model.customBackground)
        LabeledContent("Blur Amount") {
            Slider(value: $model.backgroundBlur, in: 0...80, step: 1) { editing in
                if !editing { model.setBackground() }
            }
            .accessibilityLabel("Blur Amount")
            Text(model.backgroundBlur, format: .number.precision(.fractionLength(0)))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
        }.disabled(!model.customBackground || !model.backgroundFrosted)
        HStack {
            Button("Choose Image…") { model.chooseBackgroundImage() }
            Button("Use Desktop Wallpaper") { model.setBackground(enabled: true, useDesktop: true) }
                .disabled(model.backgroundImage == nil)
        }
    }
}
