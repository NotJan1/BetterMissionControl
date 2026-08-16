import AppKit
import SwiftUI

/// One window in the overview: live thumbnail, close badge, app icon + title.
struct WindowTileView: View {
    let window: ManagedWindow
    let isSelected: Bool
    let isHovering: Bool
    let isDragging: Bool
    let onHover: (Bool) -> Void
    let onActivate: () -> Void
    let onClose: () -> Void

    /// The close badge is revealed on hover or selection, the way Mission
    /// Control reveals its own controls, rather than cluttering every tile.
    private var showsCloseButton: Bool { isHovering || isSelected }

    var body: some View {
        VStack(spacing: OverlayLayout.labelSpacing) {
            thumbnail
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
        .aspectRatio(window.aspectRatio, contentMode: .fit)
        // Never draw a window larger than it actually is. A small window
        // stretched to fill a large tile has no more detail to show, so it
        // just looks blurry — better to leave it at native size, which is
        // also what native Mission Control does.
        .frame(maxWidth: window.frame.width, maxHeight: window.frame.height)
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

    /// R7: works without the tile being selected first.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 19, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.black.opacity(0.65))
                .background(Circle().fill(.black.opacity(0.35)).padding(2))
        }
        .buttonStyle(.plain)
        .padding(6)
        .opacity(showsCloseButton ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: showsCloseButton)
        .help("Close this window")
        .accessibilityLabel("Close \(window.displayTitle)")
    }

    // MARK: - Label

    private var label: some View {
        HStack(spacing: 5) {
            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
            }
            Text(window.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.82))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(Color.black.opacity(isSelected ? 0.55 : 0.35))
        }
        .frame(height: OverlayLayout.labelHeight)
    }
}
