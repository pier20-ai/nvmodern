import AppKit
import SwiftUI

struct DocumentFindBarView: View {
    @Binding var query: String
    let matchCount: Int
    let activeMatchIndex: Int?
    let focusRequestID: Int
    let onQueryChange: (String) -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.space2) {
            searchField
                .frame(maxWidth: 360)

            Text(matchSummary)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.TextStyle.secondary)
                .frame(minWidth: 62, alignment: .leading)

            Spacer(minLength: DesignTokens.Spacing.space3)

            findBarButton(
                systemName: "chevron.up",
                help: "Previous match (Shift-Return)",
                isEnabled: matchCount > 0,
                action: onPrevious
            )
            findBarButton(
                systemName: "chevron.down",
                help: "Next match (Return)",
                isEnabled: matchCount > 0,
                action: onNext
            )
            findBarButton(
                systemName: "xmark",
                help: "Close Find",
                isEnabled: true,
                action: onClose
            )
        }
        .padding(.leading, DesignTokens.Spacing.space4)
        .padding(.trailing, DesignTokens.Spacing.space2)
        .frame(height: 40)
        .background(.bar)
        .onAppear(perform: focusField)
        .onChange(of: focusRequestID) { _, _ in focusField() }
        .onChange(of: query) { _, newValue in onQueryChange(newValue) }
        .background(
            DocumentFindBarKeyMonitor(
                onNext: onNext,
                onPrevious: onPrevious
            )
            .frame(width: 0, height: 0)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in document")
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.TextStyle.tertiary)

            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .focused($isFieldFocused)
                .onSubmit {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                        onPrevious()
                    } else {
                        onNext()
                    }
                }
                .onExitCommand(perform: onClose)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.TextStyle.tertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.space3)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                .fill(DesignTokens.Surface.overlay)
        )
    }

    private var matchSummary: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard matchCount > 0 else { return "No matches" }
        let displayIndex = min(matchCount, max(1, (activeMatchIndex ?? -1) + 1))
        return "\(displayIndex) of \(matchCount)"
    }

    private func findBarButton(
        systemName: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? DesignTokens.TextStyle.secondary
                        : DesignTokens.TextStyle.tertiary.opacity(0.45)
                )
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.input, style: .continuous)
                        .fill(Color.clear)
                )
        }
        .buttonStyle(.plain)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .disabled(!isEnabled)
        .help(help)
    }

    private func focusField() {
        DispatchQueue.main.async {
            isFieldFocused = true
        }
    }
}

private struct DocumentFindBarKeyMonitor: NSViewRepresentable {
    let onNext: () -> Void
    let onPrevious: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNext: onNext, onPrevious: onPrevious)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.hostWindow = view.window
            context.coordinator.installIfNeeded()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostWindow = nsView.window
        context.coordinator.onNext = onNext
        context.coordinator.onPrevious = onPrevious
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var hostWindow: NSWindow?
        var onNext: () -> Void
        var onPrevious: () -> Void
        private var monitor: Any?

        init(onNext: @escaping () -> Void, onPrevious: @escaping () -> Void) {
            self.onNext = onNext
            self.onPrevious = onPrevious
        }

        deinit {
            removeMonitor()
        }

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.window === hostWindow,
                      event.charactersIgnoringModifiers?.lowercased() == "g" else {
                    return event
                }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == [.command] {
                    onNext()
                    return nil
                }
                if flags == [.command, .shift] {
                    onPrevious()
                    return nil
                }
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
