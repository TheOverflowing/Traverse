import AppKit
import SwiftUI
import TraverseCore
import UniformTypeIdentifiers

@MainActor
struct ApplicationIconPicker: View {
    @ObservedObject var model: AppModel
    let application: LauncherApplication
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Selection.current
    @State private var error: String?

    private enum Selection: Equatable {
        case current
        case original
        case preset(ApplicationIconPreset)
        case image(URL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Change Icon").font(.title2.weight(.semibold))
                    Text(application.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 22) {
                Group {
                    if let preview { Image(nsImage: preview).resizable().scaledToFit() }
                    else { Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
                }.frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 10) {
                    Button("Choose Image…") { chooseImage() }
                    Button("Use Original Icon") { selection = .original; error = nil }
                }
            }.frame(maxWidth: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: 12) {
                Text("Default Icons").font(.headline)
                HStack(spacing: 12) {
                    ForEach(ApplicationIconPreset.allCases) { preset in
                        Button { selection = .preset(preset); error = nil } label: {
                            VStack(spacing: 8) {
                                Image(nsImage: preset.image()).resizable().scaledToFit().frame(width: 58, height: 58)
                                Text(preset.title).font(.caption)
                            }.frame(width: 70).padding(.vertical, 10)
                                .background(selection == .preset(preset) ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(selection == .preset(preset) ? Color.accentColor : Color.clear, lineWidth: 2))
                        }.buttonStyle(.plain).accessibilityLabel(preset.title + " icon")
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Updates the library, Spotlight, and newly opened apps.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { apply() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(selection == .current || model.busy)
            }
        }.padding(24).frame(width: 475)
    }

    private var preview: NSImage? {
        switch selection {
        case .current: model.icons.image(for: application)
        case .original:
            model.icons.image(for: LauncherApplication(id: application.id, name: application.name,
                kind: application.kind, executablePath: application.executablePath, arguments: application.arguments,
                workingDirectory: application.workingDirectory, prefixPath: application.prefixPath,
                steamAppID: application.steamAppID, iconPath: application.iconPath,
                activationDirectory: application.activationDirectory, isImported: application.isImported))
        case .preset(let preset): preset.image(size: 512)
        case .image(let url): NSImage(contentsOf: url)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Application Icon"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            guard NSImage(contentsOf: url) != nil else {
                error = "Choose an image that macOS can open."
                return
            }
            selection = .image(url)
            error = nil
        }
    }

    private func apply() {
        do {
            switch selection {
            case .current: return
            case .original: try model.resetIcon(for: application)
            case .preset(let preset): try model.setIconPreset(preset, for: application)
            case .image(let url): try model.importIcon(at: url, for: application)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
