import Foundation
import SwiftUI

extension Notification.Name {
    static let documentInspectorOpenRequested = Notification.Name("nvmodern.documentInspectorOpenRequested")
}

enum DocumentInspectorNotification {
    static let windowNumberKey = "windowNumber"
}

enum DocumentWordCounter {
    static func count(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }
}

struct DocumentInspectorPopoverView: View {
    @ObservedObject private var kernelStatus = ArborKernelStatusStore.shared

    @Binding var settings: DocumentInspectorSettings
    let effectiveAppearance: DocumentInspectorAppearance
    let frontmatterAppearance: DocumentFrontmatterAppearance?
    let wordCount: Int
    let canUnwrapProseLines: Bool
    var usesPublisherThemeDefault: Bool = false
    let onReset: () -> Void
    /// Column mode drops the popover chrome (title row, fixed width,
    /// window-background fill) so the view can live inside a full-height
    /// inspector column with its own header.
    var embedsInColumn: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedsInColumn {
                header
            }
            frontmatterOverrideNote
            if usesPublisherThemeDefault {
                epubOverrideSection
                Divider().opacity(0.5)
            }
            widthSection
                .disabled(!appearanceControlsEnabled)
            scaleSection
                .disabled(!appearanceControlsEnabled)
            Divider().opacity(0.5)
            markdownSection
            Divider().opacity(0.5)
            themeSection
                .disabled(!appearanceControlsEnabled)
            Divider().opacity(0.5)
            footer
        }
        .padding(embedsInColumn ? EdgeInsets(top: 14, leading: 14, bottom: 16, trailing: 14) : EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
        .frame(width: embedsInColumn ? nil : 320)
        .background(embedsInColumn ? Color.clear : Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Document")
                .font(DesignTokens.Typography.heading)
                .foregroundStyle(DesignTokens.TextStyle.primary)
            Spacer()
            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Reset document inspector")
        }
    }

    @ViewBuilder
    private var frontmatterOverrideNote: some View {
        if let frontmatterSummary {
            Text("Frontmatter overrides \(frontmatterSummary).")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.TextStyle.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.input)
                        .fill(DesignTokens.Surface.selected.opacity(0.65))
                )
        }
    }

    private var scaleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scale")
                    .font(DesignTokens.Typography.secondary)
                    .foregroundStyle(DesignTokens.TextStyle.secondary)
                Spacer()
                Text(settings.scale.title)
                    .font(DesignTokens.Typography.captionMono)
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.TextStyle.primary)
            }

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    // No `step:`: AppKit draws tick marks under a stepped
                    // slider. `DocumentInspectorScale` already rounds to whole
                    // percentages, so the value stays integral without it.
                    Slider(
                        value: Binding(
                            get: { settings.scale.percentage },
                            set: { settings.scale = DocumentInspectorScale(percentage: $0) }
                        ),
                        in: DocumentInspectorScale.range
                    )
                    .controlSize(.small)
                    .accessibilityLabel("Document scale")
                    .accessibilityValue(settings.scale.title)

                    Button {
                        settings.scale = .normal
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        settings.scale == .normal
                            ? DesignTokens.TextStyle.tertiary
                            : DesignTokens.TextStyle.secondary
                    )
                    .disabled(settings.scale == .normal)
                    .help("Reset scale to 100%")
                    .accessibilityLabel("Reset document scale to 100 percent")
                }

                HStack(spacing: 8) {
                    HStack {
                        Text("75%")
                        Spacer()
                        Text("125%")
                    }
                    .font(DesignTokens.Typography.captionMono)
                    .foregroundStyle(DesignTokens.TextStyle.tertiary)

                    Spacer()
                        .frame(width: 40)
                }
            }
        }
    }

    private var widthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Width")
                .font(DesignTokens.Typography.secondary)
                .foregroundStyle(DesignTokens.TextStyle.secondary)

            InspectorWidthButtons(selection: $settings.width)
        }
    }

    private var markdownSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Unwrap prose lines", isOn: $settings.unwrapMarkdownLines)
                .toggleStyle(.switch)
                .disabled(!canUnwrapProseLines)
                .accessibilityHint("Joins soft paragraph line breaks in the editor view")

            Text("Joins soft paragraph breaks in the editor view. The file stays unchanged.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.TextStyle.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Theme")
                .font(DesignTokens.Typography.secondary)
                .foregroundStyle(DesignTokens.TextStyle.secondary)

            InspectorThemeList(themes: availableThemes + [missingTheme].compactMap { $0 }, selection: $settings.theme)
        }
    }

    private var epubOverrideSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Override Theme", isOn: epubThemeOverrideBinding)
                .toggleStyle(.switch)
            Text("Off uses the EPUB publisher’s original appearance.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.TextStyle.tertiary)
        }
    }

    private var appearanceControlsEnabled: Bool {
        !usesPublisherThemeDefault
            || settings.theme.rawValue != UserEditorThemeCatalog.reservedThemeID
    }

    private var epubThemeOverrideBinding: Binding<Bool> {
        Binding(
            get: { appearanceControlsEnabled },
            set: { enabled in
                if enabled {
                    if settings.theme.rawValue == UserEditorThemeCatalog.reservedThemeID,
                       let firstTheme = availableThemes.first {
                        settings.theme = DocumentThemeID(rawValue: firstTheme.id)
                    }
                } else {
                    settings.theme = .system
                }
            }
        )
    }

    /// The unified set: System, bundled themes, and user themes from the
    /// themes directory (which shadow same-named bundled themes).
    private var availableThemes: [AvailableEditorTheme] {
        let themes = EditorThemeRegistry.availableThemes(in: UserEditorThemeCatalog.currentDirectoryURL)
        guard usesPublisherThemeDefault else { return themes }
        return themes.filter { $0.id != UserEditorThemeCatalog.reservedThemeID }
    }

    /// A configured per-document theme that resolves to no file stays visible
    /// so it can be recognized (and replaced) rather than silently vanishing.
    private var missingTheme: AvailableEditorTheme? {
        let selected = settings.theme.rawValue
        guard selected != UserEditorThemeCatalog.reservedThemeID,
              !availableThemes.contains(where: { $0.id == selected }) else {
            return nil
        }
        return AvailableEditorTheme(
            id: selected,
            title: UserEditorThemeCatalog.displayTitle(for: selected),
            subtitle: "Missing theme file",
            swatchHexes: [],
            isBundled: false,
            fileURL: nil
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(footerText)
            Text(kernelStatus.summary)
        }
        .font(DesignTokens.Typography.captionMono)
        .foregroundStyle(DesignTokens.TextStyle.tertiary)
    }

    private var frontmatterSummary: String? {
        guard let frontmatterAppearance else { return nil }
        var labels: [String] = []
        if frontmatterAppearance.theme != nil {
            labels.append("theme")
        }
        if frontmatterAppearance.width != nil {
            labels.append("width")
        }
        if frontmatterAppearance.fontFamily != nil {
            labels.append("font-family")
        }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    private var footerText: String {
        var parts = [
            effectiveAppearance.settings.width.cssValue,
            effectiveAppearance.settings.scale.title,
            "\(wordCount) \(wordCount == 1 ? "word" : "words")"
        ]
        if let fontFamily = effectiveAppearance.fontFamily {
            parts.append(fontFamily)
        }
        return parts.joined(separator: " · ")
    }
}

