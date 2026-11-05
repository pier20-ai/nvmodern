import AppKit
import SwiftUI

/// The pane body shared by every Settings tab: a grouped `Form`, the same
/// container System Settings uses, so toggles render as switches, pickers
/// right-align, and sections get the inset rounded background for free.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.visible)
    }
}

/// Title plus secondary explanation, used as a form row label.
struct SettingsLabel: View {
    let title: String
    var summary: String?
    var systemImage: String?

    init(_ title: String, summary: String? = nil, systemImage: String? = nil) {
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
    }

    var body: some View {
        let text = VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let summary, !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let systemImage {
            Label { text } icon: { Image(systemName: systemImage) }
        } else {
            text
        }
    }
}

/// A text field that writes back on Return or focus loss instead of on every
/// keystroke. Settings writes `config.toml` immediately, and some keys (socket
/// path, CLI paths) restart runtime services, so per-character writes are wrong.
struct CommitTextField: View {
    let title: String
    var prompt: String?
    var axis: Axis = .horizontal
    @Binding var text: String
    @State private var buffer = ""
    @FocusState private var focused: Bool

    init(_ title: String, text: Binding<String>, prompt: String? = nil, axis: Axis = .horizontal) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.axis = axis
    }

    var body: some View {
        TextField(title, text: $buffer, prompt: prompt.map { Text($0) }, axis: axis)
            .focused($focused)
            .onAppear { buffer = text }
            .onChange(of: text) { _, value in if !focused { buffer = value } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
            .onDisappear(perform: commit)
    }

    private func commit() { if buffer != text { text = buffer } }
}

extension Binding where Value == String? {
    /// Maps nil to "" for text fields and writes "" (after trimming) back as nil.
    var orEmpty: Binding<String> {
        Binding<String>(
            get: { wrappedValue ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                wrappedValue = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    func or(_ defaultValue: String) -> Binding<String> {
        Binding<String>(get: { wrappedValue ?? defaultValue }, set: { wrappedValue = $0 })
    }
}

/// Path row: editable path with a "Choose…" button that opens an `NSOpenPanel`.
struct PathPickerRow: View {
    let title: String
    var summary: String?
    var prompt: String?
    let kind: NVModernConfigPathKind
    @Binding var path: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                CommitTextField(title, text: $path.orEmpty, prompt: prompt)
                    .labelsHidden()
                    .frame(minWidth: 180)
                Button("Choose…", action: choose)
            }
        } label: {
            SettingsLabel(title, summary: summary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == .directory
        panel.canChooseFiles = kind != .directory
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// Bottom-of-pane notice used for Undo after destructive edits.
struct SettingsUndoBar: View {
    let message: String
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
            Text(message).lineLimit(2)
            Spacer()
            Button("Undo", action: undo).keyboardShortcut("z", modifiers: .command)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension String {
    /// `daily-capture` / `daily_capture` → `Daily Capture`.
    var settingsDisplayName: String {
        replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }
}
