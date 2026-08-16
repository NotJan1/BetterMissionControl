import AppKit
import SwiftUI

/// The full-screen overview: dimmed desktop behind freely placed window tiles.
struct OverlayView: View {
    let model: OverviewModel
    let hotKeyDisplay: String
    let onDismiss: () -> Void
    let onActivate: (ManagedWindow) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background
                // R9: a click that isn't on a tile dismisses with no action.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                content(in: geometry.size)

                if let message = model.actionMessage {
                    banner(message)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.actionMessage)
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
            canvas(in: size)
        }
    }

    /// R4: a free canvas rather than a grid — every tile sits at its own
    /// position and can be dragged anywhere inside the overlay.
    private func canvas(in size: CGSize) -> some View {
        let cell = model.cellSize(in: size)

        return ZStack(alignment: .topLeading) {
            ForEach(model.windows) { window in
                // Framed to the tile's own size, not the cell: a cell can be
                // far taller than the window's proportions, and framing to it
                // both stretched the tile and gave it a hit area that spilled
                // over its neighbours.
                let tileSize = window.tileSize(in: cell)
                tile(for: window, in: size, cell: cell)
                    .frame(width: tileSize.width, height: tileSize.height)
                    .position(model.center(for: window, in: size))
                    .zIndex(model.zIndex(for: window))
            }
        }
        .frame(width: size.width, height: size.height)
        // Tiles are no longer animated into place by a stack layout, so the
        // automatic arrangement settling in gets a gentle move of its own.
        .animation(.easeOut(duration: 0.18), value: model.windows.count)
    }

    private func tile(for window: ManagedWindow, in size: CGSize, cell: CGSize) -> some View {
        let isDragging = model.draggingID == window.id
        return WindowTileView(
            window: window,
            isSelected: model.selectedID == window.id,
            isHovering: model.hoveredID == window.id,
            isDragging: isDragging,
            thumbnailSize: window.thumbnailSize(in: cell),
            onHover: { inside in
                if inside {
                    model.hoveredID = window.id
                } else if model.hoveredID == window.id {
                    model.hoveredID = nil
                }
            },
            onActivate: { onActivate(window) },
            onClose: { model.close(window) }
        )
        .gesture(dragGesture(for: window, in: size))
    }

    /// `minimumDistance` is what separates a click-to-activate from a drag —
    /// below it the tile's own tap gesture wins.
    private func dragGesture(for window: ManagedWindow, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                model.beginDrag(window)
                model.updateDrag(window, translation: value.translation, in: size)
            }
            .onEnded { _ in
                model.endDrag()
            }
    }

    private func banner(_ text: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.black.opacity(0.72), in: Capsule())
            .padding(.bottom, 46)
        }
        .allowsHitTesting(false)
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
