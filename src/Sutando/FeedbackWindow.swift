import AppKit

// Native feedback form. Opened by:
//   * ⌃⇧F global hotkey (main.swift defaultHotkeys)
//   * "Report an issue" button in the Settings window
//
// Captures: kind (bug / feature / other), severity, title, body. Attaches
// the last screen capture + a short log tail as context. POSTs to
// /api/feedback. Errors surface inline; success closes the window and
// fires a notification.
//
// Beta posture: no offline queue. If the user is signed out or offline
// the submit fails with a clear message; they'll retry later.

private struct _FeedbackAuth: Decodable {
    let token: String
    let userId: String
    let apiBase: String
}

private func _sutandoHomeForFeedback() -> String {
    if let home = ProcessInfo.processInfo.environment["SUTANDO_HOME"], !home.isEmpty {
        return (home as NSString).expandingTildeInPath
    }
    let exe = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
    var url = exe
    for _ in 0..<8 {
        url = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) {
            return url.path
        }
    }
    return NSHomeDirectory() + "/Library/Application Support/Sutando"
}

private func _loadFeedbackAuth() -> _FeedbackAuth? {
    let path = _sutandoHomeForFeedback() + "/cloud-auth.json"
    guard FileManager.default.fileExists(atPath: path),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        return nil
    }
    return try? JSONDecoder().decode(_FeedbackAuth.self, from: data)
}

final class FeedbackWindowController: NSWindowController, NSWindowDelegate {
    private var titleField: NSTextField!
    private var bodyField: NSTextView!
    private var kindPopup: NSPopUpButton!
    private var severityPopup: NSPopUpButton!
    private var includeScreenCheck: NSButton!
    private var statusLabel: NSTextField!
    private var submitButton: NSButton!
    private var cancelButton: NSButton!
    private var initialBodyValue: String

    init(initialBody: String) {
        self.initialBodyValue = initialBody
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Report a Sutando issue"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showAndFocus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let window = window else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Tell us what's wrong or what you wish Sutando did")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(header)

        // Kind + severity row.
        let row1 = NSStackView()
        row1.orientation = .horizontal
        row1.spacing = 12

        let kindLabel = NSTextField(labelWithString: "Kind:")
        kindLabel.font = .systemFont(ofSize: 12)
        row1.addArrangedSubview(kindLabel)

        kindPopup = NSPopUpButton()
        kindPopup.addItems(withTitles: ["bug", "feature", "other"])
        row1.addArrangedSubview(kindPopup)

        let sevLabel = NSTextField(labelWithString: "Severity:")
        sevLabel.font = .systemFont(ofSize: 12)
        row1.addArrangedSubview(sevLabel)

        severityPopup = NSPopUpButton()
        severityPopup.addItems(withTitles: ["low", "medium", "high", "critical"])
        severityPopup.selectItem(withTitle: "medium")
        row1.addArrangedSubview(severityPopup)

        stack.addArrangedSubview(row1)

        // Title.
        let titleLabel = NSTextField(labelWithString: "Title")
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(titleLabel)

        titleField = NSTextField()
        titleField.placeholderString = "One-line summary"
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.widthAnchor.constraint(equalToConstant: 472).isActive = true
        stack.addArrangedSubview(titleField)

        // Body.
        let bodyLabel = NSTextField(labelWithString: "What happened (or what should happen)?")
        bodyLabel.font = .systemFont(ofSize: 11, weight: .medium)
        bodyLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(bodyLabel)

        let bodyScroll = NSScrollView()
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .lineBorder
        bodyField = NSTextView(frame: NSRect(x: 0, y: 0, width: 472, height: 140))
        bodyField.font = .systemFont(ofSize: 12)
        bodyField.isEditable = true
        bodyField.isRichText = false
        bodyField.autoresizingMask = [.width]
        bodyField.allowsUndo = true
        if !initialBodyValue.isEmpty { bodyField.string = initialBodyValue }
        bodyScroll.documentView = bodyField
        bodyScroll.widthAnchor.constraint(equalToConstant: 472).isActive = true
        bodyScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(bodyScroll)

