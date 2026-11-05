import AppKit
import SwiftUI

/// A font-family picker bound to a family name. The button shows the current
/// family in its own face; the popover lists every installed family with a
/// search field, each rendered in itself so the choice can be made by eye.
struct FontFamilyPicker: View {
    @Binding var family: String
    /// Family used when the binding is empty, and pinned to the top of the list.
    var defaultFamily: String
    var accessibilityLabel: String = "Font family"

    @State private var isPresented = false

    private var displayFamily: String {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultFamily : trimmed
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(displayFamily)
                    .font(.custom(displayFamily, size: NSFont.systemFontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FontFamilyPickerPopover(
                family: $family,
                defaultFamily: defaultFamily,
                isPresented: $isPresented
            )
            .frame(width: 320, height: 360)
        }
    }
}

private struct FontFamilyPickerPopover: View {
    @Binding var family: String
    let defaultFamily: String
    @Binding var isPresented: Bool

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var families: [String] {
        InstalledFontCatalog.families(pinning: defaultFamily, including: family)
    }

    private var filteredFamilies: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return families }
        return families.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var selectedFamily: String {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultFamily : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search fonts…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit(selectFirstMatch)
                .padding(10)

            Divider()

            ScrollViewReader { proxy in
                List(filteredFamilies, id: \.self, selection: selectionBinding) { name in
                    row(name)
                        .id(name)
                }
                .listStyle(.plain)
                .onAppear {
                    isSearchFocused = true
                    proxy.scrollTo(selectedFamily, anchor: .center)
                }
            }

            if filteredFamilies.isEmpty {
                Text("No installed fonts match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selectedFamily },
            set: { newValue in
                guard let newValue else { return }
                choose(newValue)
            }
        )
    }

    private func row(_ name: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.custom(name, size: NSFont.systemFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if InstalledFontCatalog.isFixedPitch(name) {
                Text("mono")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if name == defaultFamily {
                Text("default")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(name) }
    }

    private func selectFirstMatch() {
        guard let first = filteredFamilies.first else { return }
        choose(first)
    }

    private func choose(_ name: String) {
        family = name
        isPresented = false
    }
}

/// Every installed font family, computed once. Org text used to be limited to
/// fixed-pitch faces; that exclusion is gone, so the catalog only filters
/// hidden system families.
@MainActor
enum InstalledFontCatalog {
    static let installedFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    private static let fixedPitchFamilies: Set<String> = {
        let fontManager = NSFontManager.shared
        return Set(installedFamilies.filter { family in
            fontManager.font(withFamily: family, traits: [], weight: 5, size: NSFont.systemFontSize)?
                .isFixedPitch ?? false
        })
    }()

    static func isFixedPitch(_ family: String) -> Bool {
        fixedPitchFamilies.contains(family)
    }

    /// Installed families with `pinned` first, plus the configured family even
    /// when it is not installed so the current setting stays visible.
    static func families(pinning pinned: String, including configured: String?) -> [String] {
        var families = Set(installedFamilies)
        families.insert(pinned)
        if let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            families.insert(configured)
        }
        let remainder = families
            .filter { $0 != pinned }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [pinned] + remainder
    }
}
