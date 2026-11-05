import AppKit
import SwiftUI

/// A workspace-icon picker bound to an `SF Symbol` name string. Shows a curated
/// grid (the common case) plus a search field and a "Custom name" escape hatch
/// (validated against NSImage symbol lookup).
struct SFSymbolPicker: View {
    @Binding var symbol: String?
    /// Symbol shown when nothing is selected; also used as the default fallback.
    var placeholderSymbol: String = "books.vertical.fill"

    @State private var isPresented: Bool = false

    var body: some View {
        Button(action: { isPresented = true }) {
            HStack(spacing: 6) {
                Image(systemName: symbol ?? placeholderSymbol)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(symbol == nil ? Color.secondary : Color.primary)
                Text(symbol ?? "Choose symbol…")
                    .foregroundStyle(symbol == nil ? Color.secondary : Color.primary)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .popover(isPresented: $isPresented) {
            SFSymbolPickerPopover(symbol: $symbol, isPresented: $isPresented)
                .frame(width: 380, height: 380)
        }
    }
}

private struct SFSymbolPickerPopover: View {
    @Binding var symbol: String?
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var customName: String = ""

    /// Curated set of SF Symbols suitable for workspace/folder icons.
    static let curated: [String] = [
        // Containers
        "folder.fill", "folder.badge.gearshape", "tray.full.fill", "archivebox.fill",
        "books.vertical.fill", "book.closed.fill", "text.book.closed.fill", "character.book.closed.fill",
        "note.text", "doc.text.fill", "doc.richtext.fill", "doc.on.doc.fill",
        // Spaces
        "house.fill", "building.2.fill", "building.columns.fill", "globe",
        "mappin.circle.fill", "map.fill", "location.fill", "network",
        // Roles
        "briefcase.fill", "graduationcap.fill", "stethoscope", "person.2.fill",
        "person.crop.circle.fill", "hammer.fill", "wrench.adjustable.fill", "paintbrush.fill",
        // Personal
        "heart.fill", "star.fill", "bookmark.fill", "flag.fill",
        "tag.fill", "sparkles", "leaf.fill", "lightbulb.fill",
        // Time/data
        "calendar", "clock.fill", "alarm.fill", "timer",
        // Misc
        "paperplane.fill", "magazine.fill", "newspaper.fill", "music.note",
        "camera.fill", "photo.fill", "gamecontroller.fill", "puzzlepiece.fill",
        // Abstract
        "square.grid.3x3.fill", "circle.grid.3x3.fill", "square.stack.fill", "rectangle.stack.fill"
    ]

    private var filteredSymbols: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return Self.curated }
        return Self.curated.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var isCustomValid: Bool {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search symbols…", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(38), spacing: 4), count: 8),
                    spacing: 4
                ) {
                    ForEach(filteredSymbols, id: \.self) { name in
                        symbolCell(name)
                    }
                    if filteredSymbols.isEmpty {
                        Text("No matches in curated list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 200)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom symbol")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("e.g. heart.text.square.fill", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyCustom)
                    Button("Use") { applyCustom() }
                        .controlSize(.small)
                        .disabled(!isCustomValid)
                }
                if !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCustomValid {
                    Label("Unknown SF Symbol name.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                if symbol != nil {
                    Button("Clear") {
                        symbol = nil
                        isPresented = false
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Done") { isPresented = false }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func symbolCell(_ name: String) -> some View {
        Button {
            symbol = name
            isPresented = false
        } label: {
            Image(systemName: name)
                .font(.system(size: 18))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(name == symbol ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(name == symbol ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private func applyCustom() {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) != nil
        else { return }
        symbol = trimmed
        customName = ""
        isPresented = false
    }
}
