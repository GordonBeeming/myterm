// Optional native review surface. Built headlessly; shown only with --gui.
@MainActor
final class ReviewWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let root = NSStackView()
    let panes = NSStackView()
    let state = NSTextField(labelWithString: "Connect the disposable servers to begin.")
    var workspace = 0
    var commandID = 1_000_000
    var tick: Timer?
    var currentViews: [TerminalView] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "MyTerm native handoff prototype"
        window.isReleasedWhenClosed = false
        window.delegate = self
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSStackView()
        for index in 0..<2 {
            let button = NSButton(title: "Workspace \(index + 1)", target: self, action: #selector(selectWorkspace(_:)))
            button.tag = index
            bar.addArrangedSubview(button)
        }
        bar.addArrangedSubview(NSTextField(labelWithString: "Disposable PTYs • visible-pane subscriptions"))
        root.addArrangedSubview(bar)
        root.addArrangedSubview(state)
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        root.addArrangedSubview(panes)
        guard let content = window.contentView else { return }
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            panes.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            panes.heightAnchor.constraint(greaterThanOrEqualToConstant: 500)])
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func command(_ value: [String: Any]) {
        commandID += 1
        var value = value
        value["id"] = commandID
        do { driver.handle(try JSONSerialization.data(withJSONObject: value)) }
        catch { emit(["kind": "fatal", "error": "\(error)"]) }
    }

    @objc func selectWorkspace(_ sender: NSButton) {
        window.makeFirstResponder(nil)
        let old = workspace
        workspace = sender.tag
        if old != workspace {
            for server in driver.channels.keys.sorted() {
                command(["action": "subscribe", "server": server, "session": old, "enabled": false])
                command(["action": "subscribe", "server": server, "session": workspace, "enabled": true])
            }
        }
        currentViews = []
        refresh()
    }

    @objc func takeControl(_ sender: NSButton) {
        guard let server = sender.identifier?.rawValue, let channel = driver.channels[server] else { return }
        let pane = channel.panes[workspace]
        command(["action": "take", "server": server, "session": workspace, "expectedOwner": pane.owner as Any? ?? NSNull(),
                 "revision": pane.revision, "cols": 120, "rows": 40])
    }

    @objc func releaseControl(_ sender: NSButton) {
        guard let server = sender.identifier?.rawValue, let channel = driver.channels[server] else { return }
        command(["action": "release", "server": server, "session": workspace, "revision": channel.panes[workspace].revision])
    }

    @objc func sendEcho(_ sender: NSButton) {
        guard let server = sender.identifier?.rawValue, let channel = driver.channels[server] else { return }
        let marker = "manual-\(commandID)"
        do {
            var data = try JSONSerialization.data(withJSONObject: ["echo": marker])
            data.append(10)
            command(["action": "input", "server": server, "session": workspace,
                     "revision": channel.panes[workspace].revision, "data": data.base64EncodedString()])
        } catch { emit(["kind": "fatal", "error": "\(error)"]) }
    }

    func refresh() {
        let servers = driver.channels.keys.sorted()
        if let client = driver.channels.values.first?.clientID { window.title = "MyTerm handoff prototype — \(client)" }
        state.stringValue = servers.compactMap { server in
            guard let channel = driver.channels[server] else { return nil }
            let pane = channel.panes[workspace]
            pane.recorder.onUserInput = { [weak self, weak pane] bytes in
                guard let self, let pane else { return }
                do {
                    var record = try JSONSerialization.data(withJSONObject: ["keyboard": Array(bytes)])
                    record.append(10)
                    self.command(["action": "input", "server": server, "session": self.workspace,
                                  "revision": pane.revision, "data": record.base64EncodedString()])
                } catch { emit(["kind": "fatal", "error": "\(error)"]) }
            }
            let role = pane.pendingTake != nil ? "Taking control…" : pane.owner.map { "Controller: \($0)" } ?? "View only • unowned"
            let stream = channel.closed ? "Disconnected" : (pane.inputReady ? "Stream live" : "Catching up…")
            return "\(server.uppercased()): \(role) • revision \(pane.revision) • \(stream)"
        }.joined(separator: "     ")
        let views = servers.compactMap { driver.channels[$0]?.panes[workspace].view }
        guard views.map(ObjectIdentifier.init) != currentViews.map(ObjectIdentifier.init) else { return }
        for child in panes.arrangedSubviews { panes.removeArrangedSubview(child); child.removeFromSuperview() }
        currentViews = views
        for server in servers {
            guard let channel = driver.channels[server] else { continue }
            let pane = channel.panes[workspace]
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            let buttons = NSStackView()
            buttons.addArrangedSubview(NSTextField(labelWithString: "Server \(server.uppercased())"))
            for (title, action) in [("Take control", #selector(takeControl(_:))), ("Release", #selector(releaseControl(_:))), ("Send test input", #selector(sendEcho(_:)))] {
                let button = NSButton(title: title, target: self, action: action)
                button.identifier = NSUserInterfaceItemIdentifier(server)
                buttons.addArrangedSubview(button)
            }
            column.addArrangedSubview(buttons)
            let scroll = NSScrollView()
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = true
            // Automatic terminal resizing is disabled; only server deliveries change rows and columns.
            pane.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
            scroll.documentView = pane.view
            column.addArrangedSubview(scroll)
            NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: column.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 500)])
            panes.addArrangedSubview(column)
        }
    }

    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
}

var reviewWindow: ReviewWindow?
