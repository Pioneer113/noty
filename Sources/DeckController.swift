import AppKit
import SwiftUI
import Combine

// MARK: - Deck state

enum DeckState: Equatable {
    case rest
    case fan
    case expanded(String)

    var rank: Int {
        switch self {
        case .rest: return 0
        case .fan: return 1
        case .expanded: return 2
        }
    }
    var expandedID: String? {
        if case .expanded(let id) = self { return id }
        return nil
    }
}

final class DeckModel: ObservableObject {
    @Published var state: DeckState = .rest
    @Published var showAll = false          // "+N more" opened into a scrolling list
    @Published var findQuery: String?       // nil = find bar hidden
    @Published var revealTick = 0           // bumped to restage the fan animation

    /// Owns the NSTextView of the open note so ⌘F can drive it.
    let bridge = EditorBridge()

    /// The deck shows tabs in every state except rest.
    var fanVisible: Bool { state != .rest }

    // Mirrored from Settings so SwiftUI re-renders when a preference flips.
    @Published var style: DeckStyle = Settings.deckStyle
    @Published var onLeftEdge: Bool = Settings.deckOnLeftEdge
    @Published var fontSize: Double = Settings.noteFontSize

    func syncPreferences() {
        style = Settings.deckStyle
        onLeftEdge = Settings.deckOnLeftEdge
        fontSize = Settings.noteFontSize
    }
}

// MARK: - Controller

/// One deck per physical display. Keyed by CGDirectDisplayID because NSScreen
/// instances are replaced wholesale on display reconfiguration.
final class DeckController: NSObject {
    let displayID: CGDirectDisplayID
    let model = DeckModel()

    private let panel = DeckPanel()
    private var hosting: DeckHostingView<DeckRootView>!
    private var container: DeckContentView!
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var exitWork: DispatchWorkItem?     // debounced pointer-exit check
    private var shrinkWork: DispatchWorkItem?   // delayed panel shrink after collapse
    private var bag = Set<AnyCancellable>()

    weak var manager: DeckManager?

    var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init()

        container = DeckContentView()
        container.controller = self
        container.autoresizingMask = [.width, .height]

