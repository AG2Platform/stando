import AppKit
import UniformTypeIdentifiers

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

// Workspace dir — `$SUTANDO_WORKSPACE`, default `~/.sutando/workspace/`.
private func _sutandoHomeForFeedback() -> String {
    if let ws = ProcessInfo.processInfo.environment["SUTANDO_WORKSPACE"], !ws.isEmpty {
        return (ws as NSString).expandingTildeInPath
    }
    return NSHomeDirectory() + "/.sutando/workspace"
}

private func _loadFeedbackAuth() -> _FeedbackAuth? {
    let path = _sutandoHomeForFeedback() + "/cloud-auth.json"
    guard FileManager.default.fileExists(atPath: path),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        return nil
    }
    return try? JSONDecoder().decode(_FeedbackAuth.self, from: data)
}

/// Up to 3 image attachments, ~5MB raw each (the cloud /api/feedback route
/// caps the base64 dataB64 field at 7MB, which fits a 5MB binary payload).
private let _maxAttachments = 3
private let _maxAttachmentRawBytes = 5_000_000
private let _supportedAttachmentMimes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

private struct FeedbackAttachment {
    let name: String
    let mime: String
    let data: Data
}

final class FeedbackWindowController: NSWindowController, NSWindowDelegate {
    private var titleField: NSTextField!
    private var bodyField: PasteAwareTextView!
    private var kindPopup: NSPopUpButton!
    private var severityPopup: NSPopUpButton!
    private var includeScreenCheck: NSButton!
    private var statusLabel: NSTextField!
    private var submitButton: NSButton!
    private var cancelButton: NSButton!
    private var initialBodyValue: String

    private var attachments: [FeedbackAttachment] = []
    private var attachmentsStack: NSStackView!
    private var attachmentsRow: NSView!
    private var attachButton: NSButton!

    init(initialBody: String) {
        self.initialBodyValue = initialBody
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
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
        bodyField = PasteAwareTextView(frame: NSRect(x: 0, y: 0, width: 472, height: 140))
        bodyField.font = .systemFont(ofSize: 12)
        bodyField.isEditable = true
        bodyField.isRichText = false
        bodyField.autoresizingMask = [.width]
        bodyField.allowsUndo = true
        bodyField.feedbackController = self
        if !initialBodyValue.isEmpty { bodyField.string = initialBodyValue }
        bodyScroll.documentView = bodyField
        bodyScroll.widthAnchor.constraint(equalToConstant: 472).isActive = true
        bodyScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(bodyScroll)

        // Attachments row: a thumbnail strip + an "Attach images" button.
        // Paste of an image inside the body field is also captured (see
        // PasteAwareTextView below). Tip text mirrors the cloud form.
        let attachHeader = NSStackView()
        attachHeader.orientation = .horizontal
        attachHeader.spacing = 8

        let attachLabel = NSTextField(labelWithString: "Screenshots (optional, max \(_maxAttachments))")
        attachLabel.font = .systemFont(ofSize: 11, weight: .medium)
        attachLabel.textColor = .secondaryLabelColor
        attachHeader.addArrangedSubview(attachLabel)

        attachButton = NSButton(title: "Attach images", target: self, action: #selector(pickAttachments))
        attachButton.bezelStyle = .inline
        attachButton.controlSize = .small
        attachButton.font = .systemFont(ofSize: 11)
        attachHeader.addArrangedSubview(attachButton)
        stack.addArrangedSubview(attachHeader)

        attachmentsStack = NSStackView()
        attachmentsStack.orientation = .horizontal
        attachmentsStack.spacing = 6
        attachmentsStack.alignment = .top
        attachmentsRow = attachmentsStack
        stack.addArrangedSubview(attachmentsStack)

        let attachTip = NSTextField(labelWithString: "Paste a screenshot into Details (⌘V) or click Attach images. PNG / JPEG / GIF / WebP, up to 1MB each.")
        attachTip.font = .systemFont(ofSize: 10)
        attachTip.textColor = .tertiaryLabelColor
        attachTip.maximumNumberOfLines = 2
        stack.addArrangedSubview(attachTip)

        includeScreenCheck = NSButton(
            checkboxWithTitle: "Also attach a screenshot of the current screen",
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
        let attachmentsSnapshot = attachments
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
            if !attachmentsSnapshot.isEmpty {
                body["attachments"] = attachmentsSnapshot.map { att -> [String: Any] in
                    [
                        "name": att.name,
                        "mime": att.mime,
                        "dataB64": att.data.base64EncodedString(),
                    ]
                }
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

    // MARK: - Attachments

    /// Called by PasteAwareTextView when the user pastes image data into
    /// the body field. Also invoked by the Attach images button.
    func addImageData(_ data: Data, suggestedName: String, mime: String) {
        if attachments.count >= _maxAttachments {
            setStatus("Max \(_maxAttachments) attachments reached.", error: true)
            return
        }
        if data.count > _maxAttachmentRawBytes {
            setStatus("\"\(suggestedName)\" is over 5MB — please resize before attaching.", error: true)
            return
        }
        guard _supportedAttachmentMimes.contains(mime) else {
            setStatus("Unsupported image type: \(mime).", error: true)
            return
        }
        attachments.append(FeedbackAttachment(name: suggestedName, mime: mime, data: data))
        rebuildAttachmentThumbnails()
        setStatus("", error: false)
    }

    @objc private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "png": mime = "image/png"
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "webp": mime = "image/webp"
                default: continue
                }
                addImageData(data, suggestedName: url.lastPathComponent, mime: mime)
            }
        }
    }

