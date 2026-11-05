import AppKit
import SwiftUI

/// One entry in a launchpad list — a recent note, or a note belonging to one of
/// the configured capture kinds.
struct LaunchpadRecentItem: Identifiable, Equatable {
    let id: String
    let title: String          // filename without extension
    let relativePath: String   // full relative path inside the workspace
    let folderLabel: String    // last folder in the note's chain, for context
}

/// New-tab surface: the Miller browser, full bleed.
///
/// This used to stack a scratchpad pill strip, a recent pill strip, and a
/// "BROWSE" section label above a boxed Miller browser that got whatever height
/// was left. Three competing lists on one page made it noisy, and the browser —
/// the thing actually used to navigate — was the smallest element on it. The
/// columns now own the page.
struct LaunchpadView<BrowseContent: View>: View {
    let browseContent: () -> BrowseContent

    init(@ViewBuilder browseContent: @escaping () -> BrowseContent) {
        self.browseContent = browseContent
    }

    var body: some View {
        browseContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DesignTokens.Surface.base)
    }
}

// MARK: — recent pill

struct LaunchpadRecentPill: View {
    let item: LaunchpadRecentItem
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.space2) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(DesignTokens.TextStyle.secondary)

                Text(item.title)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.TextStyle.primary)
                    .lineLimit(1)

                Text(item.folderLabel)
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(DesignTokens.TextStyle.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.space3)
            .padding(.vertical, DesignTokens.Spacing.space3)
            .background(
                Capsule()
                    .fill(isHovering ? DesignTokens.Surface.overlay : DesignTokens.Surface.raised)
            )
            .overlay(
                Capsule()
                    .strokeBorder(DesignTokens.TextStyle.tertiary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("Open \(item.title)")
    }
}

// MARK: — previews

private struct LaunchpadBrowsePlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
            .stroke(
                DesignTokens.TextStyle.tertiary.opacity(0.3),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            .overlay {
                VStack(spacing: DesignTokens.Spacing.space2) {
                    Image(systemName: "square.grid.3x1.folder.badge.plus")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(DesignTokens.TextStyle.tertiary)
                    Text("Miller columns render here in the live app")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.TextStyle.tertiary)
                }
            }
    }
}

#Preview("Launchpad — full-bleed browser") {
    LaunchpadView(browseContent: { LaunchpadBrowsePlaceholder() })
        .frame(width: 1200, height: 820)
}

#Preview("Launchpad — narrow window") {
    LaunchpadView(browseContent: { LaunchpadBrowsePlaceholder() })
        .frame(width: 760, height: 620)
}
