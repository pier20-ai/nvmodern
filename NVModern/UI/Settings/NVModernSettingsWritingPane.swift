import SwiftUI

struct WritingPane: View {
    @ObservedObject var model: NVModernSettingsModel
    @Binding var draft: NVModernConfigDraft
    @State private var newPerson = ""

    var body: some View {
        SettingsForm {
            Section {
                if draft.substitutions.isEmpty {
                    Text("No replacements").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Text("Replace").frame(width: 120, alignment: .leading)
                        Text("With")
                        Spacer()
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                ForEach($draft.substitutions, id: \._uiID) { $row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        CommitTextField("Replace", text: $row.from, prompt: ";sig")
                            .labelsHidden()
                            .font(.body.monospaced())
                            .frame(width: 120)
                        CommitTextField("With", text: $row.to, prompt: "Replacement text", axis: .vertical)
                            .labelsHidden()
                            .lineLimit(1...6)
                        RemoveRowButton(help: "Remove replacement") { model.removeSubstitution(row._uiID) }
                    }
                }
            } header: {
                Text("Text Replacements")
            } footer: {
                HStack(alignment: .top) {
                    Text("Typing a trigger in the editor replaces it with its text. Press Option-Return for a line break.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Replacement") { draft.substitutions.append(.init()) }
                }
            }

            Section {
                ForEach(Array(draft.users.enumerated()), id: \.offset) { index, _ in
                    HStack {
                        CommitTextField("Name", text: userBinding(index), prompt: "Name").labelsHidden()
                        RemoveRowButton(help: "Remove person") { draft.users.remove(at: index) }
                    }
                }
                TextField("Add person", text: $newPerson, prompt: Text("Add a name…"))
                    .labelsHidden()
                    .onSubmit {
                        let name = newPerson.trimmingCharacters(in: .whitespacesAndNewlines)
                        newPerson = ""
                        if !name.isEmpty, !draft.users.contains(name) { draft.users.append(name) }
                    }
            } header: {
                Text("People")
            } footer: {
                Text("Offered when you type @ in a document.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Clearing a name removes the row, so the list never saves blanks.
    private func userBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.users.indices.contains(index) ? draft.users[index] : "" },
            set: { value in
                guard draft.users.indices.contains(index) else { return }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { draft.users.remove(at: index) } else { draft.users[index] = trimmed }
            }
        )
    }
}

struct RemoveRowButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
