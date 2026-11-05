import AppKit
import Foundation

/// Owns the frame stack, the modes, the resolver, and the in-flight resolve
/// task.
///
/// `WorkspaceTabView` keeps one of these for the lifetime of the tab and only
/// handles what needs the tab: activations, document preview, and presentation.
@MainActor
final class PaletteSession: ObservableObject {
    let stack: PaletteStack
    let resolver: PaletteResultsResolver

    /// Modes are layered over the session, not over the stack: they survive
    /// pushing and popping frames and are cleared by Escape.
    @Published private(set) var modes: Set<PaletteMode> = []
    /// Multi-select marks, keyed by item id so a re-resolve keeps them.
    @Published private(set) var marked: [String: PaletteTarget] = [:]
    /// What the results area says when a frame has no items.
    @Published private(set) var emptyMessage = ""
    /// Title of the tab's document at the last resolve, for the header when a
    /// sentence started from a preset (`⌘R`) rather than from a chosen row.
    @Published private(set) var currentDocumentTitle: String?
    /// Bumped every time a resolve lands, and reset when the palette opens on a
    /// preset. `PaletteFrameView` holds its reveal until the first one, so the
    /// palette is never shown at its empty height and then resized.
    @Published private(set) var resolveGeneration = 0

    /// The preset the palette was opened on; drives the input's shortcut label.
    private(set) var preset: PalettePreset = .root

    /// Built fresh on every resolve so the palette always sees current
    /// workspace state. Set by the tab when it presents the palette.
    var makeContext: (() -> PaletteContext)?
    /// Selection changes, for document preview.
    var onSelectionChanged: ((PaletteItem?) -> Void)?
    /// Everything except `.push`, which the session handles.
    var onActivation: ((PaletteItem, PaletteActivation, Bool, PaletteFrameSpec) -> Void)?
    /// A batch run: the same action once per marked noun, awaited in order.
    var onBatchActivation: ((PaletteItem, [PaletteActivation], PaletteFrameSpec) -> Void)?
    /// Escape with nothing left to pop.
    var onClose: (() -> Void)?
    /// Lets the document runtime start/end reversible navigation on preset swaps.
    var onFrameChanged: ((PaletteFrameSpec) -> Void)?

    private var resolveTask: Task<Void, Never>?
    private var lastSelectedItemID: String?
    private var hoverSelectionGate = PaletteHoverSelectionGate()
    private(set) var shouldPreviewOutlineSelection = false

    var isPreviewModeActive: Bool { modes.contains(.preview) }
    var isMultiSelectModeActive: Bool { modes.contains(.multiSelect) }
    var isPinModeActive: Bool { modes.contains(.pin) }

    init(resolver: PaletteResultsResolver? = nil) {
        self.stack = PaletteStack(root: .root)
        self.resolver = resolver ?? PaletteResultsResolver()
    }

    // MARK: Presentation lifecycle

    /// Resets the stack onto a preset and kicks the first resolve.
    func open(preset: PalettePreset, carryingQuery carriedQuery: String? = nil) {
        // Swapping a plugin's picker for another preset abandons it.
        if case .pluginPick(let previous) = self.preset, self.preset != preset {
            PluginPickCenter.shared.cancel(previous.requestID)
        }
        if case .pluginPick(let pick) = preset {
            PluginPickCenter.shared.markPresented(pick.requestID)
        }
        self.preset = preset
        var frames = PalettePresetResolver.frames(for: preset)
        if let carriedQuery, preset.preservesQueryOnSwap, var top = frames.last {
            // The presets that carry a query are now root plus a prefix, so the
            // carried text lands after the new prefix rather than replacing it.
            let carriedText = PaletteQueryScope.parse(carriedQuery).text
            if !carriedText.isEmpty {
                top.initialQuery = PaletteQueryScope.parse(top.initialQuery).prefix + carriedText
                frames[frames.count - 1] = top
            }
        }
        if case .documentVerbs = preset,
           let path = makeContext?().currentDocumentRelativePath {
            frames.append(.verbs(for: .workspaceNote(relativePath: path)))
        }
        stack.reset(to: frames)
        onFrameChanged?(stack.top.spec)
        modes.remove(.preview)
        modes.remove(.multiSelect)
        if preset == .outline { modes.removeAll() }
        marked.removeAll()
        lastSelectedItemID = nil
        shouldPreviewOutlineSelection = false
        // Opening the palette can place a row underneath a stationary cursor.
        // Treat that initial layout exactly like a query-driven relayout: the
        // pointer must leave its dead zone before hover can change selection.
        hoverSelectionGate.suppress(at: NSEvent.mouseLocation)
        emptyMessage = ""
        resolveGeneration = 0
        paletteDebugLog("session.open preset=\(preset.debugLabel) depth=\(stack.depth)")
        resolve(immediate: true)
    }

