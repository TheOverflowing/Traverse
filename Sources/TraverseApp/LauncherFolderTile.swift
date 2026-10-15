import AppKit
import SwiftUI
import TraverseCore

@MainActor
struct LauncherFolderTile: View {
    let folder: LauncherFolder
    let applications: [LauncherApplication]
    let icons: ApplicationIconResolver
    let iconSize: CGFloat
    let targeted: Bool
    let beginDrag: (() -> Void)?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false

    init(folder: LauncherFolder, applications: [LauncherApplication],
         icons: ApplicationIconResolver, iconSize: CGFloat, targeted: Bool = false,
         beginDrag: (() -> Void)? = nil,
         action: @escaping () -> Void) {
        self.folder = folder
        self.applications = applications
        self.icons = icons
        self.iconSize = iconSize
        self.targeted = targeted
        self.beginDrag = beginDrag
        self.action = action
    }

    var body: some View {
        VStack(spacing: 12) {
            draggableIcon.frame(height: 92)
                .background { LauncherTileHighlight(hovered: hovered, iconSize: iconSize) }
            Text(folder.name).font(.system(size: 13, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(height: 36, alignment: .top).contentShape(Rectangle()).onTapGesture(perform: action)
        }
        .frame(maxWidth: .infinity).frame(height: 144)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { action(); return .handled }
        .onKeyPress(.space) { action(); return .handled }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(folder.name)
        .accessibilityValue("\(applications.count) \(applications.count == 1 ? "application" : "applications")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityHint("Open folder or drag to arrange")
        .help("Open \(folder.name)")
    }

    @ViewBuilder private var draggableIcon: some View {
        if let beginDrag { LauncherDraggableIcon(id: folder.id, begin: beginDrag, action: action) { folderIcon } }
        else { folderIcon.onTapGesture(perform: action) }
    }

    private var folderIcon: some View {
        let shape = RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
        let padding = iconSize * 0.11
        let spacing = iconSize * 0.055
        let miniSize = (iconSize - padding * 2 - spacing * 2) / 3
        return ZStack {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(.regularMaterial)
            }
            shape.fill(.white.opacity(targeted ? 0.17 : 0.06))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(miniSize), spacing: spacing), count: 3),
                      alignment: .leading, spacing: spacing) {
                ForEach(Array(applications.prefix(9))) { application in
                    miniIcon(application, size: miniSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(padding)
            shape.strokeBorder(.white.opacity(targeted ? 0.65 : 0.17), lineWidth: 1)
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.22), radius: 9, x: 0, y: 5)
        .scaleEffect(targeted && !reduceMotion ? 1.035 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1), value: targeted)
    }

    @ViewBuilder private func miniIcon(_ application: LauncherApplication, size: CGFloat) -> some View {
        if let image = icons.image(for: application) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.white.opacity(0.18))
                .overlay(Image(systemName: application.kind == .steamGame ? "gamecontroller.fill" : "app.fill")
                    .font(.system(size: size * 0.52)).foregroundStyle(.white.opacity(0.85)))
                .frame(width: size, height: size)
        }
    }
}

struct LauncherTileHighlight: View {
    let hovered: Bool
    let iconSize: CGFloat
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: iconSize * 0.22 + 4, style: .continuous)
            .fill(.white.opacity(focused ? 0.09 : hovered ? 0.065 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: iconSize * 0.22 + 4, style: .continuous)
                    .strokeBorder(.white.opacity(focused ? (contrast == .increased ? 0.65 : 0.3) : 0), lineWidth: 1.5)
            }
            .frame(width: iconSize + 8, height: iconSize + 8)
            .allowsHitTesting(false)
    }
}
