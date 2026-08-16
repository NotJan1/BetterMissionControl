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
                // Fades up with the tiles, so the real desktop is still
                // visible behind them as they start moving.
                background
                    .opacity(model.isRevealed ? 1 : 0)
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
            // Already blurred when captured — no `.blur` here on purpose.
            Image(decorative: desktop, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fill)
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
                let revealed = model.isRevealed
                // Mission Control's signature move: each tile begins life at
                // its window's real position and size, then flies into the
                // overview. Scaling rather than resizing keeps the thumbnail's
                // proportions exact throughout.
                let scale = revealed ? 1 : model.sourceScale(for: window, tile: tileSize)
                let place = revealed
                    ? model.center(for: window, in: size)
                    : model.sourceCenter(for: window)

                // `.equatable()` keeps a drag from re-rendering every tile:
                // only the one whose position changed compares unequal, so the
                // rest are skipped entirely. It needs the concrete tile view,
                // so the gesture is attached out here rather than inside.
                tile(for: window, cell: cell)
                    .equatable()
                    .frame(width: tileSize.width, height: tileSize.height)
                    .scaleEffect(scale)
                    .opacity(revealed ? 1 : 0)
                    .gesture(dragGesture(for: window, in: size))
                    .position(place)
                    .zIndex(model.zIndex(for: window))
            }
        }
        .frame(width: size.width, height: size.height)
        // Tiles are no longer animated into place by a stack layout, so the
        // automatic arrangement settling in gets a gentle move of its own —
        // but never while dragging, where any implicit animation on position
        // reads as the tile lagging behind the pointer.
        .animation(
            model.draggingID == nil ? .easeOut(duration: 0.18) : nil,
            value: model.windows.count
        )
    }

    private func tile(for window: ManagedWindow, cell: CGSize) -> WindowTileView {
        let isDragging = model.draggingID == window.id
        return WindowTileView(
            window: window,
            isSelected: model.selectedID == window.id,
            isHovering: model.hoveredID == window.id,
            isDragging: isDragging,
            thumbnailSize: window.thumbnailSize(in: cell),
            onHover: { inside in
                // Ignored mid-drag: the pointer sweeps across other tiles on
                // the way, and each hover change invalidates the whole canvas.
                guard model.draggingID == nil else { return }
                if inside {
                    model.hoveredID = window.id
                } else if model.hoveredID == window.id {
                    model.hoveredID = nil
                }
            },
            onActivate: { onActivate(window) },
            onClose: { model.close(window) }
        )
    }

    /// `minimumDistance` is what separates a click-to-activate from a drag —
    /// below it the tile's own tap gesture wins.
    ///
    /// The coordinate space matters more than it looks. A `DragGesture`
    /// defaults to `.local`, meaning the tile's *own* space — and this gesture
    /// moves that very tile. So each frame the tile chased the pointer, its
    /// coordinate space moved with it, the pointer appeared to have travelled
    /// less than it had, and the next translation came back smaller. The tile
    /// converged on the pointer instead of tracking it, which is exactly the
    /// "it behaves like it has drag" feel. `.global` is stationary, so
    /// translation is the true pointer delta.
    private func dragGesture(for window: ManagedWindow, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
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
