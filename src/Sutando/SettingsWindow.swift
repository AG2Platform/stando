import AppKit

// Settings window — the main UI for configuring Sutando.
//
// Sections (top to bottom):
//   1. Cloud account     — sign-in status / button
//   2. API keys          — Gemini (required), Cartesia (optional)
//                          + disclosure for advanced (Twilio, X, ngrok)
//   3. Permissions       — microphone / accessibility / screen-recording
//                          status + System Settings deeplinks
//   4. Background services — live status; services auto-start with the app
//                          and stop on quit (no manual Install button).
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
    // Plan + usage panel — populated from GET /api/me. Rebuilt on every
    // refresh tick (cheap: 5–7 small subviews) so the user sees fresh
    // wallet balance + caps without restarting Settings.
    private var tierPanelContainer: NSStackView?
    private var tierPlanLabel: NSTextField?
    private var tierWalletLabel: NSTextField?
    private var tierAutoTopupCheckbox: NSButton?
    private var tierBarsStack: NSStackView?
    private var tierPanelEmptyLabel: NSTextField?
    private var lastMeFetchTs: TimeInterval = 0
    private var claudeStatusLabel: NSTextField?
    private var claudeActionButton: NSButton?
    private var claudeSpinner: NSProgressIndicator?
    private var codexStatusLabel: NSTextField?
    private var codexActionButton: NSButton?
    private var geminiStatusLabel: NSTextField?
    private var geminiActionButton: NSButton?
    private var stepperContainer: NSStackView?
    private var stepperDots: [NSTextField] = []
    private var stepperLabels: [NSTextField] = []
    private var servicesStatusLabel: NSTextField?
    /// Onboarding steps already emitted this app launch. Server enforces
    /// uniqueness too (unique index on user_id+step), but checking here
    /// avoids HTTP round trips from the 1.5s status-polling loop.
    private var emittedOnboardingSteps: Set<String> = []

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

        // Plan + usage panel. Populated from GET /api/me. Hidden if
        // signed out; collapsed if no usage data yet.
        stack.addArrangedSubview(sectionHeader("Plan & usage"))
        stack.addArrangedSubview(tierUsagePanel())

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

        // Optional CLI delegates (codex / gemini). Used by the
        // claude-codex, claude-gemini, and claude-router skills. Sutando
        // works without them — these are surfaced so power users know
        // why those skills fail until they install the CLIs.
        stack.addArrangedSubview(sectionHeader("Optional CLI delegates"))
        stack.addArrangedSubview(cliDelegateRow(.codex))
        stack.addArrangedSubview(cliDelegateRow(.gemini))

        // Permissions
        stack.addArrangedSubview(sectionHeader("System permissions"))
        for perm in SystemPermission.allCases {
            stack.addArrangedSubview(permissionRow(perm))
        }

        // Background services
        stack.addArrangedSubview(sectionHeader("Background services"))
        stack.addArrangedSubview(servicesRow())

        // Feedback / bug report — natural Settings affordance for ⌃⇧F.
        stack.addArrangedSubview(sectionHeader("Help us improve"))
        stack.addArrangedSubview(feedbackRow())

        // Danger zone — full uninstall.
        stack.addArrangedSubview(sectionHeader("Danger zone"))
        stack.addArrangedSubview(dangerZoneRow())

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

    // MARK: - Plan & usage panel

    private func tierUsagePanel() -> NSView {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false

        // Top row: plan badge + wallet + top-up + manage button.
        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let plan = NSTextField(labelWithString: "—")
        plan.font = .systemFont(ofSize: 13, weight: .semibold)
        plan.maximumNumberOfLines = 1
        tierPlanLabel = plan
        topRow.addArrangedSubview(plan)

        let wallet = NSTextField(labelWithString: "")
        wallet.font = .systemFont(ofSize: 12)
        wallet.textColor = .secondaryLabelColor
        tierWalletLabel = wallet
        topRow.addArrangedSubview(wallet)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        topRow.addArrangedSubview(spacer)

        let topup = NSButton(
            title: "Top up",
            target: self,
            action: #selector(openBillingTopup)
        )
        topup.bezelStyle = .rounded
        topRow.addArrangedSubview(topup)

        let manage = NSButton(
            title: "Open billing",
            target: self,
            action: #selector(openBillingDashboard)
        )
        manage.bezelStyle = .rounded
        topRow.addArrangedSubview(manage)

        outer.addArrangedSubview(topRow)

        // Auto-topup toggle.
        let auto = NSButton(
            checkboxWithTitle: "Auto top-up $10 when wallet runs low",
            target: self,
            action: #selector(toggleAutoTopup(_:))
        )
        auto.font = .systemFont(ofSize: 11)
        tierAutoTopupCheckbox = auto
        outer.addArrangedSubview(auto)

        // Per-group usage bars container — populated on refresh.
        let bars = NSStackView()
        bars.orientation = .vertical
        bars.alignment = .leading
        bars.spacing = 6
        bars.translatesAutoresizingMaskIntoConstraints = false
        bars.widthAnchor.constraint(equalToConstant: 504).isActive = true
        tierBarsStack = bars
        outer.addArrangedSubview(bars)

        // Empty-state placeholder shown when signed out or no usage yet.
        let empty = NSTextField(labelWithString: "Sign in to see plan, usage, and wallet balance.")
        empty.font = .systemFont(ofSize: 11)
        empty.textColor = .secondaryLabelColor
        tierPanelEmptyLabel = empty
        outer.addArrangedSubview(empty)

        tierPanelContainer = outer
        return outer
    }

    private func refreshTierPanel() {
        // Throttle: at most once every 15s while the window is open.
        let now = Date().timeIntervalSince1970
        if now - lastMeFetchTs < 15.0 { return }
        lastMeFetchTs = now

        guard CloudAuth.shared.isSignedIn else {
            applyTierPanel(snapshot: nil)
            return
        }
        CloudClient.fetchMe { [weak self] snapshot in
            DispatchQueue.main.async { self?.applyTierPanel(snapshot: snapshot) }
        }
    }

    private func applyTierPanel(snapshot: CloudMeSnapshot?) {
        guard let plan = tierPlanLabel,
              let wallet = tierWalletLabel,
              let auto = tierAutoTopupCheckbox,
              let bars = tierBarsStack,
              let empty = tierPanelEmptyLabel else { return }

        bars.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let s = snapshot else {
            plan.stringValue = "—"
            wallet.stringValue = ""
            auto.state = .off
            auto.isEnabled = false
            empty.isHidden = false
            return
        }

        plan.stringValue = s.plan.capitalized
        let dollars = Double(s.walletCredits) / 100.0
        wallet.stringValue = String(format: "Wallet: %d cr ($%.2f)", s.walletCredits, dollars)
        auto.isEnabled = true
        auto.state = s.autoTopupEnabled ? .on : .off
        auto.title = s.autoTopupEnabled
            ? String(format: "Auto top-up $10 when wallet <  %d cr", s.autoTopupThresholdCredits)
            : "Auto top-up $10 when wallet runs low"

        if s.usagePanel.isEmpty {
            empty.stringValue = "No tier caps — Free / BYOK plan."
            empty.isHidden = false
        } else {
            empty.isHidden = true
            for row in s.usagePanel {
                bars.addArrangedSubview(makeUsageBar(row: row))
            }
        }
    }

    private func makeUsageBar(row: CloudUsagePanelRow) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 3
        container.translatesAutoresizingMaskIntoConstraints = false

        let head = NSStackView()
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 6

        let label = NSTextField(labelWithString: tierGroupLabel(row.group))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        head.addArrangedSubview(label)

        if !row.managedInCurrentRelease {
            let byok = NSTextField(labelWithString: "BYOK")
            byok.font = .systemFont(ofSize: 9, weight: .semibold)
            byok.textColor = .secondaryLabelColor
            head.addArrangedSubview(byok)
        }
        if row.overCap {
            let over = NSTextField(labelWithString: "OVER CAP · WALLET")
            over.font = .systemFont(ofSize: 9, weight: .semibold)
            over.textColor = .systemRed
            head.addArrangedSubview(over)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        head.addArrangedSubview(spacer)

        let amount = NSTextField(labelWithString: String(
            format: "%@ / %@",
            formatCanonical(value: row.currentCanonical, unit: row.displayUnit),
            formatCanonical(value: row.capCanonical, unit: row.displayUnit)
        ))
        amount.font = .systemFont(ofSize: 11)
        amount.textColor = .secondaryLabelColor
        head.addArrangedSubview(amount)
        container.addArrangedSubview(head)

        let bar = TierUsageBarView(percent: row.percent)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 504).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
        container.addArrangedSubview(bar)

        return container
    }

    private func tierGroupLabel(_ group: String) -> String {
        switch group {
        case "voice": return "Voice"
        case "phone": return "Phone"
        case "channel": return "Channels"
        case "image": return "Images"
        case "video": return "Video"
        case "tts": return "Speech (TTS)"
        case "skill": return "Skills"
        default: return group.capitalized
        }
    }

    private func formatCanonical(value: Double, unit: String) -> String {
        switch unit {
        case "hours":    return String(format: "%.1f hr", value)
        case "minutes":  return String(format: "%.0f min", value)
        case "messages": return String(format: "%.0f msgs", value)
        case "seconds":  return String(format: "%.0f s", value)
        case "images":   return String(format: "%.0f", value)
        case "runs":     return String(format: "%.0f", value)
        default:         return String(format: "%.0f %@", value, unit)
        }
    }

    @objc private func openBillingTopup() {
        if let url = URL(string: "https://sutando.ag2.ai/dashboard?topup=open") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openBillingDashboard() {
        if let url = URL(string: "https://sutando.ag2.ai/dashboard") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleAutoTopup(_ sender: NSButton) {
        // Optimistic: send the new state immediately; the next refresh
        // confirms it landed. Server validates the request itself.
        CloudClient.updateAutoTopup(enabled: sender.state == .on, thresholdCredits: nil)
        // Force a refresh on next poll tick.
        lastMeFetchTs = 0
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

    // 3 steps — background services start automatically with the app, so
    // the old 4th step ("Install Background Services") was removed.
    private static let stepNames = ["API key", "Claude Code", "Permissions"]

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

        return [apiKeyDone, claudeDone, permissionsDone]
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
            emitOnboardingOnce("claude_installed")
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

    private enum CLIDelegate {
        case codex
        case gemini

        var binaryName: String {
            switch self {
            case .codex: return "codex"
            case .gemini: return "gemini"
            }
        }
        var displayName: String {
            switch self {
            case .codex: return "Codex CLI"
            case .gemini: return "Gemini CLI"
            }
        }
        var docsURL: String {
            switch self {
            case .codex: return "https://github.com/openai/codex"
            case .gemini: return "https://github.com/google-gemini/gemini-cli"
            }
        }
        var description: String {
            switch self {
            case .codex: return "Used by /claude-codex and /claude-router for second-opinion code reviews and delegations."
            case .gemini: return "Used by /claude-gemini and /claude-router for large-context repo scans."
            }
        }
    }

    private func cliDelegateRow(_ tool: CLIDelegate) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let status = NSTextField(labelWithString: "Checking…")
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        status.cell?.wraps = true
        row.addArrangedSubview(status)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let button = NSButton(title: "…", target: self, action: nil)
        button.bezelStyle = .rounded
        button.identifier = .init(tool.docsURL)
        button.action = #selector(openHelpLink(_:))
        row.addArrangedSubview(button)

        switch tool {
        case .codex:
            codexStatusLabel = status
            codexActionButton = button
        case .gemini:
            geminiStatusLabel = status
            geminiActionButton = button
        }
        refreshCLIDelegateUI(tool)
        return row
    }

    /// Resolve the CLI on PATH or the same well-known locations checked by
    /// `claudeCodePath()`. Mirrors that function so both detection paths
    /// stay consistent.
    private func cliDelegatePath(_ binaryName: String) -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs.append(contentsOf: [
            NSHomeDirectory() + "/.local/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            NSHomeDirectory() + "/.npm-global/bin",
        ])
        for dir in dirs where !dir.isEmpty {
            let path = dir + "/" + binaryName
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func refreshCLIDelegateUI(_ tool: CLIDelegate) {
        let label: NSTextField?
        let button: NSButton?
        switch tool {
        case .codex:
            label = codexStatusLabel
            button = codexActionButton
        case .gemini:
            label = geminiStatusLabel
            button = geminiActionButton
        }
        if let path = cliDelegatePath(tool.binaryName) {
            let homeRel = path.hasPrefix(NSHomeDirectory())
                ? "~" + path.dropFirst(NSHomeDirectory().count)
                : path
            label?.stringValue = "\(tool.displayName) installed at \(homeRel)."
            label?.textColor = .labelColor
            button?.title = "Docs"
        } else {
            label?.stringValue = "\(tool.displayName) not installed. \(tool.description)"
            label?.textColor = .secondaryLabelColor
            button?.title = "Install instructions"
        }
    }

    private func servicesRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let status = NSTextField(labelWithString: "Checking…")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        status.preferredMaxLayoutWidth = 360
        servicesStatusLabel = status
        row.addArrangedSubview(status)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let restart = NSButton(title: "Restart", target: self, action: #selector(restartServicesFromSettings))
        restart.bezelStyle = .rounded
        row.addArrangedSubview(restart)
        refreshServicesUI()
        return row
    }

    /// Refresh the live "N/7 services running" string. Called on the
    /// 1.5s status-polling tick the rest of Settings already uses.
    private func refreshServicesUI() {
        guard let label = servicesStatusLabel else { return }
        DispatchQueue.global(qos: .utility).async {
            let count = LaunchAgentInstaller().loadedLabels().count
            DispatchQueue.main.async {
                let text: String
                let color: NSColor
                if count == 0 {
                    text = "Services are not running. Click Restart, or quit and reopen Sutando."
                    color = .systemOrange
                } else if count < 5 {
                    text = "\(count) services running — some may have failed. Click Restart."
                    color = .systemOrange
                } else {
                    text = "\(count) services running. Auto-managed: start with Sutando, stop on quit."
                    color = .secondaryLabelColor
                }
                label.stringValue = text
                label.textColor = color
            }
        }
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
            // Activation telemetry. The Gemini key is the single
            // gate-keeper checkpoint — without it nothing else can run.
            // Save also closes out first-run for the funnel.
            let geminiKey = env.value(for: SettingsField.GEMINI_API_KEY.rawValue) ?? ""
            if !geminiKey.isEmpty {
                emitOnboardingOnce("gemini_key_set")
            }
            emitOnboardingOnce("firstrun_complete")
            showBanner("Saved. Background services will pick up the new settings on next restart.", color: .systemGreen)
        } catch {
            showBanner("Failed to save: \(error.localizedDescription)", color: .systemRed)
        }
    }

    /// Emit an onboarding milestone exactly once per app launch.
    /// Server-side dedup is on (user_id, step) so retries are safe; this
    /// guard just avoids the HTTP round trip from the polling loop.
    private func emitOnboardingOnce(_ step: String) {
        if emittedOnboardingSteps.contains(step) { return }
        emittedOnboardingSteps.insert(step)
        CloudClient.recordOnboarding(step)
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
        if perm == .microphone {
            // Mic-only path: fire the AVCaptureDevice prompt FIRST so macOS
            // can register Sutando in the TCC database. Opening System
            // Settings before the prompt steals focus and macOS suppresses
            // prompts from non-frontmost apps — the result is that the user
            // sees an empty Microphone list and Sutando never gets added.
            // Only fall through to System Settings if the user denied.
            //
            // Sutando is LSUIElement (menu-bar app, no Dock icon). Apps in
            // .accessory activation policy can have their TCC prompts
            // silently dropped by macOS — the IPC fires but no UI surfaces.
            // Promoting to .regular for the duration of the prompt forces
            // macOS to treat Sutando like any other foreground app.
            let priorPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)

            perm.request { [weak self] status in
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(priorPolicy)
                    self?.updatePermissionUI()
                    if status != .granted, let url = perm.systemSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else {
            // Accessibility + Screen Recording: macOS doesn't show a useful
            // in-app prompt for these — the request just nudges the system
            // to add an entry. Opening Settings is the meaningful action,
            // so do it first.
            if let url = perm.systemSettingsURL { NSWorkspace.shared.open(url) }
            perm.request { [weak self] _ in self?.updatePermissionUI() }
        }
    }

    @objc private func restartServicesFromSettings() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let installer = LaunchAgentInstaller()
            _ = installer.stopAll()
            let paths = LaunchAgentInstaller.defaultPaths(workspace: appDelegate?.workspace ?? "")
            do {
                let summary = try installer.install(paths: paths)
                // Per-service failure → cloud reliability board. Lets us
                // catch regressions like the Phase 4-bug Disabled=true
                // crash before the next user hits it.
                for failure in summary.failed {
                    CloudClient.recordError(
                        kind: "launchd.bootstrap_fail",
                        severity: .error,
                        message: "\(failure.label): \(failure.message)",
                        metadata: ["label": failure.label]
                    )
                }
                DispatchQueue.main.async { [self] in
                    if summary.failed.isEmpty {
                        showBanner("Restarted \(summary.installed.count) services.", color: .systemGreen)
                        emitOnboardingOnce("services_installed")
                    } else {
                        let errs = summary.failed.map { "\($0.label): \($0.message)" }.joined(separator: "; ")
                        showBanner("Restarted \(summary.installed.count). Failed: \(errs)", color: .systemOrange)
                    }
                    refreshServicesUI()
                }
            } catch {
                CloudClient.recordError(
                    kind: "launchd.install_failed",
                    severity: .fatal,
                    message: error.localizedDescription
                )
                DispatchQueue.main.async { [self] in
                    showBanner("Restart failed: \(error.localizedDescription)", color: .systemRed)
                }
            }
        }
    }

    private func feedbackRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let info = NSTextField(labelWithString: "Report a bug, request a feature, or send a note. ⌃⇧F also opens this form.")
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        info.maximumNumberOfLines = 2
        info.lineBreakMode = .byWordWrapping
        info.preferredMaxLayoutWidth = 360
        row.addArrangedSubview(info)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let button = NSButton(title: "Report an issue…", target: self, action: #selector(openFeedbackFromSettings))
        button.bezelStyle = .rounded
        row.addArrangedSubview(button)
        return row
    }

    @objc private func openFeedbackFromSettings() {
        appDelegate?.openFeedbackForm(initialBody: "")
    }

    private func dangerZoneRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let info = NSTextField(labelWithString: "Remove Sutando completely from this Mac.")
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        row.addArrangedSubview(info)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let button = NSButton(title: "Uninstall Sutando…", target: self, action: #selector(uninstallApp))
        button.bezelStyle = .rounded
        button.hasDestructiveAction = true
        row.addArrangedSubview(button)
        return row
    }

    @objc private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Sutando?"
        alert.informativeText = """
            This removes the app, background services, caches, cloud sign-in, \
            and skill symlinks. The Privacy & Security entries (Microphone, \
            Screen Recording, Accessibility) will be reset, but you may need \
            to remove them from System Settings manually if any remain.
            """
        alert.alertStyle = .warning

        let keepData = NSButton(checkboxWithTitle: "Keep my settings and API keys", target: nil, action: nil)
        keepData.state = .on
        keepData.toolTip = "Preserve ~/Library/Application Support/Sutando (.env, results, notes). Useful if you plan to reinstall."
        let accessory = NSStackView(views: [keepData])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Uninstall and quit")
        alert.addButton(withTitle: "Cancel")
        // Make Cancel the default. The destructive button is buttons[0]
        // (Uninstall) — flagging it via .keyEquivalentModifierMask leaves
        // Return on Cancel.
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        showBanner("Uninstalling… Sutando will quit in a moment.", color: .systemOrange)
        let keep = keepData.state == .on
        Uninstaller.performUninstall(keepUserData: keep)
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
        refreshCLIDelegateUI(.codex)
        refreshCLIDelegateUI(.gemini)
        refreshStepperUI()
        refreshTierPanel()
        refreshServicesUI()
        // Refresh permission + cloud + Claude Code + stepper + services
        // status while the window is open so returning from System
        // Settings, a Terminal install, or a Restart click reflects the
        // new state.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self, let window = self.window, window.isVisible else {
                timer.invalidate()
                return
            }
            self.updatePermissionUI()
            self.updateCloudUI()
            self.refreshClaudeCodeUI()
            self.refreshCLIDelegateUI(.codex)
            self.refreshCLIDelegateUI(.gemini)
            self.refreshStepperUI()
            self.refreshServicesUI()
            // refreshTierPanel throttles internally to ~15s — safe to
            // call from the 1.5s tick.
            self.refreshTierPanel()
        }
    }

    private func updatePermissionUI() {
        var allGranted = true
        for perm in SystemPermission.allCases {
            let status = perm.status()
            if status != .granted { allGranted = false }
            if let label = permissionStatusLabels[perm] {
                label.stringValue = status.symbol
                label.textColor = status.color
            }
        }
        if allGranted {
            emitOnboardingOnce("perms_granted")
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

/// Custom NSView for the per-group usage bar. Pure draw — avoids the
/// heavier `NSProgressIndicator` for what's just a horizontal pill with
/// a tinted fill. Tone shifts from neutral → amber (>80%) → red (>100%)
/// so over-cap usage is glanceable.
final class TierUsageBarView: NSView {
    private let percent: Double
    init(percent: Double) {
        self.percent = percent
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
        track.fill()

        let clamped = max(0, min(100, percent))
        let fillRect = NSRect(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.width * CGFloat(clamped / 100.0),
            height: bounds.height
        )
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        let tone: NSColor
        if percent >= 100 { tone = .systemRed }
        else if percent >= 80 { tone = .systemOrange }
        else { tone = .controlAccentColor }
        tone.setFill()
        fill.fill()
    }
}
