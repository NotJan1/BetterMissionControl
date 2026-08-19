import AppKit
import SwiftUI

/// One window in the overview: live thumbnail, close badge, app icon + title.
struct WindowTileView: View {
    let window: ManagedWindow
    let isSelected: Bool
    let isHovering: Bool
    let isDragging: Bool
    /// Exact drawn size, computed by `OverlayLayout` rather than inferred from
    /// the layout system, so the tile always matches the window's proportions.
    let thumbnailSize: CGSize
    /// Size of the app icon straddling the thumbnail's bottom edge.
    let iconSize: CGFloat
    let onHover: (Bool) -> Void
    let onActivate: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onForceQuit: () -> Void

    /// The close badge is revealed on hover or selection, the way Mission
    /// Control reveals its own controls, rather than cluttering every tile.
    private var showsCloseButton: Bool { isHovering || isSelected }

    var body: some View {
        VStack(spacing: OverlayLayout.labelSpacing) {
            thumbnail
                // The icon hangs half past the bottom edge, so the space it
                // needs is reserved here rather than eating into the image.
                .overlay(alignment: .bottom) { appIcon.offset(y: iconSize / 2) }
                .padding(.bottom, iconSize / 2)
            label
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        // R8: a click anywhere but the close control activates the window.
        .onTapGesture(perform: onActivate)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.appName): \(window.displayTitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Thumbnail

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.28))

            if let image = window.thumbnail {
                Image(decorative: image, scale: 2, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(
                        RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
                    )
            } else {
                placeholder
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .overlay(selectionRing)
        .overlay(alignment: .topLeading) { closeButton }
        // Lifting the tile while it's dragged makes it read as picked up,
        // which matters more now that tiles can overlap.
        .shadow(
            color: .black.opacity(isDragging ? 0.6 : 0.45),
            radius: isDragging ? 26 : (isSelected ? 18 : 11),
            y: isDragging ? 14 : (isSelected ? 8 : 5)
        )
        .scaleEffect(isDragging ? 1.05 : (isHovering && !isSelected ? 1.02 : 1))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isDragging)
    }

    /// Large app icon, the way Mission Control marks each window.
    private var appIcon: some View {
        Group {
            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "macwindow")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: iconSize, height: iconSize)
        // Reads against any thumbnail behind it, light or dark.
        .shadow(color: .black.opacity(0.55), radius: 5, y: 2)
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                if let icon = window.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .opacity(0.55)
                }
            }
    }

    private var selectionRing: some View {
        RoundedRectangle(cornerRadius: OverlayLayout.cornerRadius, style: .continuous)
            .strokeBorder(
                isSelected ? Color.accentColor : Color.white.opacity(0.14),
                lineWidth: isSelected ? 3 : 1
            )
    }

    /// The window's own traffic lights, plus one macOS doesn't offer.
    ///
    /// R7: each works without selecting the tile first.
    private var closeButton: some View {
        // Order, colours and glyphs follow AltTab: the extra purple control
        // sits to the *left* of the standard three, so the familiar traffic
        // lights keep their usual relative positions.
        HStack(spacing: 7) {
            trafficLight(
                color: Color(red: 0.66, green: 0.29, blue: 0.92),
                symbol: "power",
                help: "Force quit \(window.appName) — unsaved work is lost",
                action: onForceQuit
            )
            trafficLight(
                color: Color(red: 0.96, green: 0.34, blue: 0.29),
                symbol: "xmark",
                help: "Close this window",
                action: onClose
            )
            trafficLight(
                color: Color(red: 0.78, green: 0.58, blue: 0.09),
                symbol: "minus",
                help: "Minimize this window",
                action: onMinimize
            )
            trafficLight(
                color: Color(red: 0.23, green: 0.77, blue: 0.29),
                symbol: "arrow.up.left.and.arrow.down.right",
                help: "Zoom this window",
                action: onZoom
            )
        }
        .padding(8)
        .opacity(showsCloseButton ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: showsCloseButton)
    }

    private func trafficLight(
        color: Color,
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 17, height: 17)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.7))
                }
                .overlay(Circle().strokeBorder(.black.opacity(0.22), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(help), \(window.displayTitle)")
    }

    // MARK: - Label

    private var label: some View {
        Text(window.displayTitle)
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            // Opaque enough to stay readable when tiles overlap — a translucent
            // capsule let the label underneath bleed through and the two ran
            // together into nonsense.
            .background { Capsule().fill(Color.black.opacity(isSelected ? 0.8 : 0.55)) }
            .frame(height: OverlayLayout.titleHeight)
    }
}

/// Lets SwiftUI skip tiles that haven't changed. Without this every tile
/// re-renders on every frame of a drag, because the whole window array is
/// republished each time the dragged tile moves.
extension WindowTileView: Equatable {
    static func == (lhs: WindowTileView, rhs: WindowTileView) -> Bool {
        lhs.window == rhs.window
            && lhs.isSelected == rhs.isSelected
            && lhs.isHovering == rhs.isHovering
            && lhs.isDragging == rhs.isDragging
            && lhs.thumbnailSize == rhs.thumbnailSize
            && lhs.iconSize == rhs.iconSize
    }
}