        hosting = DeckHostingView(rootView: DeckRootView(deck: model, controller: self))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)

        panel.contentView = container
        layout()
        panel.orderFrontRegardless()

        // Pill height tracks the note count.
        NoteStore.shared.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.model.state == .rest else { return }
                self.layout()
            }
            .store(in: &bag)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        panel.orderOut(nil)
    }

    // MARK: Layout

    func layout() { layout(for: model.state) }

    func layout(for state: DeckState) {
        guard let screen else { return }
        let full = screen.frame
        let vis = screen.visibleFrame
        let onRight = !Settings.deckOnLeftEdge

        let frame: NSRect
        switch state {
        case .rest:
            let h = DeckGeom.pillHeight(noteCount: max(1, NoteStore.shared.active.count))
            let w = DeckGeom.pillTouchWidth
            frame = NSRect(x: onRight ? full.maxX - w : full.minX,
                           y: vis.midY - h / 2, width: w, height: h)
        case .fan:
            let w = DeckGeom.fanWidth
            frame = NSRect(x: onRight ? full.maxX - w : full.minX,
                           y: vis.minY, width: w, height: vis.height)
        case .expanded:
            let w = DeckGeom.expandedWidth
            frame = NSRect(x: onRight ? full.maxX - w : full.minX,
                           y: vis.minY, width: w, height: vis.height)
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    func refreshLevel() {
        panel.applyLevel()
        panel.orderFrontRegardless()
    }

    // MARK: Transitions

    private func setState(_ new: DeckState) {
        let old = model.state
        guard old != new else { return }
        shrinkWork?.cancel(); shrinkWork = nil
        DeckLog.line("setState \(old) -> \(new)  panel=\(Int(panel.frame.width))x\(Int(panel.frame.height))")

        if new.rank >= old.rank {
            layout(for: new)
            if new == .fan {
                model.state = new
                model.revealTick &+= 1
            } else {
                // One tick later, so SwiftUI animates inside a stable panel size.
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        self.model.state = new
                    }
                }
            }
        } else {
            // Let the exit animation play at full size, then shrink the panel.
            model.state = new
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                DeckLog.line("shrink fires; state=\(self.model.state)")
                self.layout()
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
        }

        if new.expandedID != nil {
            installKeyMonitor(); installOutsideMonitor()
        } else {
            removeKeyMonitor(); removeOutsideMonitor()
        }
        if new == .rest { model.showAll = false; model.findQuery = nil }
    }

    func pointerEntered() {
        exitWork?.cancel(); exitWork = nil
        shrinkWork?.cancel(); shrinkWork = nil
        DeckLog.line("pointerEntered state=\(model.state) panel=\(Int(panel.frame.width))")
        guard model.state == .rest else { layout(); return }
        manager?.deckDidActivate(self)
        setState(.fan)
    }

    func pointerExited() {
        guard model.state == .fan else { return }   // an open note stays open until Esc
        // Tracking areas fire spuriously across a resize, so confirm the pointer really left.
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .fan else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) {
                DeckLog.line("pointerExited confirmed")
                self.setState(.rest)
            }
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func expand(_ id: String) {
        manager?.deckDidActivate(self)
        setState(.expanded(id))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func collapse() {
        let wasExpanded = model.state.expandedID != nil
        setState(.rest)
        if wasExpanded { NSApp.deactivate() }
    }

    func collapseToRest() { setState(.rest) }

    // MARK: Key handling for the expanded note

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let id = self.model.state.expandedID,
                  self.panel.isKeyWindow else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53 {                                  // Esc
                if self.model.findQuery != nil { self.model.findQuery = nil }
                else { self.collapse() }
                return nil
            }
            guard mods == .command else { return event }
            if event.keyCode == 51 {                                  // ⌘⌫
                NoteStore.shared.delete(id: id)
                self.collapse()
                return nil
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case ".":
                NoteStore.shared.cycleColor(id: id)
                return nil
            case "f":
                self.model.findQuery = self.model.findQuery == nil ? "" : nil
                return nil
            case "t":
                self.model.bridge.toggleTaskLine()
                return nil
            default:
                return event
            }
        }
    }

    /// A click in any other app dismisses the open note. Mouse-only global monitors
    /// need no Accessibility permission.
    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.state.expandedID != nil else { return }
            DispatchQueue.main.async { self.collapse() }
        }
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Context menu

    func showContextMenu(at event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Note", action: #selector(AppDelegate.newNote), keyEquivalent: "")
        menu.addItem(withTitle: "All Notes", action: #selector(AppDelegate.openAllNotes), keyEquivalent: "")
        menu.addItem(withTitle: "Archive", action: #selector(AppDelegate.openArchive), keyEquivalent: "")
        menu.addItem(.separator())

        let overFS = NSMenuItem(title: "Show over full-screen apps",
                                action: #selector(AppDelegate.toggleOverFullScreen), keyEquivalent: "")
        overFS.state = Settings.showOverFullScreen ? .on : .off
        menu.addItem(overFS)

        let styleItem = NSMenuItem(title: "Deck style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for s in DeckStyle.allCases {
            let it = NSMenuItem(title: s.title, action: #selector(AppDelegate.setDeckStyle(_:)), keyEquivalent: "")
            it.representedObject = s.rawValue
            it.state = Settings.deckStyle == s ? .on : .off
            styleMenu.addItem(it)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let textItem = NSMenuItem(title: "Text size", action: nil, keyEquivalent: "")
        let textMenu = NSMenu()
        for entry in Settings.fontSizes {
            let it = NSMenuItem(title: entry.name, action: #selector(AppDelegate.setFontSize(_:)),
                                keyEquivalent: "")
            it.representedObject = entry.size
            it.state = abs(Settings.noteFontSize - entry.size) < 0.01 ? .on : .off
            textMenu.addItem(it)
        }
        textItem.submenu = textMenu
        menu.addItem(textItem)

        let leftEdge = NSMenuItem(title: "Dock deck to left edge",
                                  action: #selector(AppDelegate.toggleDeckEdge), keyEquivalent: "")
        leftEdge.state = Settings.deckOnLeftEdge ? .on : .off
        menu.addItem(leftEdge)

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(AppDelegate.toggleLaunchAtLogin), keyEquivalent: "")
        login.state = Settings.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(withTitle: "Markdown (one file per note)…",
                           action: #selector(AppDelegate.exportMarkdown), keyEquivalent: "")
        exportMenu.addItem(withTitle: "Plain text (one file per note)…",
                           action: #selector(AppDelegate.exportPlainText), keyEquivalent: "")
        exportMenu.addItem(withTitle: "Single document…",
                           action: #selector(AppDelegate.exportSingleFile), keyEquivalent: "")
        exportMenu.addItem(withTitle: "Sticky archive (.stickies)…",
                           action: #selector(AppDelegate.exportStickies), keyEquivalent: "")
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)
        menu.addItem(withTitle: "Import…", action: #selector(AppDelegate.importStickies), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Noty", action: #selector(AppDelegate.quit), keyEquivalent: "")

        for item in menu.items where item.action != nil {
            item.target = NSApp.delegate
        }
        NSMenu.popUpContextMenu(menu, with: event, for: container)
    }
}

// MARK: - Manager

/// Keeps one deck alive per display and rebuilds the set when displays change.
final class DeckManager {
    private(set) var decks: [CGDirectDisplayID: DeckController] = [:]

    init() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    func rebuild() {
        let live = Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
        for id in decks.keys where !live.contains(id) { decks.removeValue(forKey: id) }
        for id in live where decks[id] == nil {
            let d = DeckController(displayID: id)
            d.manager = self
            decks[id] = d
        }
        decks.values.forEach { $0.layout() }
    }

    /// Only one deck is open at a time — the one the pointer entered.
    func deckDidActivate(_ active: DeckController) {
        for d in decks.values where d !== active { d.collapseToRest() }
    }

    func refreshAll() {
        decks.values.forEach { $0.model.syncPreferences(); $0.refreshLevel(); $0.layout() }
    }

    /// Deck on the screen holding the pointer, else the main screen's.
    var focused: DeckController? {
        let p = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }),
           let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            return decks[id]
        }
        return decks.values.first
    }
}