    /// Called by the tab once the palette host has torn the surface down.
    func handleDidClose() {
        // A no-op when a row already answered the picker.
        if case .pluginPick(let pick) = preset {
            PluginPickCenter.shared.cancel(pick.requestID)
        }
        resolveTask?.cancel()
        resolveTask = nil
        modes.removeAll()
        marked.removeAll()
        lastSelectedItemID = nil
        hoverSelectionGate.reset()
    }

    // MARK: Query and navigation

    func setQuery(_ query: String) {
        guard stack.query != query else { return }
        shouldPreviewOutlineSelection = true
        stack.query = query
        // Typing always abandons mouse or keyboard selection. Reset once
        // against the visible rows, then force the newly filtered result set
        // to begin at its first row too. Layout can synthesize hover events
        // under a stationary pointer, so hover stays gated until the cursor
        // deliberately leaves its current dead zone.
        hoverSelectionGate.suppress(at: NSEvent.mouseLocation)
        stack.selectFirstItem()
        if stack.top.spec.sources != [.outline] { notifySelectionChanged() }
        resolve(immediate: false, resetSelection: true)
    }

    func push(_ frame: PaletteFrameSpec) {
        stack.push(frame)
        onFrameChanged?(stack.top.spec)
        lastSelectedItemID = nil
        paletteDebugLog("session.push frame=\(frame.id) depth=\(stack.depth)")
        resolve(immediate: true)
    }

    @discardableResult
    func pop() -> Bool {
        guard stack.pop() else { return false }
        onFrameChanged?(stack.top.spec)
        lastSelectedItemID = nil
        paletteDebugLog("session.pop depth=\(stack.depth)")
        resolve(immediate: true)
        notifySelectionChanged()
        return true
    }

    /// Escape: clear modes, else pop a frame, else close.
    func handleEscape() {
        if !modes.isEmpty {
            modes.removeAll()
            marked.removeAll()
            notifySelectionChanged(force: true)
            return
        }
        if pop() { return }
        onClose?()
    }

    /// `Cmd+Shift+K` / `Cmd+Shift+F` / `Cmd+N` / `Cmd+R` while the palette is
    /// already open: reset onto that preset, carrying the typed text.
    func applyPresetShortcut(_ requested: PalettePreset) {
        if case .root = requested, stack.top.spec.isRoot, !stack.canPop {
            return
        }
        var preset = requested
        let currentQuery = stack.query
        if case .contentSearch = requested {
            preset = .contentSearch(initialQuery: PaletteQueryScope.parse(currentQuery).text)
        }
        open(preset: preset, carryingQuery: currentQuery)
    }

    // MARK: Modes

    func toggleMode(_ mode: PaletteMode) {
        guard stack.top.spec.sources != [.outline] else { return }
        if modes.contains(mode) {
            modes.remove(mode)
            if mode == .multiSelect { marked.removeAll() }
        } else {
            modes.insert(mode)
        }
        paletteDebugLog("session.mode \(mode.rawValue) modes=\(modes.map(\.rawValue).sorted().joined(separator: ","))")
        notifySelectionChanged(force: true)
    }

    /// Space in multi-select. Only nouns that denote a note can be marked.
    @discardableResult
    func toggleMarkOnSelection() -> Bool {
        guard isMultiSelectModeActive,
              let item = stack.top.selectedItem,
              let target = item.target,
              target.noteRelativePath != nil else {
            return false
        }
        if marked.removeValue(forKey: item.id) == nil {
            marked[item.id] = target
        }
        return true
    }

    /// The marked nouns as one subject: a single mark binds itself.
    private var markedSubject: PaletteTarget? {
        let targets = marked
            .sorted { $0.key < $1.key }
            .map(\.value)
        guard !targets.isEmpty else { return nil }
        return targets.count == 1 ? targets[0] : .batch(targets)
    }

    // MARK: Stepping