/// Inspector-column content for the native shell. Unlike the compact popover
/// above, this is a full document inspector: document facts use standard
/// labeled rows and appearance controls use a grouped form. Diagnostics do not
/// belong here; they remain available through the app's diagnostics surfaces.
struct NativeDocumentInspectorView: View {
    @Binding var settings: DocumentInspectorSettings
    let frontmatterAppearance: DocumentFrontmatterAppearance?
    let title: String?
    let relativePath: String?
    let modifiedDate: Date?
    let mimeType: String?
    let fileSize: Int64?
    let wordCount: Int
    let canUnwrapProseLines: Bool
    var usesPublisherThemeDefault: Bool = false
    let onReset: () -> Void
    let canRunFileActions: Bool
    let onShowInFinder: () -> Void
    let onReloadFromDisk: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            detailsForm
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                InspectorThemeList(themes: availableThemes, selection: $settings.theme)
                    .disabled(!appearanceControlsEnabled)
            }
            .padding(16)
        }
    }

    private var detailsForm: some View {
        Form {
            Section("Document") {
                if let title, !title.isEmpty {
                    LabeledContent("Name") {
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(title)
                    }
                }

                if let relativePath, !relativePath.isEmpty {
                    LabeledContent("Location") {
                        Text(relativePath.replacingOccurrences(of: "/", with: " › "))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(relativePath)
                    }
                }

                LabeledContent("Words", value: wordCount.formatted())

                if let fileSize {
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                }

                if let modifiedDate {
                    LabeledContent("Modified") {
                        Text(modifiedDate, format: .dateTime.year().month().day().hour().minute())
                    }
                }

                if let formatDescription {
                    LabeledContent("Format", value: formatDescription)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { fileActionButtons }
                    VStack(alignment: .leading, spacing: 8) { fileActionButtons }
                }
                .labelStyle(.titleOnly)
                .controlSize(.small)
                .font(.system(size: 11))
                .disabled(!canRunFileActions)
            }

            if let frontmatterSummary {
                Section {
                    Label(frontmatterSummary, systemImage: "doc.badge.gearshape")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Overrides")
                } footer: {
                    Text("Document frontmatter takes precedence over the controls below.")
                }
            }

            Section {
                if usesPublisherThemeDefault {
                    Toggle("Override Theme", isOn: epubThemeOverrideBinding)
                        .toggleStyle(.switch)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Width")
                        .foregroundStyle(.secondary)
                    InspectorWidthButtons(selection: $settings.width)
                }
                .disabled(!appearanceControlsEnabled)

                LabeledContent("Scale") {
                    HStack(spacing: 8) {
                        // See the compact slider above: no `step:`, so the
                        // track draws without tick marks.
                        Slider(
                            value: Binding(
                                get: { settings.scale.percentage },
                                set: { settings.scale = DocumentInspectorScale(percentage: $0) }
                            ),
                            in: DocumentInspectorScale.range
                        )
                        .frame(minWidth: 100, idealWidth: 140)
                        .accessibilityLabel("Document scale")

                        Text(settings.scale.title)
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                .disabled(!appearanceControlsEnabled)

                Button(action: onReset) {
                    Label("Reset Appearance", systemImage: "arrow.counterclockwise")
                }
                .disabled(settings == .default)
            } header: {
                Text("Appearance")
            } footer: {
                if usesPublisherThemeDefault && !appearanceControlsEnabled {
                    Text("Using the EPUB publisher’s original appearance.")
                }
            }

            Section {
                Toggle("Unwrap prose lines", isOn: $settings.unwrapMarkdownLines)
                    .toggleStyle(.switch)
                    .disabled(!canUnwrapProseLines)
                    .accessibilityHint("Joins soft paragraph line breaks in the editor view")
            } header: {
                Text("Text")
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    @ViewBuilder
    private var fileActionButtons: some View {
        Button(action: onShowInFinder) {
            Label("Show in Finder", systemImage: "folder")
        }
        Button(action: onReloadFromDisk) {
            Label("Reload from Disk", systemImage: "arrow.clockwise")
        }
    }

    private var availableThemes: [AvailableEditorTheme] {
        let themes = EditorThemeRegistry.availableThemes(in: UserEditorThemeCatalog.currentDirectoryURL)
        guard usesPublisherThemeDefault else { return themes }
        return themes.filter { $0.id != UserEditorThemeCatalog.reservedThemeID }
    }

    private var appearanceControlsEnabled: Bool {
        !usesPublisherThemeDefault
            || settings.theme.rawValue != UserEditorThemeCatalog.reservedThemeID
    }

    private var epubThemeOverrideBinding: Binding<Bool> {
        Binding(
            get: { appearanceControlsEnabled },
            set: { enabled in
                if enabled {
                    if settings.theme.rawValue == UserEditorThemeCatalog.reservedThemeID,
                       let firstTheme = availableThemes.first {
                        settings.theme = DocumentThemeID(rawValue: firstTheme.id)
                    }
                } else {
                    settings.theme = .system
                }
            }
        )
    }

    private var formatDescription: String? {
        if let mimeType, !mimeType.isEmpty {
            return mimeType
        }
        guard let relativePath else { return nil }
        let pathExtension = (relativePath as NSString).pathExtension
        return pathExtension.isEmpty ? nil : pathExtension.uppercased()
    }

    private var frontmatterSummary: String? {
        guard let frontmatterAppearance else { return nil }
        var labels: [String] = []
        if frontmatterAppearance.theme != nil { labels.append("Theme") }
        if frontmatterAppearance.width != nil { labels.append("Width") }
        if frontmatterAppearance.fontFamily != nil { labels.append("Font family") }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }


}

private struct InspectorWidthButtons: View {
    @Binding var selection: DocumentInspectorWidth

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DocumentInspectorWidth.allCases) { width in
                Button { selection = width } label: {
                    Text(width.title)
                        .font(.system(size: 11, weight: selection == width ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selection == width ? Color.accentColor : Color.clear)
                        }
                        .foregroundStyle(selection == width ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(width.title) document width")
                .accessibilityAddTraits(selection == width ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document width")
    }
}

private struct InspectorThemeList: View {
    let themes: [AvailableEditorTheme]
    @Binding var selection: DocumentThemeID
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var previewStore = EditorThemePreviewStore()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(themes) { theme in
                        ThemeRow(
                            theme: theme,
                            preview: previewStore.previews[theme.id],
                            isSelected: selection.rawValue == theme.id,
                            action: { selection = DocumentThemeID(rawValue: theme.id) }
                        )
                        .frame(height: 30)
                        .id(theme.id)
                    }
                }
            }
            .frame(height: CGFloat(min(themes.count, 6)) * 30)
            .onAppear { proxy.scrollTo(selection.rawValue, anchor: .center) }
        }
        .task(id: "\(colorScheme)-\(themes.hashValue)") {
            previewStore.load(themes: themes, dark: colorScheme == .dark)
        }
    }
}

private struct ThemeRow: View {
    let theme: AvailableEditorTheme
    let preview: EditorThemePreviewStore.Preview?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ThemeSwatch(hexes: theme.swatchHexes, showsDynamicFallback: theme.isBundled, colors: preview?.colors)
                Text(theme.title)
                    .font(preview.map { Font($0.font) } ?? DesignTokens.Typography.bodyMedium)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DesignTokens.TextStyle.primary)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.Accent.nav)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.input)
                    .fill(isSelected ? DesignTokens.Surface.selected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ThemeSwatch: View {
    let hexes: [String]
    let showsDynamicFallback: Bool
    var colors: [Color]? = nil

    var body: some View {
        HStack(spacing: 0) {
            if let colors, !colors.isEmpty {
                ForEach(colors.indices, id: \.self) { index in
                    colors[index]
                }
            } else if hexes.isEmpty {
                if showsDynamicFallback {
                    color(0)
                    color(1)
                    color(2)
                } else {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(DesignTokens.Surface.overlay)
                }
            } else if hexes.count == 1 {
                swatchColor(hexes[0])
            } else {
                ForEach(hexes.indices, id: \.self) { index in
                    swatchColor(hexes[index])
                }
            }
        }
        .frame(width: 28, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(DesignTokens.TextStyle.tertiary.opacity(0.3), lineWidth: 1)
        )
    }

    private func color(_ index: Int) -> Color {
        switch index {
        case 0: return Color(nsColor: .textBackgroundColor)
        case 1: return DesignTokens.TextStyle.primary
        default: return DesignTokens.Accent.nav
        }
    }

    private func swatchColor(_ hex: String) -> Color {
        if let color = NSColor(rgbHex: hex) {
            return Color(nsColor: color)
        }
        return DesignTokens.Surface.overlay
    }
}

private extension NSColor {
    /// Parses theme swatch hex values (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`).
    convenience init?(rgbHex hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()

        let channels: [CGFloat]
        switch value.count {
        case 3, 4:
            channels = value.compactMap { character in
                guard let nibble = UInt(String(character), radix: 16) else { return nil }
                return CGFloat(nibble) / 15.0
            }
        case 6, 8:
            var bytes: [CGFloat] = []
            var index = value.startIndex
            while index < value.endIndex {
                let next = value.index(index, offsetBy: 2)
                guard let byte = UInt(value[index..<next], radix: 16) else { return nil }
                bytes.append(CGFloat(byte) / 255.0)
                index = next
            }
            channels = bytes
        default:
            return nil
        }

        guard channels.count == 3 || channels.count == 4 else { return nil }
        let alpha = channels.count == 4 ? channels[3] : 1.0
        self.init(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
    }
}
