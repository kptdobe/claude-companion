import AppKit

/// Owns the menu bar status item: the (animated) icon and the session list menu.
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength)
    private let monitor: SessionMonitor
    private let titles = TranscriptTitleStore()

    private var spinTimer: Timer?
    private var spinAngle: CGFloat = 0
    private var isSpinning = false

    init(monitor: SessionMonitor = SessionMonitor()) {
        self.monitor = monitor
        super.init()
        statusItem.button?.imagePosition = .imageLeading
        monitor.onChange = { [weak self] sessions in self?.render(sessions) }
        monitor.start()
        render(monitor.sessions)
    }

    // MARK: - Rendering

    private func render(_ sessions: [Session]) {
        updateIcon(sessions)
        rebuildMenu(sessions)
    }

    private func updateIcon(_ sessions: [Session]) {
        let waiting = SessionMerger.waitingCount(sessions)
        let thinking = SessionMerger.anyThinking(sessions)

        if waiting > 0 {
            stopSpin()
            statusItem.button?.image = symbol(
                "exclamationmark.bubble.fill", color: .systemOrange)
            statusItem.button?.title = waiting > 1 ? " \(waiting)" : ""
        } else if thinking {
            statusItem.button?.title = ""
            startSpin()
        } else {
            stopSpin()
            statusItem.button?.title = ""
            statusItem.button?.image = symbol("bubble.left", color: nil)
        }
    }

    private func rebuildMenu(_ sessions: [Session]) {
        let menu = NSMenu()

        let active = SessionMerger.active(sessions)
        let hidden = sessions.count - active.count

        let header = NSMenuItem(
            title: active.isEmpty
                ? "Claude Companion"
                : "Claude — \(active.count) session\(active.count == 1 ? "" : "s")",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if active.isEmpty {
            let empty = NSMenuItem(
                title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for var session in active {
                session.customTitle = titles.title(for: session.id, cwd: session.cwd)
                menu.addItem(sessionItem(session))
            }
        }

        if hidden > 0 {
            menu.addItem(.separator())
            let note = NSMenuItem(
                title: "\(hidden) older session\(hidden == 1 ? "" : "s") hidden (no activity since launch)",
                action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Claude Companion", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func sessionItem(_ session: Session) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(session.title)  ·  \(session.entrypoint.label)",
            action: #selector(jump(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session
        item.image = stateGlyph(session.activity)
        item.toolTip = "\(stateLabel(session.activity)) — \(session.cwd)"
        return item
    }

    // MARK: - Actions

    @objc private func jump(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        WindowActivator.activate(session)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Icon helpers

    private func startSpin() {
        guard !isSpinning else { return }
        isSpinning = true
        spinTimer = Timer.scheduledTimer(
            withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.spinAngle = (self.spinAngle - 24).truncatingRemainder(dividingBy: 360)
            let base = self.symbol("arrow.triangle.2.circlepath", color: nil)
            self.statusItem.button?.image = base.map { self.rotated($0, degrees: self.spinAngle) }
        }
    }

    private func stopSpin() {
        spinTimer?.invalidate()
        spinTimer = nil
        isSpinning = false
    }

    private func symbol(_ name: String, color: NSColor?) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let color {
            config = config.applying(.init(paletteColors: [color]))
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(config)
        image?.isTemplate = (color == nil)
        return image
    }

    private func stateGlyph(_ activity: SessionActivity) -> NSImage? {
        switch activity {
        case .thinking: return symbol("arrow.triangle.2.circlepath", color: .systemBlue)
        case .waiting:  return symbol("exclamationmark.circle.fill", color: .systemOrange)
        case .idle:     return symbol("checkmark.circle.fill", color: .systemGreen)
        case .unknown:  return symbol("circle", color: .systemGray)
        }
    }

    private func stateLabel(_ activity: SessionActivity) -> String {
        switch activity {
        case .thinking: return "Working"
        case .waiting:  return "Waiting for you"
        case .idle:     return "Done"
        case .unknown:  return "Idle"
        }
    }

    /// Render an image rotated about its center (template flag preserved).
    private func rotated(_ image: NSImage, degrees: CGFloat) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width / 2, yBy: size.height / 2)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        result.isTemplate = image.isTemplate
        return result
    }
}