    /// Tab (and `Cmd+K` inside the palette): commit this slot and move to the
    /// next one. A noun becomes the bound subject; a verb with an object opens
    /// its object frame; anything else is a no-op.
    @discardableResult
    func stepIntoSelection() -> Bool {
        if let subject = markedSubject {
            modes.remove(.multiSelect)
            marked.removeAll()
            push(.verbs(for: subject))
            return true
        }
        guard let item = stack.top.selectedItem else { return false }
        if case .push(let frame) = item.activation {
            push(frame)
            return true
        }
        // Nouns get a verbs frame, but only from root: an argument frame is
        // already collecting something, and diverting it would lose the pending
        // command.
        guard stack.top.spec.isRoot,
              let target = item.target,
              target.nounKind != nil else {
            return false
        }
        push(.verbs(for: target))
        return true
    }

    // MARK: Selection

    func select(itemID: String) {
        guard stack.selectedItemID != itemID else { return }
        shouldPreviewOutlineSelection = true
        stack.selectedItemID = itemID
        notifySelectionChanged()
    }

    func selectFromHover(itemID: String) {
        guard hoverSelectionGate.allowsSelection(at: NSEvent.mouseLocation) else { return }
        select(itemID: itemID)
    }

    func moveSelection(by delta: Int) {
        shouldPreviewOutlineSelection = true
        stack.moveSelection(by: delta)
        notifySelectionChanged()
    }

    // MARK: Activation

    func activateSelection(openInNewTab: Bool) {
        if markedSubject != nil {
            stepIntoSelection()
            return
        }
        guard let item = stack.top.selectedItem else {
            paletteDebugLog("session.activate noSelection frame=\(stack.top.spec.id)")
            return
        }
        activate(item, openInNewTab: openInNewTab)
    }

    /// Shift-Return on a note row: push the note to the tab's side stack
    /// (ticket 0031) instead of opening it. False for any other row.
    @discardableResult
    func activateSelectionInSideStack() -> Bool {
        guard markedSubject == nil,
              let item = stack.top.selectedItem,
              let activation = PaletteActivation.sideStackPush(for: item.activation) else {
            return false
        }
        paletteDebugLog("session.activate sideStack id=\(item.id) frame=\(stack.top.spec.id)")
        onActivation?(item, activation, false, stack.top.spec)
        return true
    }

    func activate(_ item: PaletteItem, openInNewTab: Bool) {
        paletteDebugLog("session.activate id=\(item.id) newTab=\(openInNewTab) frame=\(stack.top.spec.id)")
        switch item.activation {
        case .push(let frame):
            push(frame)
        case .runAction(let method, let args, let target):
            PaletteRecentVerbsStore.shared.record(method)
            // A batch survives into the object frame: refiling three notes
            // still has to pick one folder before anything runs.
            let subject = stack.top.spec.boundTarget ?? stack.top.spec.subjectTarget
            if case .batch(let members)? = subject {
                runBatch(item, method: method, args: args, target: target, members: members)
                return
            }
            onActivation?(item, item.activation, openInNewTab, stack.top.spec)
        default:
            onActivation?(item, item.activation, openInNewTab, stack.top.spec)
        }
    }

    /// One run per marked noun, with that noun's own bound arguments.
    private func runBatch(
        _ item: PaletteItem,
        method: String,
        args: [String: ActionValue],
        target: ActionTarget,
        members: [PaletteTarget]
    ) {
        guard let descriptor = ActionRegistry.shared.descriptor(for: method) else {
            paletteDebugLog("session.batch missingDescriptor method=\(method)")
            NSSound.beep()
            return
        }
        let activations: [PaletteActivation] = members.compactMap { member in
            guard let bound = PaletteActionPlanner.boundArgs(for: descriptor, target: member) else {
                return nil
            }
            var merged = args
            merged.merge(bound) { _, new in new }
            return .runAction(method: method, args: merged, target: target)
        }
        guard !activations.isEmpty else {
            paletteDebugLog("session.batch noApplicableMembers method=\(method)")
            NSSound.beep()
            return
        }
        paletteDebugLog("session.batch method=\(method) runs=\(activations.count)")
        onBatchActivation?(item, activations, stack.top.spec)
    }

    /// Pin mode: after a run the palette stays open, back at root.
    func handleDidRun() {
        marked.removeAll()
        stack.reset(to: [.root])
        onFrameChanged?(stack.top.spec)
        modes.remove(.multiSelect)
        lastSelectedItemID = nil
        emptyMessage = ""
        paletteDebugLog("session.pinnedReset")
        resolve(immediate: true)
    }

