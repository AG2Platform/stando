import AppKit

// Settings window — the main UI for configuring Sutando.
//
// Sections (top to bottom):
//   1. Cloud account     — sign-in status / button
//   2. API keys          — Gemini (required), Cartesia (optional)
//                          + disclosure for advanced (Twilio, X, ngrok)
//   3. Permissions       — microphone / accessibility / screen-recording
//                          status + System Settings deeplinks
//   4. Background services — Install / Uninstall buttons
//
// Persistence: API keys go to $SUTANDO_HOME/.env (mode 0600) via EnvFile.
// On Save, the running services are restarted (best-effort) so changes
// take effect immediately without manual intervention.

private func sutandoHomePath() -> String {
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

private func envFilePath() -> String { sutandoHomePath() + "/.env" }

// Marker for "user has completed initial setup". Created when the user
// clicks Save with a valid Gemini key. Absence triggers the first-launch
// auto-open behavior in main.swift.
private func firstRunCompleteMarker() -> String { sutandoHomePath() + "/.firstrun-complete" }

enum SettingsField: String, CaseIterable {
    // Required.
    case GEMINI_API_KEY
    // Optional, common.
    case CARTESIA_API_KEY
    case CARTESIA_VOICE_ID
    case NOTIFICATION_EMAIL
    // Optional, advanced.
    case TWILIO_ACCOUNT_SID
    case TWILIO_AUTH_TOKEN
    case TWILIO_PHONE_NUMBER
    case NGROK_DOMAIN
    case OWNER_NUMBER
    case VERIFIED_CALLERS
    case X_BEARER_TOKEN
    case X_API_KEY
    case X_API_SECRET
    case X_ACCESS_TOKEN
    case X_ACCESS_TOKEN_SECRET

    var label: String {
        switch self {
        case .GEMINI_API_KEY: return "Gemini API key"
        case .CARTESIA_API_KEY: return "Cartesia API key"
        case .CARTESIA_VOICE_ID: return "Cartesia voice ID"
        case .NOTIFICATION_EMAIL: return "Notification email"
        case .TWILIO_ACCOUNT_SID: return "Twilio Account SID"
        case .TWILIO_AUTH_TOKEN: return "Twilio Auth Token"
        case .TWILIO_PHONE_NUMBER: return "Twilio phone number"
        case .NGROK_DOMAIN: return "ngrok reserved domain"
        case .OWNER_NUMBER: return "Owner phone number"
        case .VERIFIED_CALLERS: return "Verified callers (comma-separated)"
        case .X_BEARER_TOKEN: return "X bearer token"
        case .X_API_KEY: return "X API key"
        case .X_API_SECRET: return "X API secret"
        case .X_ACCESS_TOKEN: return "X access token"
        case .X_ACCESS_TOKEN_SECRET: return "X access token secret"
        }
    }

    var helpText: String? {
        switch self {
        case .GEMINI_API_KEY: return "Required for voice + vision. Free tier covers normal use."
        case .CARTESIA_API_KEY: return "Optional — premium TTS for task results."
        case .NOTIFICATION_EMAIL: return "Optional — alerts when health checks fail."
        case .TWILIO_ACCOUNT_SID: return "Optional — phone calls. Free trial available."
        case .NGROK_DOMAIN: return "Optional — reserved domain for stable Twilio webhooks."
        case .OWNER_NUMBER: return "Your phone number, e.g. +14155551234. Full phone access."
        case .VERIFIED_CALLERS: return "Numbers granted limited access. Comma-separated."
        case .X_BEARER_TOKEN: return "Optional — read-only X (Twitter) access."
        default: return nil
        }
    }

    var isSecret: Bool {
        switch self {
        case .GEMINI_API_KEY, .CARTESIA_API_KEY, .TWILIO_AUTH_TOKEN,
             .X_BEARER_TOKEN, .X_API_KEY, .X_API_SECRET,
             .X_ACCESS_TOKEN, .X_ACCESS_TOKEN_SECRET:
            return true
        default:
            return false
        }
    }

    var helpURL: URL? {
        switch self {
        case .GEMINI_API_KEY: return URL(string: "https://ai.google.dev")
        case .CARTESIA_API_KEY: return URL(string: "https://cartesia.ai")
        case .TWILIO_ACCOUNT_SID, .TWILIO_AUTH_TOKEN, .TWILIO_PHONE_NUMBER:
            return URL(string: "https://www.twilio.com/")
        case .NGROK_DOMAIN: return URL(string: "https://dashboard.ngrok.com/domains")
        default: return nil
        }
    }

    static var basic: [SettingsField] { [.GEMINI_API_KEY, .CARTESIA_API_KEY, .NOTIFICATION_EMAIL] }
    static var advanced: [SettingsField] {
        [.CARTESIA_VOICE_ID, .TWILIO_ACCOUNT_SID, .TWILIO_AUTH_TOKEN, .TWILIO_PHONE_NUMBER,
         .NGROK_DOMAIN, .OWNER_NUMBER, .VERIFIED_CALLERS, .X_BEARER_TOKEN, .X_API_KEY,
         .X_API_SECRET, .X_ACCESS_TOKEN, .X_ACCESS_TOKEN_SECRET]
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var fieldEditors: [SettingsField: NSTextField] = [:]
    private var permissionStatusLabels: [SystemPermission: NSTextField] = [:]
    private var cloudStatusLabel: NSTextField?
    private var cloudActionButton: NSButton?
    private var advancedDisclosure: NSButton?
    private var advancedContainer: NSView?
    private var statusBanner: NSTextField?
    private var claudeStatusLabel: NSTextField?
    private var claudeActionButton: NSButton?
    private var claudeSpinner: NSProgressIndicator?
    private var stepperContainer: NSStackView?
    private var stepperDots: [NSTextField] = []
    private var stepperLabels: [NSTextField] = []

    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sutando — Settings"
        window.minSize = NSSize(width: 560, height: 480)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadFromDisk()
        startStatusPolling()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showAndFocus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let window = window else { return }

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let title = NSTextField(labelWithString: "Sutando")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Add your API key and Sutando is ready to use. Everything below is optional.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(subtitle)

        // Status banner (hidden until there's something to say)
        let banner = NSTextField(labelWithString: "")
        banner.font = .systemFont(ofSize: 12, weight: .medium)
        banner.isHidden = true
        statusBanner = banner
        stack.addArrangedSubview(banner)

        // First-launch stepper. Visible until the user has saved at least
        // once (which writes $SUTANDO_HOME/.firstrun-complete). Shows
        // progress through the 4 setup steps so a non-technical user knows
        // what to do and what's already done.
        let stepper = buildStepperView()
        stepperContainer = stepper
        stepper.isHidden = FileManager.default.fileExists(atPath: firstRunCompleteMarker())
        stack.addArrangedSubview(stepper)

        // Cloud account section
        stack.addArrangedSubview(sectionHeader("Sutando Cloud"))
        stack.addArrangedSubview(cloudAccountRow())

        // API keys
        stack.addArrangedSubview(sectionHeader("API keys"))
        for field in SettingsField.basic {
            stack.addArrangedSubview(fieldRow(field))
        }
        // Advanced disclosure
        let disclosure = NSButton()
        disclosure.bezelStyle = .recessed
        disclosure.title = "▶ Advanced integrations"
        disclosure.setButtonType(.momentaryChange)
        disclosure.font = .systemFont(ofSize: 12, weight: .medium)
        disclosure.target = self
        disclosure.action = #selector(toggleAdvanced)
        advancedDisclosure = disclosure
        stack.addArrangedSubview(disclosure)

        let advancedStack = NSStackView()
        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        advancedStack.spacing = 14
        advancedStack.translatesAutoresizingMaskIntoConstraints = false
        for field in SettingsField.advanced {
            advancedStack.addArrangedSubview(fieldRow(field))
        }
        advancedStack.isHidden = true
        advancedContainer = advancedStack
        stack.addArrangedSubview(advancedStack)

        // Claude Code (prereq for the core-agent service)
        stack.addArrangedSubview(sectionHeader("Claude Code"))
        stack.addArrangedSubview(claudeCodeRow())

        // Permissions
        stack.addArrangedSubview(sectionHeader("System permissions"))
        for perm in SystemPermission.allCases {
            stack.addArrangedSubview(permissionRow(perm))
        }

        // Background services
        stack.addArrangedSubview(sectionHeader("Background services"))
        stack.addArrangedSubview(servicesRow())

        // Bottom buttons
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.addArrangedSubview(spacer)
        let cancel = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        cancel.bezelStyle = .rounded
        let save = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        footer.addArrangedSubview(cancel)
        footer.addArrangedSubview(save)
        stack.addArrangedSubview(footer)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalToConstant: 560),
        ])
        scrollView.documentView = documentView
        window.contentView!.addSubview(scrollView)
    }

    private func sectionHeader(_ title: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let wrap = NSStackView()
        wrap.orientation = .vertical
        wrap.spacing = 6
        wrap.alignment = .leading
        wrap.addArrangedSubview(label)
        let hr = NSBox()
        hr.boxType = .separator
        hr.translatesAutoresizingMaskIntoConstraints = false
        hr.widthAnchor.constraint(equalToConstant: 504).isActive = true
        wrap.addArrangedSubview(hr)
        return wrap
    }

    private func cloudAccountRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        cloudStatusLabel = label
        row.addArrangedSubview(label)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let button = NSButton(title: "Sign in", target: self, action: #selector(toggleCloudAccount))
        button.bezelStyle = .rounded
        cloudActionButton = button
        row.addArrangedSubview(button)

        updateCloudUI()
        return row
    }

    private func fieldRow(_ field: SettingsField) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4

        let labelRow = NSStackView()
        labelRow.orientation = .horizontal
        labelRow.spacing = 6
        labelRow.alignment = .firstBaseline

        let label = NSTextField(labelWithString: field.label + (field == .GEMINI_API_KEY ? " (required)" : ""))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        labelRow.addArrangedSubview(label)
        if let url = field.helpURL {
            let link = NSButton()
            link.title = "Get key →"
            link.bezelStyle = .recessed
            link.font = .systemFont(ofSize: 11)
            link.target = self
            link.action = #selector(openHelpLink(_:))
            link.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
            labelRow.addArrangedSubview(link)
        }
        row.addArrangedSubview(labelRow)

        let editor: NSTextField = field.isSecret ? NSSecureTextField() : NSTextField()
        editor.placeholderString = field.isSecret ? "stored locally, never logged" : ""
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.widthAnchor.constraint(equalToConstant: 504).isActive = true
        row.addArrangedSubview(editor)
        fieldEditors[field] = editor

        if let help = field.helpText {
            let hint = NSTextField(labelWithString: help)
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            row.addArrangedSubview(hint)
        }
        return row
    }

    private func permissionRow(_ perm: SystemPermission) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let status = NSTextField(labelWithString: "○")
        status.font = .systemFont(ofSize: 14, weight: .bold)
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 18).isActive = true
        permissionStatusLabels[perm] = status
        row.addArrangedSubview(status)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        let title = NSTextField(labelWithString: perm.displayName)
        title.font = .systemFont(ofSize: 13)
        let subtitle = NSTextField(labelWithString: perm.purpose)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(subtitle)
        row.addArrangedSubview(textStack)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let button = NSButton(title: "Grant…", target: self, action: #selector(grantPermission(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(perm.rawValue)
        row.addArrangedSubview(button)
        return row
    }

    // MARK: - First-launch stepper

    private static let stepNames = ["API key", "Claude Code", "Permissions", "Background services"]

    private func buildStepperView() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        for (i, name) in Self.stepNames.enumerated() {
            let dot = NSTextField(labelWithString: "○")
            dot.font = .systemFont(ofSize: 13, weight: .bold)
            stepperDots.append(dot)
            row.addArrangedSubview(dot)

            let label = NSTextField(labelWithString: "\(i + 1). \(name)")
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            stepperLabels.append(label)
            row.addArrangedSubview(label)

            if i < Self.stepNames.count - 1 {
                let sep = NSTextField(labelWithString: "›")
                sep.font = .systemFont(ofSize: 13)
                sep.textColor = .tertiaryLabelColor
                row.addArrangedSubview(sep)
            }
        }
        refreshStepperUI()
        return row
    }

    /// Step state. Index matches `stepNames`.
    private func stepperStatus() -> [Bool] {
        // 1. API key — Gemini set in env (in-memory edit OR on-disk).
        let inFlightKey = fieldEditors[.GEMINI_API_KEY]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let onDiskKey = EnvFile.at(envFilePath()).value(for: SettingsField.GEMINI_API_KEY.rawValue) ?? ""
        let apiKeyDone = !inFlightKey.isEmpty || !onDiskKey.isEmpty

        // 2. Claude Code — installed (we can't detect signed-in without
        //    running it, so this only checks for the binary).
        let claudeDone = claudeCodePath() != nil

        // 3. Permissions — all required ones granted.
        let permissionsDone = SystemPermission.allCases.allSatisfy { $0.status() == .granted }

        // 4. Background services — at least 5 of the 7 expected agents loaded.
        let loaded = LaunchAgentInstaller().loadedLabels().count
        let servicesDone = loaded >= 5

        return [apiKeyDone, claudeDone, permissionsDone, servicesDone]
    }

    private func refreshStepperUI() {
        guard !stepperDots.isEmpty else { return }
        let states = stepperStatus()
        for (i, done) in states.enumerated() {
            let dot = stepperDots[i]
            let label = stepperLabels[i]
            dot.stringValue = done ? "✓" : "○"
            dot.textColor = done ? .systemGreen : .tertiaryLabelColor
            label.textColor = done ? .labelColor : .secondaryLabelColor
        }
    }

    private func claudeCodeRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let status = NSTextField(labelWithString: "Checking…")
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        status.cell?.wraps = true
        claudeStatusLabel = status
        row.addArrangedSubview(status)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        claudeSpinner = spinner
        row.addArrangedSubview(spinner)

        let button = NSButton(title: "…", target: self, action: #selector(claudeCodeAction))
        button.bezelStyle = .rounded
        claudeActionButton = button
        row.addArrangedSubview(button)

        refreshClaudeCodeUI()
        return row
    }

    /// Resolve `claude` on PATH or in well-known install locations.
    /// Settings inherits a sparse PATH from launchd, so we also look in
    /// the standard places where `claude.ai/install.sh` and Homebrew
    /// drop the binary.
    private func claudeCodePath() -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs.append(contentsOf: [
            NSHomeDirectory() + "/.local/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            NSHomeDirectory() + "/.npm-global/bin",
        ])
        for dir in dirs where !dir.isEmpty {
            let path = dir + "/claude"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func refreshClaudeCodeUI() {
        if let path = claudeCodePath() {
            let homeRel = path.hasPrefix(NSHomeDirectory())
                ? "~" + path.dropFirst(NSHomeDirectory().count)
                : path
            claudeStatusLabel?.stringValue =
                "Installed at \(homeRel). If you haven't authenticated, click Sign in."
            claudeStatusLabel?.textColor = .labelColor
            claudeActionButton?.title = "Sign in…"
        } else {
            claudeStatusLabel?.stringValue =
                "Not installed. Required for the core agent (proactive loop, voice tasks)."
            claudeStatusLabel?.textColor = .secondaryLabelColor
            claudeActionButton?.title = "Install"
        }
    }

    @objc private func claudeCodeAction() {
        if claudeCodePath() != nil {
            // Installed → open Terminal so the user can run `claude auth login`
            // interactively. We can't drive the auth flow from inside the app
            // because Anthropic's flow opens a browser + reads stdin.
            openTerminalRunning("claude auth login")
        } else {
            runClaudeCodeInstaller()
        }
    }

    /// Open Terminal.app with a one-shot command. Falls back to a
    /// notification if Terminal automation is denied.
    private func openTerminalRunning(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if err != nil {
            showBanner("Open Terminal and run: \(command)", color: .systemOrange)
        }
    }

    /// Run `curl -fsSL https://claude.ai/install.sh | bash` via NSTask.
    /// The official installer lands the binary at ~/.local/bin/claude (no
    /// sudo needed) and updates the user's shell rc.
    private func runClaudeCodeInstaller() {
        claudeActionButton?.isEnabled = false
        claudeSpinner?.startAnimation(nil)
        claudeStatusLabel?.stringValue = "Installing Claude Code…"
        claudeStatusLabel?.textColor = .secondaryLabelColor

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            // -l so the installer's PATH lookups (curl, install -d, etc.)
            // pick up Homebrew + system paths cleanly; -c for the inline
            // pipeline.
            proc.arguments = ["-lc", "curl -fsSL https://claude.ai/install.sh | bash"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var output = ""
            var success = false
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output = String(data: data, encoding: .utf8) ?? ""
                success = proc.terminationStatus == 0
            } catch {
                output = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.claudeSpinner?.stopAnimation(nil)
                self.claudeActionButton?.isEnabled = true
                self.refreshClaudeCodeUI()
                if success && self.claudeCodePath() != nil {
                    self.showBanner("Installed Claude Code. Click Sign in to authenticate.", color: .systemGreen)
                } else {
                    let snippet = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                    self.showBanner("Install failed: \(snippet.prefix(220))", color: .systemRed)
                }
            }
        }
    }

    private func servicesRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let info = NSTextField(labelWithString: "Voice agent, dashboard, bridges. Run in the background.")
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        row.addArrangedSubview(info)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let install = NSButton(title: "Install", target: self, action: #selector(installServices))
        install.bezelStyle = .rounded
        let uninstall = NSButton(title: "Uninstall", target: self, action: #selector(uninstallServices))
        uninstall.bezelStyle = .rounded
        row.addArrangedSubview(install)
        row.addArrangedSubview(uninstall)
        return row
    }

    // MARK: - Actions

    @objc private func saveSettings() {
        var env = EnvFile.at(envFilePath())
        for (field, editor) in fieldEditors {
            let value = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            env.set(field.rawValue, value.isEmpty ? nil : value)
        }
        do {
            try env.write(to: envFilePath())
            // Mark first-launch complete so we don't auto-open next time.
            FileManager.default.createFile(atPath: firstRunCompleteMarker(), contents: Data())
            // Hide the first-launch stepper now that the user has saved
            // (the marker file is the source of truth for "are we still
            // onboarding").
            stepperContainer?.isHidden = true
            showBanner("Saved. Background services will pick up the new settings on next restart.", color: .systemGreen)
        } catch {
            showBanner("Failed to save: \(error.localizedDescription)", color: .systemRed)
        }
    }

    @objc private func closeWindow() { window?.close() }

    @objc private func toggleAdvanced() {
        guard let advancedContainer = advancedContainer else { return }
        let willShow = advancedContainer.isHidden
        advancedContainer.isHidden = !willShow
        advancedDisclosure?.title = willShow ? "▼ Advanced integrations" : "▶ Advanced integrations"
    }

    @objc private func toggleCloudAccount() {
        if CloudAuth.shared.isSignedIn {
            CloudAuth.shared.signOut()
        } else {
            _ = CloudAuth.shared.startSignIn()
        }
        // Allow time for the URL-scheme handoff to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in updateCloudUI() }
    }

    @objc private func openHelpLink(_ sender: NSButton) {
        guard let urlString = sender.identifier?.rawValue,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func grantPermission(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let perm = SystemPermission(rawValue: raw) else { return }
        // Always open System Settings so the user can flip the toggle.
        if let url = perm.systemSettingsURL { NSWorkspace.shared.open(url) }
        // Also fire the system request when applicable.
        perm.request { [weak self] _ in self?.updatePermissionUI() }
    }

    @objc private func installServices() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let installer = LaunchAgentInstaller()
            let paths = LaunchAgentInstaller.defaultPaths(workspace: appDelegate?.workspace ?? "")
            do {
                let summary = try installer.install(paths: paths)
                DispatchQueue.main.async { [self] in
                    if summary.failed.isEmpty {
                        var msg = "Installed \(summary.installed.count) services."
                        if !summary.skippedDisabled.isEmpty {
                            msg += " Skipped \(summary.skippedDisabled.joined(separator: ", ")) (disabled)."
                        }
                        showBanner(msg, color: .systemGreen)
                    } else {
                        let errs = summary.failed.map { "\($0.label): \($0.message)" }.joined(separator: "; ")
                        showBanner("Installed \(summary.installed.count). Failed: \(errs)", color: .systemOrange)
                    }
                }
            } catch {
                DispatchQueue.main.async { [self] in
                    showBanner("Install failed: \(error.localizedDescription)", color: .systemRed)
                }
            }
        }
    }

    @objc private func uninstallServices() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let removed = LaunchAgentInstaller().uninstall()
            DispatchQueue.main.async { [self] in
                showBanner("Removed \(removed.count) services.", color: .systemOrange)
            }
        }
    }

    // MARK: - State sync

    private func loadFromDisk() {
        let env = EnvFile.at(envFilePath())
        for field in SettingsField.allCases {
            fieldEditors[field]?.stringValue = env.value(for: field.rawValue) ?? ""
        }
    }

    private func startStatusPolling() {
        updatePermissionUI()
        updateCloudUI()
        refreshClaudeCodeUI()
        refreshStepperUI()
        // Refresh permission + cloud + Claude Code + stepper status while
        // the window is open so returning from System Settings, a Terminal
        // install, or a Background Services Install reflects the new state.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self, let window = self.window, window.isVisible else {
                timer.invalidate()
                return
            }
            self.updatePermissionUI()
            self.updateCloudUI()
            self.refreshClaudeCodeUI()
            self.refreshStepperUI()
        }
    }

    private func updatePermissionUI() {
        for perm in SystemPermission.allCases {
            let status = perm.status()
            if let label = permissionStatusLabels[perm] {
                label.stringValue = status.symbol
                label.textColor = status.color
            }
        }
    }

    private func updateCloudUI() {
        let signedIn = CloudAuth.shared.isSignedIn
        let userId = CloudAuth.shared.record()?.userId.prefix(8) ?? ""
        cloudStatusLabel?.stringValue = signedIn
            ? "Signed in (user \(userId)…)"
            : "Not signed in. Optional, but unlocks usage dashboards."
        cloudStatusLabel?.textColor = signedIn ? .labelColor : .secondaryLabelColor
        cloudActionButton?.title = signedIn ? "Sign out" : "Sign in"
    }

    private func showBanner(_ message: String, color: NSColor) {
        guard let banner = statusBanner else { return }
        banner.stringValue = message
        banner.textColor = color
        banner.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak banner] in
            banner?.isHidden = true
        }
    }

    // MARK: - First-launch hook

    /// True when the user hasn't completed setup yet (no Gemini key + no
    /// firstrun marker). main.swift uses this on launch to decide whether
    /// to auto-open Settings.
    static var needsFirstLaunchSetup: Bool {
        if FileManager.default.fileExists(atPath: firstRunCompleteMarker()) {
            return false
        }
        let env = EnvFile.at(envFilePath())
        let key = env.value(for: SettingsField.GEMINI_API_KEY.rawValue) ?? ""
        return key.isEmpty
    }
}
