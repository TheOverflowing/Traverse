import AppKit
import SwiftUI
import TraverseCore

@MainActor
struct LauncherFolderPanel: View {
    let folder: LauncherFolder
    let applications: [LauncherApplication]
    let icons: ApplicationIconResolver
    let busy: Bool
    let openingID: String?
    let editingName: Bool
    let arrangementNamespace: Namespace.ID
    let panelWidth: CGFloat
    let maxHeight: CGFloat
    let currentItem: @MainActor () -> String?
    let beginDrag: @MainActor (String) -> Void
    let launch: @MainActor (LauncherApplication) -> Void
    let configureGraphics: @MainActor (LauncherApplication) -> Void
    let configureIcon: @MainActor (LauncherApplication) -> Void
    let rename: @MainActor (String) -> Void
    let moveOut: @MainActor (String) -> Void
    let receive: @MainActor @Sendable (String, Int) -> Void
    let close: @MainActor () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var name = ""
    @FocusState private var naming: Bool
    @FocusState private var focusedApplication: String?

    var body: some View {
        VStack(spacing: 24) {
            TextField("Folder Name", text: $name)
                .textFieldStyle(.plain).font(.system(size: 24, weight: .medium))
                .multilineTextAlignment(.center).focused($naming)
                .frame(width: min(480, panelWidth - 80), height: 40)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                .accessibilityLabel("Folder Name")
                .onSubmit { commitName(); naming = false }
            LauncherDropTarget(enabled: !busy, currentApplication: currentItem,
                               receive: { receive($0, applications.count) }) { targeted in
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 72), spacing: 12), count: 6),
                              spacing: 24) {
                        ForEach(Array(applications.enumerated()), id: \.element.id) { index, application in
                            LauncherDropTarget(enabled: !busy, outlined: true, currentApplication: currentItem,
                                               receive: { receive($0, index) }) { _ in
                                ApplicationTile(application: application, image: icons.image(for: application),
                                    iconSize: min(88, max(72, (panelWidth - 80) / 6 - 28)),
                                    opening: openingID == application.id, needsInstall: false,
                                    beginDrag: { beginDrag(application.id) }) {
                                        commitName(); launch(application)
                                    }
                                    .matchedGeometryEffect(id: application.id, in: arrangementNamespace, properties: .position)
                                    .focused($focusedApplication, equals: application.id)
                                    .disabled(busy)
                                    .contextMenu {
                                        Button("Open") { commitName(); launch(application) }.disabled(busy)
                                        if application.isImported {
                                            Button("Change Icon…") { commitName(); configureIcon(application) }.disabled(busy)
                                        }
                                        if application.kind != .steam {
                                            Button("Application Settings…") { commitName(); configureGraphics(application) }.disabled(busy)
                                        }
                                        Button("Move Out of Folder") { commitName(); moveOut(application.id) }.disabled(busy)
                                    }
                            }
                        }
                    }.padding(.horizontal, 40).padding(.vertical, 28)
                }
                .scrollIndicators(.hidden)
                .frame(width: panelWidth, height: max(144, maxHeight - 64))
                .background {
                    let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
                    if reduceTransparency { shape.fill(Color(nsColor: .windowBackgroundColor)) }
                    else { shape.fill(.regularMaterial) }
                    shape.fill(.white.opacity(targeted ? 0.09 : 0.025))
                }
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(.white.opacity(targeted ? 0.5 : 0.16), lineWidth: 1).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.22), radius: 32, y: 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(folder.name) folder")
        .onAppear { name = folder.name; naming = editingName }
        .onChange(of: naming) { _, value in if !value { commitName() } }
        .onDisappear { commitName() }
        .onMoveCommand { direction in
            guard !naming, !applications.isEmpty else { return }
            let current = applications.firstIndex { $0.id == focusedApplication } ?? 0
            let offset: Int
            switch direction {
            case .left: offset = -1
            case .right: offset = 1
            case .up: offset = -6
            case .down: offset = 6
            @unknown default: return
            }
            focusedApplication = applications[min(max(current + offset, 0), applications.count - 1)].id
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { name = folder.name }
        else if trimmed != folder.name { rename(trimmed) }
    }
}