    // MARK: Resolve

    func resolve(immediate: Bool, resetSelection: Bool = false) {
        resolveTask?.cancel()
        guard let makeContext else {
            stack.setSections([])
            return
        }

        let frame = stack.top.spec
        let rawQuery = stack.top.query
        let delay = immediate ? 0 : resolver.debounceNanoseconds(for: frame, rawQuery: rawQuery)

        resolveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            // Built here, inside the resolve task, because the action variables
            // reach workspace state and must never run during a render pass.
            let context = makeContext()
            self.currentDocumentTitle = context.currentDocumentTitle
            let sections = await self.resolver.sections(
                frame: frame,
                rawQuery: rawQuery,
                context: context
            )
            guard !Task.isCancelled,
                  self.stack.top.spec.id == frame.id,
                  self.stack.top.query == rawQuery else {
                return
            }

            self.emptyMessage = self.makeEmptyMessage(frame: frame, rawQuery: rawQuery, context: context)
            self.stack.setSections(sections, preservingSelection: !resetSelection)
            if frame.sources == [.outline], rawQuery.isEmpty,
               !self.shouldPreviewOutlineSelection, let activeID = context.activeOutlineItemID,
               self.stack.top.items.contains(where: { $0.id == activeID }) {
                self.stack.selectedItemID = activeID
            }
            self.resolveGeneration &+= 1
            paletteDebugLog("session.resolved frame=\(frame.id) query=\(rawQuery.debugDescription) sections=\(sections.count) items=\(sections.reduce(0) { $0 + $1.items.count })")
            self.notifySelectionChanged()
        }
    }

    private func notifySelectionChanged(force: Bool = false) {
        let item = stack.top.selectedItem
        guard force || item?.id != lastSelectedItemID else { return }
        lastSelectedItemID = item?.id
        onSelectionChanged?(item)
    }

    // MARK: Empty state

    private func makeEmptyMessage(
        frame: PaletteFrameSpec,
        rawQuery: String,
        context: PaletteContext
    ) -> String {
        let scope = PaletteQueryScope.parse(rawQuery)
        let quoted = "\u{201C}\(scope.text)\u{201D}"

        if frame.sources == [.outline] {
            return rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No headings in this document."
                : "No headings match \u{201C}\(rawQuery)\u{201D}."
        }

        if let boundTarget = frame.boundTarget {
            return "No verbs for \(boundTarget.breadcrumbLabel)."
        }

        if let pending = frame.pendingCommand {
            switch pending.argumentPicker {
            case .text:
                return frame.placeholder
            case .workspaceFolder:
                if pending.method == "workspace.note.refile",
                   pending.args["path"] == nil,
                   frame.subjectTarget == nil,
                   context.currentDocumentRelativePath == nil {
                    return "Open a workspace note before refiling."
                }
                return scope.text.isEmpty ? "No folders in this workspace." : "No folders for \(quoted)."
            case .documentWidth:
                return "No page widths for \(quoted)."
            case .editorTheme:
                return scope.text.isEmpty ? "No editor themes found." : "No themes for \(quoted)."
            }
        }

        switch scope.scope {
        case .passages:
            if scope.text.count < PaletteResultsResolver.passagesMinimumQueryLength {
                return "Type to search across all note contents…"
            }
            if resolver.passagesProvider.lastResponseWasRebuilding {
                if let indexed = resolver.passagesProvider.lastRebuildIndexedCount,
                   let total = resolver.passagesProvider.lastRebuildTotalCount,
                   total > 0 {
                    let formatter = NumberFormatter()
                    formatter.numberStyle = .decimal
                    let indexedLabel = formatter.string(from: NSNumber(value: indexed)) ?? "\(indexed)"
                    let totalLabel = formatter.string(from: NSNumber(value: total)) ?? "\(total)"
                    return "Indexing \(indexedLabel) of \(totalLabel) notes\u{2026}"
                }
                return "The search index is still building. Try again in a moment."
            }
            return "No matches for \(quoted)."
        case .folders:
            return scope.text.isEmpty ? "No folders in this workspace." : "No folders for \(quoted)."
        case .actions:
            return scope.text.isEmpty ? "No verbs available." : "No verbs for \(quoted)."
        case .all:
            return scope.text.isEmpty
                ? "Start typing to find a note…"
                : "No matches for \(quoted)."
        }
    }
}