        includeScreenCheck = NSButton(
            checkboxWithTitle: "Attach a screenshot of the current screen",
            target: nil,
            action: nil
        )
        includeScreenCheck.state = .off
        includeScreenCheck.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(includeScreenCheck)

        // Status line for errors / success.
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)

        // Footer.
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.addArrangedSubview(spacer)
        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        footer.addArrangedSubview(cancelButton)
        submitButton = NSButton(title: "Send", target: self, action: #selector(submit))
        submitButton.bezelStyle = .rounded
        submitButton.keyEquivalent = "\r"
        footer.addArrangedSubview(submitButton)
        stack.addArrangedSubview(footer)

        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func submit() {
        let kind = kindPopup.titleOfSelectedItem ?? "other"
        let severity = severityPopup.titleOfSelectedItem ?? "medium"
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyField.string.trimmingCharacters(in: .whitespacesAndNewlines)

        if title.isEmpty {
            setStatus("Title required.", error: true)
            return
        }
        guard let auth = _loadFeedbackAuth() else {
            setStatus("Sign in to Sutando Cloud first (Settings → Sign in).", error: true)
            return
        }
        guard let url = URL(string: auth.apiBase + "/api/feedback") else {
            setStatus("Bad cloud config.", error: true)
            return
        }

        submitButton.isEnabled = false
        cancelButton.isEnabled = false
        setStatus("Sending…", error: false)

        // Build context object — frontmost app + screen path + version.
        var context: [String: Any] = [:]
        if let host = Host.current().localizedName { context["hostname"] = host }
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            context["app_version"] = version
        }
        if let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName {
            context["frontmost_app"] = frontApp
        }

        // Async helper closure: optionally capture screen, then POST.
        let postWith: ([String: Any]) -> Void = { [weak self] ctxFinal in
            var body: [String: Any] = [
                "kind": kind,
                "severity": severity,
                "title": title,
                "body": body,
                "context": ctxFinal,
            ]
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                body["appVersion"] = version
            }
            guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
                DispatchQueue.main.async { self?.setStatus("Failed to encode payload.", error: true) }
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            req.httpBody = payload
            URLSession.shared.dataTask(with: req) { _, response, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let error = error {
                        self.setStatus("Send failed: \(error.localizedDescription)", error: true)
                        self.submitButton.isEnabled = true
                        self.cancelButton.isEnabled = true
                        return
                    }
                    if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                        let n = "Sutando — feedback sent. Thanks!"
                        let safe = n.replacingOccurrences(of: "\"", with: "")
                        _ = try? Process.run(
                            URL(fileURLWithPath: "/usr/bin/osascript"),
                            arguments: ["-e", "display notification \"\(safe)\" with title \"Sutando\""]
                        )
                        self.window?.close()
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self.setStatus("Send failed (HTTP \(status)).", error: true)
                    self.submitButton.isEnabled = true
                    self.cancelButton.isEnabled = true
                }
            }.resume()
        }

        if includeScreenCheck.state == .on {
            captureScreenPath { path in
                var ctxLocal = context
                if let path = path { ctxLocal["last_screen_path"] = path }
                postWith(ctxLocal)
            }
        } else {
            postWith(context)
        }
    }

    private func setStatus(_ msg: String, error: Bool) {
        statusLabel.stringValue = msg
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    /// Call the local screen-capture server (started by src/startup.sh) to
    /// snapshot the current screen. Returns the file path on success.
    /// Times out at 3s — feedback flow shouldn't block on a downed server.
    private func captureScreenPath(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "http://localhost:7845/capture") else {
            completion(nil); return
        }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = json["path"] as? String else {
                completion(nil); return
            }
            completion(path)
        }.resume()
    }
}