    @objc fileprivate func removeAttachment(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < attachments.count else { return }
        attachments.remove(at: idx)
        rebuildAttachmentThumbnails()
    }

    private func rebuildAttachmentThumbnails() {
        // Clear existing arranged subviews.
        for v in attachmentsStack.arrangedSubviews { v.removeFromSuperview() }

        for (i, att) in attachments.enumerated() {
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.widthAnchor.constraint(equalToConstant: 78).isActive = true
            container.heightAnchor.constraint(equalToConstant: 64).isActive = true

            let thumb = NSImageView()
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.image = NSImage(data: att.data)
            thumb.imageScaling = .scaleProportionallyUpOrDown
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = 4
            thumb.layer?.borderWidth = 1
            thumb.layer?.borderColor = NSColor.separatorColor.cgColor
            thumb.layer?.masksToBounds = true
            container.addSubview(thumb)

            let removeBtn = NSButton(title: "×", target: self, action: #selector(removeAttachment(_:)))
            removeBtn.tag = i
            removeBtn.bezelStyle = .circular
            removeBtn.controlSize = .small
            removeBtn.font = .systemFont(ofSize: 10, weight: .bold)
            removeBtn.translatesAutoresizingMaskIntoConstraints = false
            removeBtn.toolTip = "Remove \(att.name)"
            container.addSubview(removeBtn)

            NSLayoutConstraint.activate([
                thumb.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                thumb.topAnchor.constraint(equalTo: container.topAnchor),
                thumb.widthAnchor.constraint(equalToConstant: 64),
                thumb.heightAnchor.constraint(equalToConstant: 60),
                removeBtn.topAnchor.constraint(equalTo: container.topAnchor, constant: -4),
                removeBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 0),
                removeBtn.widthAnchor.constraint(equalToConstant: 18),
                removeBtn.heightAnchor.constraint(equalToConstant: 18),
            ])
            attachmentsStack.addArrangedSubview(container)
        }
        attachButton.isEnabled = attachments.count < _maxAttachments
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

// MARK: - PasteAwareTextView

/// NSTextView that intercepts ⌘V when the pasteboard contains image
/// data, hands the bytes to the owning FeedbackWindowController as an
/// attachment, and prevents the default behavior of embedding the
/// image as an NSTextAttachment inside the body (which we'd then have
/// to extract and serialize — paste-to-attachments is the simpler flow).
/// Plain-text paste still works via super.paste.
final class PasteAwareTextView: NSTextView {
    weak var feedbackController: FeedbackWindowController?

    override func paste(_ sender: Any?) {
        if handleImagePaste() { return }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘V — let NSTextView's own paste menu route us through paste(_:).
        // We override paste(_:) above, so we don't need to intercept here.
        return super.performKeyEquivalent(with: event)
    }

    /// Returns true when image data was found + consumed.
    private func handleImagePaste() -> Bool {
        let pb = NSPasteboard.general
        // Files first — file URLs on the pasteboard usually mean an
        // image dragged in from Finder.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            var consumed = false
            for url in urls {
                let ext = url.pathExtension.lowercased()
                let mime: String?
                switch ext {
                case "png": mime = "image/png"
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "webp": mime = "image/webp"
                default: mime = nil
                }
                guard let mime = mime, let data = try? Data(contentsOf: url) else { continue }
                feedbackController?.addImageData(data, suggestedName: url.lastPathComponent, mime: mime)
                consumed = true
            }
            if consumed { return true }
        }
        // Raw bitmap (e.g. ⌘⇧⌃4 captured to clipboard).
        if let tiff = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff) {
            // Prefer PNG — lossless, what cmd+shift+ctrl+4 produces.
            if let png = bitmap.representation(using: .png, properties: [:]) {
                feedbackController?.addImageData(png, suggestedName: "screenshot.png", mime: "image/png")
                return true
            }
        }
        if let png = pb.data(forType: .png) {
            feedbackController?.addImageData(png, suggestedName: "screenshot.png", mime: "image/png")
            return true
        }
        return false
    }
}
