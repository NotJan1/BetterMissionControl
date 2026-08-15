import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The full-screen overview: dimmed desktop behind a grid of window tiles.
struct OverlayView: View {
    let model: OverviewModel
    let hotKeyDisplay: String
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background
                // R9: a click that isn't on a tile dismisses with no action.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                content(in: geometry.size)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Background

    /// Showing the *desktop* rather than a blur of whatever windows sit behind
    /// the overlay is what sells the Mission Control resemblance.
    @ViewBuilder
    private var background: some View {
        if let desktop = model.desktopPicture {
            Image(decorative: desktop, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 9)
                .overlay(Color.black.opacity(0.42))
                .clipped()
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.32))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        switch model.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case .empty:
            message(
                symbol: "macwindow.badge.plus",
                title: "No open windows",
                detail: "Nothing to show right now. Press \(hotKeyDisplay) again once you've opened a window."
            )
        case .missingPermissions(let permissions):
            PermissionsNoticeView(permissions: permissions, onDismiss: onDismiss)
        case .ready:
            grid(in: size)
        }
    }

    private func grid(in size: CGSize) -> some View {
        let columns = OverlayLayout.columnCount(for: model.windows.count, in: size)
        let cell = OverlayLayout.cellSize(count: model.windows.count, columns: columns, in: size)
        let rows = model.windows.chunked(into: columns)

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: OverlayLayout.spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: OverlayLayout.spacing) {
                        ForEach(row) { window in
                            tile(for: window)
                                .frame(width: cell.width, height: cell.height)
                        }
                        // Keeps a short final row left-aligned with the rows
                        // above it instead of centring it on its own.
                        if row.count < columns {
                            Spacer(minLength: 0)
                                .frame(
                                    width: CGFloat(columns - row.count)
                                        * (cell.width + OverlayLayout.spacing)
                                )
                        }
                    }
                }
            }
            .padding(OverlayLayout.outerPadding)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func tile(for window: ManagedWindow) -> some View {
        WindowTileView(
            window: window,
            isSelected: model.selectedID == window.id,
            isHovering: model.hoveredID == window.id,
            onHover: { inside in
                if inside {
                    model.hoveredID = window.id
                } else if model.hoveredID == window.id {
                    model.hoveredID = nil
                }
            },
            onActivate: {
                model.activate(window)
                onDismiss()
            },
            onClose: { model.close(window) }
        )
        // R4: drag a tile onto another to take its place in the order.
        .draggable(String(window.id)) {
            dragPreview(for: window)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let draggedID = CGWindowID(raw) else { return false }
            model.move(id: draggedID, toIndexOf: window.id)
            return true
        }
    }

    private func dragPreview(for window: ManagedWindow) -> some View {
        Group {
            if let image = window.thumbnail {
                Image(decorative: image, scale: 2, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius)
                    .fill(Color.gray.opacity(0.6))
            }
        }
        .frame(width: 180)
        .opacity(0.85)
    }

    private func message(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.white.opacity(0.75))
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(36)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Shown inside the overlay when a permission is missing, so the hotkey always
/// explains itself instead of silently producing an empty grid.
struct PermissionsNoticeView: View {
    let permissions: [Permission]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Better Mission Control needs permission")
                    .font(.system(size: 21, weight: .semibold))
                Text("macOS keeps these switched off until you turn them on by hand.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            ForEach(permissions) { permission in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: permission.symbolName)
                        .font(.system(size: 17))
                        .frame(width: 24)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(permission.title).font(.system(size: 14, weight: .medium))
                        Text(permission.explanation)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Open Settings") {
                        PermissionsManager.openSettings(for: permission)
                        onDismiss()
                    }
                }
            }

            if permissions.contains(where: \.requiresRelaunchAfterGranting) {
                Text("Quit and reopen Better Mission Control after granting Screen Recording — macOS only checks it at launch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        )
        .shadow(radius: 30, y: 12)
    }
}
