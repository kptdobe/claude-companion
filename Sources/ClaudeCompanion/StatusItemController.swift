import AppKit

/// Owns the menu bar status item: the (animated) icon and the session list menu.
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength)
    private let monitor: SessionMonitor
    private let titles = TranscriptTitleStore()
    private let notifier = Notifier()

    /// Last-seen activity per session, to detect state transitions to notify on.
    private var previousActivities: [String: SessionActivity] = [:]
    private var notificationsEnabled: Bool =
        UserDefaults.standard.object(forKey: "notifyOnStatusChange") as? Bool ?? true

    private var spinTimer: Timer?
    private var spinAngle: CGFloat = 0
    private var isSpinning = false

    /// Latest published state, combined on each render.
    private var latestSessions: [Session] = []
    private var latestUsage = UsageSnapshot()
    private var latestHeadroom: HeadroomSavings?

    init(monitor: SessionMonitor = SessionMonitor()) {
        self.monitor = monitor
        super.init()
        statusItem.button?.imagePosition = .imageLeading

        monitor.onChange = { [weak self] sessions in
            guard let self else { return }
            self.handleTransitions(sessions)
            self.latestSessions = sessions
            self.render()
        }
        monitor.onUsage = { [weak self] usage in
            self?.latestUsage = usage
            self?.render()
        }
        monitor.onHeadroom = { [weak self] savings in
            self?.latestHeadroom = savings
            self?.render()
        }
        monitor.start()
        latestSessions = monitor.sessions
        render()

        promptToInstallHeadroomIfNeeded()
    }

    // MARK: - Rendering

    private func render() {
        updateIcon(latestSessions)
        rebuildMenu(latestSessions)
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
            for session in active {
                menu.addItem(sessionItem(resolved(session)))
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

        addCostSection(to: menu)
        addHeadroomSection(to: menu)

        menu.addItem(.separator())
        let notifyItem = NSMenuItem(
            title: "Notify on Status Change", action: #selector(toggleNotifications),
            keyEquivalent: "")
        notifyItem.target = self
        notifyItem.state = notificationsEnabled ? .on : .off
        menu.addItem(notifyItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Claude Companion", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    /// Fill in the human title (and, for Paperclip, the issue key) from the
    /// transcript. Shared by the menu and the notifications.
    private func resolved(_ session: Session) -> Session {
        var s = session
        let info = titles.info(for: s.id, cwd: s.cwd)
        s.customTitle = info.title
        // Only PaperclipAI (sdk-cli) sessions are issue-scoped; other sessions
        // may merely mention an issue key in their transcript.
        if s.entrypoint == .sdk { s.issueKey = info.issueKey }
        return s
    }

    private func sessionItem(_ session: Session) -> NSMenuItem {
        let item = NSMenuItem(
            title: "", action: #selector(jump(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session
        item.image = stateGlyph(session.activity)

        // Two lines: title + a subtitle carrying state and, when known, cost.
        var subtitle = "\(stateLabel(session.activity)) · \(session.entrypoint.label)"
        if let usage = latestUsage.perSession[session.id], !usage.isEmpty {
            subtitle += " · \(UsageFormat.costAndTokens(usage))"
        }
        item.attributedTitle = twoLine(
            "\(session.title)", subtitle: subtitle)

        item.toolTip = tooltip(for: session)
        return item
    }

    private func tooltip(for session: Session) -> String {
        var lines = ["\(stateLabel(session.activity)) — \(session.cwd)"]
        if let u = latestUsage.perSession[session.id], !u.isEmpty {
            lines.append("")
            lines.append("Cost: \(UsageFormat.cost(u.cost))")
            lines.append("Input: \(UsageFormat.tokens(u.inputTokens))")
            lines.append("Output: \(UsageFormat.tokens(u.outputTokens))")
            lines.append("Cache write: \(UsageFormat.tokens(u.cacheWriteTokens))")
            lines.append("Cache read: \(UsageFormat.tokens(u.cacheReadTokens))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Cost / Headroom sections

    private func addCostSection(to menu: NSMenu) {
        guard !latestUsage.today.isEmpty || !latestUsage.last30.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(disabled(header: "Cost"))
        menu.addItem(disabled(info: "Today: \(UsageFormat.costAndTokens(latestUsage.today))"))
        menu.addItem(disabled(info: "Last 30 days: \(UsageFormat.costAndTokens(latestUsage.last30))"))
    }

    private func addHeadroomSection(to menu: NSMenu) {
        menu.addItem(.separator())
        if let h = latestHeadroom {
            menu.addItem(disabled(header: "Headroom savings"))
            let today = "\(UsageFormat.cost(h.costSavedToday)) · \(UsageFormat.tokens(h.tokensSavedToday)) tokens"
            let last30 = "\(UsageFormat.cost(h.costSaved30d)) · \(UsageFormat.tokens(h.tokensSaved30d)) tokens"
            menu.addItem(disabled(info: "Today: \(today)"))
            menu.addItem(disabled(info: "Last 30 days: \(last30)"))
        } else {
            let install = NSMenuItem(
                title: "Install headroom.ai to save tokens…",
                action: #selector(showHeadroomInstall), keyEquivalent: "")
            install.target = self
            install.image = symbol("wand.and.stars", color: nil)
            menu.addItem(install)
        }
    }

    private func disabled(header: String) -> NSMenuItem {
        let item = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: header, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
        ])
        return item
    }

    private func disabled(info: String) -> NSMenuItem {
        let item = NSMenuItem(title: info, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: info, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    /// A menu-item title of a bold-ish primary line over a small gray subtitle.
    private func twoLine(_ title: String, subtitle: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: paragraph,
            ])
        result.append(NSAttributedString(
            string: "\n\(subtitle)",
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        return result
    }

    // MARK: - Status-change notifications

    /// Notify when a session becomes attention-worthy: it starts waiting on you,
    /// or it finishes its turn. First sightings (and the constant thinking churn)
    /// are recorded silently so launch and normal work don't spam notifications.
    private func handleTransitions(_ sessions: [Session]) {
        let liveIds = Set(sessions.map(\.id))
        for session in sessions {
            let prev = previousActivities[session.id]
            let new = session.activity
            defer { previousActivities[session.id] = new }
            guard notificationsEnabled, let prev, prev != new else { continue }
            switch new {
            case .waiting:
                notifier.post(title: resolved(session).title,
                              body: "Waiting for you", sound: true)
            case .idle:
                notifier.post(title: resolved(session).title,
                              body: "Done", sound: false)
            default:
                break  // thinking / unknown aren't worth a notification
            }
        }
        // Forget sessions that are gone so a reused id doesn't inherit old state.
        previousActivities = previousActivities.filter { liveIds.contains($0.key) }
    }

    // MARK: - Actions

    @objc private func toggleNotifications() {
        notificationsEnabled.toggle()
        UserDefaults.standard.set(notificationsEnabled, forKey: "notifyOnStatusChange")
        render()
    }

    @objc private func jump(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        WindowActivator.activate(session)
    }

    @objc private func showHeadroomInstall() {
        presentHeadroomInstall(firstRun: false)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Headroom first-run prompt

    private func promptToInstallHeadroomIfNeeded() {
        let key = "didPromptHeadroomInstall"
        guard !HeadroomStore.isInstalled,
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        // Let the status item finish setting up before showing a modal.
        DispatchQueue.main.async { [weak self] in
            self?.presentHeadroomInstall(firstRun: true)
        }
    }

    private func presentHeadroomInstall(firstRun: Bool) {
        let alert = NSAlert()
        alert.messageText = "Save tokens with headroom.ai"
        alert.informativeText = """
        Headroom is a local context-compression layer that shrinks prompts \
        before they reach the model, cutting token usage and cost. Claude \
        Companion will show your savings once it's installed.

        Install it, then reopen the menu:

        \(HeadroomStore.installCommand)
        """
        alert.addButton(withTitle: "Copy Install Command")
        alert.addButton(withTitle: "Open Website")
        alert.addButton(withTitle: firstRun ? "Not Now" : "Close")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(HeadroomStore.installCommand, forType: .string)
        case .alertSecondButtonReturn:
            if let url = URL(string: "https://github.com/headroomlabs-ai/headroom") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
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
