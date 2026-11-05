import AppKit
import SwiftUI

struct AppearancePane: View {
    @Binding var draft: NVModernConfigDraft

    /// Bumped to re-scan the themes directory after it may have changed on disk.
    @State private var themesRefreshToken = UUID()

    var body: some View {
        SettingsForm {
            Section {
                Picker(selection: editorThemeBinding) {
                    Text("System").tag("")
                    ForEach(themeChoices(including: draft.editor_theme)) { theme in
                        Label {
                            Text(theme.title)
                        } icon: {
                            Image(nsImage: swatchImage(theme.swatchHexes))
                        }
                        .tag(theme.id)
                    }
                } label: {
                    SettingsLabel("Theme", summary: "Applies to every document. A document can pick its own in the Document Inspector.")
                }
                .accessibilityLabel("Editor theme")
                Toggle(isOn: windowTintBinding) {
                    SettingsLabel("Tint window", summary: "The toolbar and tab bar take the colour of the document's page.")
                }
                .accessibilityLabel("Tint window with the document's colour")
                PathPickerRow(title: "Custom CSS", summary: "Applied on top of the theme.", prompt: "None", kind: .file, path: $draft.editor_theme_css)
                PathPickerRow(title: "Themes folder", summary: "Each .css file here is a theme. Edits apply as you save.",
                              prompt: "~/.config/nvmodern/themes", kind: .directory, path: $draft.themes_dir)
                HStack {
                    Spacer()
                    Button("Open Themes Folder") { openThemesFolder() }
                }
            } header: {
                Text("Editor")
            }

            Section {
                Picker(selection: enumBinding($draft.width, defaultValue: "comfortable")) {
                    ForEach(NVModernConfigSchema.documentWidthOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                } label: {
                    SettingsLabel("Text width", summary: "Used for documents that don't set their own.")
                }
            } header: {
                Text("Documents")
            }

            filetypeSection("org", name: "Org")
            filetypeSection("md", name: "Markdown")
        }
    }

    /// `[filetypes.<ext>]`: a theme and a font for one file type. A document's
    /// own theme or frontmatter still wins over these.
    private func filetypeSection(_ ext: String, name: String) -> some View {
        Section {
            Picker(selection: filetypeThemeBinding(ext)) {
                Text("Editor theme").tag("")
                Text("System").tag(UserEditorThemeCatalog.reservedThemeID)
                ForEach(themeChoices(including: draft.filetypes[ext]?.theme)) { theme in
                    Label {
                        Text(theme.title)
                    } icon: {
                        Image(nsImage: swatchImage(theme.swatchHexes))
                    }
                    .tag(theme.id)
                }
            } label: {
                SettingsLabel("Theme", summary: "Replaces the editor theme for .\(ext) files.")
            }
            .accessibilityLabel("\(name) theme")
            LabeledContent {
                FontFamilyPicker(
                    family: filetypeFontBinding(ext),
                    defaultFamily: Self.themeFontLabel,
                    accessibilityLabel: "\(name) font"
                )
                .frame(width: 220)
            } label: {
                SettingsLabel("Font", summary: "Replaces the theme's text face in .\(ext) files, at the theme's size.")
            }
        } header: {
            Text("\(name) Files")
        }
    }

    private func enumBinding(_ source: Binding<String?>, defaultValue: String) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? defaultValue },
            set: { source.wrappedValue = $0 }
        )
    }

    private var resolvedThemesDirectory: URL {
        UserEditorThemeCatalog.resolvedDirectoryURL(
            from: draft.themes_dir,
            configURL: NVModernConfigSchema.defaultConfigURL()
        )
    }

    private var editorThemeBinding: Binding<String> {
        Binding(
            get: { draft.editor_theme ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.editor_theme = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    /// Every theme except System (rendered as the picker's own item), plus a
    /// placeholder when `selection` is missing from disk so it stays visible
    /// and clearable.
    private func themeChoices(including selection: String?) -> [AvailableEditorTheme] {
        _ = themesRefreshToken
        var themes = EditorThemeRegistry.availableThemes(in: resolvedThemesDirectory)
        themes.removeAll { $0.id == UserEditorThemeCatalog.reservedThemeID }

        let selectedID = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !selectedID.isEmpty,
              selectedID != UserEditorThemeCatalog.reservedThemeID,
              !themes.contains(where: { $0.id == selectedID }) else {
            return themes
        }
        return themes + [
            AvailableEditorTheme(
                id: selectedID,
                title: "\(UserEditorThemeCatalog.displayTitle(for: selectedID)) (missing)",
                subtitle: nil,
                swatchHexes: [],
                isBundled: false,
                fileURL: nil
            )
        ]
    }

    private func openThemesFolder() {
        let directory = resolvedThemesDirectory
        UserEditorThemeCatalog.installTemplateIfNeeded(in: directory)
        UserEditorThemeCatalog.revealDirectory(directory)
        themesRefreshToken = UUID()
    }

    /// Menu items only render images, not arbitrary views, so the swatch dot is
    /// drawn into an `NSImage`.
    private func swatchImage(_ hexes: [String]) -> NSImage {
        let color = hexes.first.flatMap(NSColor.init(rgbHex:)) ?? .tertiaryLabelColor
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    private var windowTintBinding: Binding<Bool> {
        Binding(
            get: { draft.window_tint ?? true },
            set: { draft.window_tint = $0 ? nil : false }
        )
    }

    /// Shown, and pinned first, in a file type's font picker; choosing it
    /// clears the override so the theme's own faces apply.
    private static let themeFontLabel = "Theme Font"

    private func filetypeThemeBinding(_ ext: String) -> Binding<String> {
        Binding(
            get: { draft.filetypes[ext]?.theme ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.filetypes[ext, default: .init()].theme = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private func filetypeFontBinding(_ ext: String) -> Binding<String> {
        Binding(
            get: { draft.filetypes[ext]?.font_family ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let isThemeFont = trimmed.isEmpty || trimmed == Self.themeFontLabel
                draft.filetypes[ext, default: .init()].font_family = isThemeFont ? nil : trimmed
            }
        )
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
