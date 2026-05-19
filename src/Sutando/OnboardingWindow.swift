import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Security

// First-launch onboarding wizard.
//
// Five steps, gated so the main app (UnifiedMainWindow) never opens until
// the user has finished:
//
//   1. Welcome      — hero card, "Get started" button.
//   2. Gemini key   — text field, validated against
//                     generativelanguage.googleapis.com/v1beta/models.
//                     Persisted to $SUTANDO_HOME/.env via EnvFile.
//   3. Claude Code  — detect `claude` on disk; offer to run
//                     `curl -fsSL https://claude.ai/install.sh | bash`
//                     in-process if it isn't there.
//   4. Permissions  — Microphone (REQUIRED, blocks Continue) +
//                     Screen Recording (optional). Real prompts via
//                     AVCaptureDevice.requestAccess + CGRequestScreenCaptureAccess.
//   5. Services     — runs LaunchAgentInstaller().install(), shows
//                     N/M services running, then Done.
//
// Completion writes $SUTANDO_HOME/.onboarding-complete. AppDelegate
// checks `OnboardingWindowController.needsOnboarding` at launch and
// at every openUnifiedWindow() call — if true, this window is shown
// instead of the main UI.

private func sutandoHomePathForOnboarding() -> String {
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

private func onboardingEnvPath() -> String { sutandoHomePathForOnboarding() + "/.env" }
private func onboardingCompleteMarker() -> String { sutandoHomePathForOnboarding() + "/.onboarding-complete" }
/// Resume marker. Holds the index of the last step the user visited so
/// a restart-from-the-Permissions-step (Screen Recording TCC cache only
/// refreshes on relaunch) drops them back where they were instead of at
/// step 1. Cleaned up by `completeOnboarding()`.
private func onboardingStepMarker() -> String { sutandoHomePathForOnboarding() + "/.onboarding-step" }

/// Resolve the `claude` binary on PATH or in well-known install locations.
/// Mirrors `SettingsWindowController.claudeCodePath()` — kept as a free
/// function so the onboarding window doesn't have to reach into Settings.
private func resolveClaudeBinary() -> String? {
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

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    weak var appDelegate: AppDelegate?

    /// Called once when the user clicks "Done" on the final step. The
    /// AppDelegate uses this to kick off the bootstrap-and-open-WebUI
    /// flow that's normally part of `applicationDidFinishLaunching`.
    var onComplete: (() -> Void)?

    /// True until the user has completed every step at least once.
    /// AppDelegate consults this at launch and at every openUnifiedWindow
    /// call to decide whether to show the wizard instead of the main UI.
    static var needsOnboarding: Bool {
        !FileManager.default.fileExists(atPath: onboardingCompleteMarker())
    }

    /// Write the completion sentinel(s) without showing the wizard.
    /// `applicationDidFinishLaunching` calls this on first launch so
    /// the wizard never appears — the Settings panel's first-launch
    /// stepper (`SettingsWindowController.needsFirstLaunchSetup`)
    /// hosts the same Gemini-key / Claude CLI / permissions flow and
    /// runs in a window the user can close, dismiss, or come back to.
    /// The wizard was a launch-blocking modal that turned every
    /// transient failure in those flows into "the app won't open" for
    /// the user. Keeping the wizard code in-tree (rather than deleting
    /// it) means we can still wheel it out later if we decide the
    /// guided flow is worth the maintenance — but it's no longer on
    /// the cold-launch critical path.
    static func markCompleteSkippingWizard() {
        let marker = onboardingCompleteMarker()
        let dir = (marker as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: marker) {
            FileManager.default.createFile(atPath: marker, contents: Data())
        }
        // Resume marker from a partially-completed wizard run is no
        // longer meaningful once the wizard is bypassed — clean it up
        // so a future re-enable doesn't drop the user back into a
        // half-completed step.
        try? FileManager.default.removeItem(atPath: onboardingStepMarker())
    }

    // MARK: - Step state

    private enum Step: Int, CaseIterable {
        case welcome = 0
        case geminiKey
        case claudeCLI
        case permissions
        case services

        var title: String {
            switch self {
            case .welcome:     return "Welcome"
            case .geminiKey:   return "Gemini API key"
            case .claudeCLI:   return "Claude Code CLI"
            case .permissions: return "Permissions"
            case .services:    return "Background services"
            }
        }
    }

    private var currentStep: Step = .welcome

    // Per-step views. Built once, swapped in/out of `contentContainer`
    // so the wizard is a single window with no scroll/resize jitter.
    private var stepViews: [Step: NSView] = [:]
    private var contentContainer: NSView!
    private var stepperDots: [NSView] = []
    private var stepperLabels: [NSTextField] = []

    private var backButton: NSButton!
    private var continueButton: NSButton!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var statusBanner: NSTextField!

    // Step 2 — Connect Sutando (managed Gemini vs BYOK)
    private enum GeminiOnboardingMode { case managed, byok }
    private var geminiOnboardingMode: GeminiOnboardingMode = .managed
    private var geminiManagedRadio: NSButton!
    private var geminiBYOKRadio: NSButton!
    private var geminiManagedSection: NSView!
    private var geminiBYOKSection: NSView!
    // Managed sub-section
    private var managedSignInButton: NSButton!
    private var managedRefreshButton: NSButton!
    private var managedSignInSpinner: NSProgressIndicator!
    private var managedStatusLabel: NSTextField!
    private var managedCompCardContainer: NSView!
    private var managedCompLabel: NSTextField!
    private var managedSnapshot: CloudMeSnapshot?
    private var managedSnapshotInFlight = false
    private var managedModeSetInFlight = false
    // BYOK sub-section (existing)
    private var geminiKeyField: NSSecureTextField!
    private var geminiValidateButton: NSButton!
    private var geminiStatusLabel: NSTextField!
    private var geminiSpinner: NSProgressIndicator!
    private var geminiKeyValidated = false

    // Step 3 — Claude CLI
    private enum ClaudeState {
        case notInstalled
        case notSignedIn
        case signedIn
        case unknown
    }
    private var claudeState: ClaudeState = .unknown
    private var claudeStatusLabel: NSTextField!
    private var claudeActionButton: NSButton!
    private var claudeSpinner: NSProgressIndicator!
    private var claudeSkipButton: NSButton!
    private var claudeSkipped = false
    private var claudeAuthPollTimer: Timer?
    // Inline OAuth flow — `claude auth login --claudeai` prints a URL,
    // opens the browser, then waits on stdin for the code that the
    // post-OAuth landing page hands back. We pipe stdin/stdout so the
    // wizard hosts the whole flow without anyone touching Terminal.
    private var claudeAuthSignInPanel: NSStackView!
    private var claudeAuthURLField: NSTextField!
    private var claudeAuthCodeField: NSTextField!
    private var claudeAuthSubmitButton: NSButton!
    private var claudeAuthSpinner: NSProgressIndicator!
    private var claudeAuthStatusLabel: NSTextField!
    private var claudeAuthProcess: Process?
    private var claudeAuthStdin: FileHandle?
    private var claudeAuthURL: String?

    // Step 4 — Permissions
    private var micStatusLabel: NSTextField!
    private var micActionButton: NSButton!
    private var screenStatusLabel: NSTextField!
    private var screenActionButton: NSButton!
    private var screenRestartHint: NSTextField!
    private var permissionsTimer: Timer?
    /// Set when the user clicks Grant for Screen Recording. Used as the
    /// trigger for showing the "Restart Sutando" affordance — we only
    /// surface the restart hint after the user has actually attempted
    /// to grant, to avoid spooking users who haven't done anything yet.
    private var screenGrantClickedAt: Date?
    /// Last status we saw for Screen Recording. Used to detect a
    /// granted-→-revoked transition (user toggled Sutando off in
    /// System Settings) so we can clear `screenGrantClickedAt` and
    /// revert the button from "Restart Sutando" back to "Grant".
    /// Nil before the first refresh.
    private var lastSeenScreenStatus: SystemPermission.Status?

    // Step 5 — Services
    private var servicesStatusLabel: NSTextField!
    private var servicesActionButton: NSButton!
    private var servicesSpinner: NSProgressIndicator!
    private var servicesInstallStarted = false
    private var servicesInstalledCount = 0
    private var servicesTimer: Timer?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            // Intentionally no `.closable`: onboarding must complete or
            // the user quits via Cmd+Q. LSUIElement means no Dock icon
            // either — the only escape valves are Quit and finishing.
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Sutando"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.pageBackground
        window.center()
        window.setFrameAutosaveName("SutandoOnboardingWindow")
        super.init(window: window)
        window.delegate = self
        buildUI()
        // Resume from the step the user was last on (e.g. after a TCC
        // restart for Screen Recording). Falls back to Welcome on a
        // truly fresh install or any unparseable marker.
        let resumeStep: Step = Self.readResumeStep() ?? .welcome
        showStep(resumeStep)
        // On resume to the permissions step we DON'T pre-stamp
        // `screenGrantClickedAt`. The previous version did, on the
        // theory that the user must have just clicked Restart, which
        // forced the button into the "Restart Sutando" state on every
        // refresh — even when the live status check now correctly
        // reports `.granted`. Letting `refreshPermissionStatus` make
        // the call from the actual current status keeps the UI honest:
        // ✓ Granted if TCC saw the relaunch, otherwise back to "Grant".
        if resumeStep == .permissions {
            DispatchQueue.main.async { [weak self] in self?.refreshPermissionStatus() }
        }
    }

    /// Read the persisted step number (0–4) from the marker file; nil
    /// if no marker, file unreadable, or out-of-range.
    private static func readResumeStep() -> Step? {
        let path = onboardingStepMarker()
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Step(rawValue: n)
    }

    /// Save the current step so a relaunch (e.g. via the Screen Recording
    /// "Restart Sutando" button) lands the user back here instead of at
    /// Welcome. Best-effort — failure is silent because the worst case
    /// is "user starts the wizard from step 1 again".
    private func persistCurrentStep() {
        let path = onboardingStepMarker()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "\(currentStep.rawValue)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showAndFocus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Re-poll status when the window comes back to the front so
        // permissions granted via System Settings reflect immediately.
        refreshClaudeStatus()
        refreshPermissionStatus()
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let window = window, let contentView = window.contentView else { return }

        let bg = ThemedBackgroundView(frame: contentView.bounds)
        bg.themedBackgroundColor = Theme.pageBackground
        bg.autoresizingMask = [.width, .height]
        contentView.addSubview(bg)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 28, left: 36, bottom: 24, right: 36)
        root.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: bg.topAnchor),
            root.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])

        // Step indicator across the top.
        let stepper = buildStepper()
        root.addArrangedSubview(stepper)

        // Hero title + subtitle. Updated per step.
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor
        root.addArrangedSubview(titleLabel)

        subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.preferredMaxLayoutWidth = 648
        root.addArrangedSubview(subtitleLabel)

        // Status banner — surfaces validation errors / progress.
        statusBanner = NSTextField(labelWithString: "")
        statusBanner.font = .systemFont(ofSize: 12, weight: .medium)
        statusBanner.maximumNumberOfLines = 2
        statusBanner.lineBreakMode = .byWordWrapping
        statusBanner.preferredMaxLayoutWidth = 648
        statusBanner.isHidden = true
        root.addArrangedSubview(statusBanner)

        // Content container — holds whichever step view is active.
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.setContentHuggingPriority(.init(1), for: .vertical)
        root.addArrangedSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -72),
        ])

        // Pre-build every step's view once so swapping is instant and
        // the field editors keep their text.
        for step in Step.allCases {
            let view = makeStepView(step)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            contentContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                view.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor),
            ])
            stepViews[step] = view
        }

        // Footer — Back / Continue.
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.alignment = .centerY
        let leftSpacer = NSView()
        leftSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.addArrangedSubview(leftSpacer)

        backButton = NSButton(title: "Back", target: self, action: #selector(goBack))
        backButton.bezelStyle = .rounded
        footer.addArrangedSubview(backButton)

        continueButton = NSButton(title: "Continue", target: self, action: #selector(goForward))
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        footer.addArrangedSubview(continueButton)

        root.addArrangedSubview(footer)
    }

    private func buildStepper() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        for (i, step) in Step.allCases.enumerated() {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
            stepperDots.append(dot)
            row.addArrangedSubview(dot)

            let label = NSTextField(labelWithString: "\(i + 1). \(step.title)")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            stepperLabels.append(label)
            row.addArrangedSubview(label)

            if i < Step.allCases.count - 1 {
                let sep = NSTextField(labelWithString: "›")
                sep.font = .systemFont(ofSize: 12)
                sep.textColor = .tertiaryLabelColor
                row.addArrangedSubview(sep)
            }
        }
        return row
    }

    private func refreshStepper() {
        for (i, _) in Step.allCases.enumerated() {
            let dot = stepperDots[i]
            let label = stepperLabels[i]
            let isActive = i == currentStep.rawValue
            let isDone = i < currentStep.rawValue
            let color: NSColor
            if isDone { color = .systemGreen }
            else if isActive { color = .controlAccentColor }
            else { color = .tertiaryLabelColor }
            dot.layer?.backgroundColor = color.cgColor
            label.textColor = (isActive || isDone) ? .labelColor : .secondaryLabelColor
            label.font = .systemFont(
                ofSize: 11,
                weight: isActive ? .semibold : .medium
            )
        }
    }

    // MARK: - Step views

    private func makeStepView(_ step: Step) -> NSView {
        switch step {
        case .welcome:     return makeWelcomeView()
        case .geminiKey:   return makeGeminiKeyView()
        case .claudeCLI:   return makeClaudeCLIView()
        case .permissions: return makePermissionsView()
        case .services:    return makeServicesView()
        }
    }

    private func makeWelcomeView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let bullets = [
            ("Voice + screen", "Talk to Sutando, share what you're looking at, get answers."),
            ("Tasks anywhere", "Telegram, Discord, phone, and the menu bar all reach the same agent."),
            ("Lives on your Mac", "API keys and memory stay on disk under Application Support/Sutando."),
        ]
        for (title, body) in bullets {
            stack.addArrangedSubview(makeBullet(title: title, body: body))
        }
        return stack
    }

    private func makeBullet(title: String, body: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12

        let dot = NSTextField(labelWithString: "•")
        dot.font = .systemFont(ofSize: 18, weight: .bold)
        dot.textColor = .controlAccentColor
        row.addArrangedSubview(dot)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 14, weight: .semibold)
        text.addArrangedSubview(t)

        let b = NSTextField(labelWithString: body)
        b.font = .systemFont(ofSize: 12)
        b.textColor = .secondaryLabelColor
        b.maximumNumberOfLines = 2
        b.lineBreakMode = .byWordWrapping
        b.preferredMaxLayoutWidth = 580
        text.addArrangedSubview(b)

        row.addArrangedSubview(text)
        return row
    }

    private func makeGeminiKeyView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        // Mode chooser at the top — two radios.
        let chooser = makeGeminiModeChooserView()
        stack.addArrangedSubview(chooser)

        // Managed sub-section — sign in to claim 2 months of Max.
        let managed = makeManagedGeminiSection()
        geminiManagedSection = managed
        stack.addArrangedSubview(managed)

        // BYOK sub-section — paste a Gemini key. Old onboarding behavior.
        let byok = makeBYOKGeminiSection()
        geminiBYOKSection = byok
        stack.addArrangedSubview(byok)

        // Listen for sign-in callbacks. Step 2 fires CloudAuth.startSignIn();
        // the browser → sutando:// callback lands in CloudAuth.handle(url:)
        // which posts this notification on the main thread.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onboardingCloudSignedIn(_:)),
            name: .cloudAuthDidSignIn,
            object: nil
        )

        applyGeminiOnboardingMode()
        // If the user is already signed in (resumed onboarding or signed
        // in from the menu before reaching step 2), refresh the snapshot
        // so the comp card + Continue gate light up without a click.
        if CloudAuth.shared.isSignedIn {
            refreshManagedSnapshot()
        } else {
            applyManagedSnapshot(nil)
        }

        return stack
    }

    /// Header section: title + two radios. Radio change flips the mode and
    /// re-applies section visibility / Continue-button gate.
    private func makeGeminiModeChooserView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let managedRadio = NSButton(
            radioButtonWithTitle: "Sign in to Sutando — claim 2 months of Max free  (Recommended)",
            target: self,
            action: #selector(geminiOnboardingModeChanged(_:))
        )
        managedRadio.font = .systemFont(ofSize: 13, weight: .medium)
        managedRadio.tag = 0
        managedRadio.state = .on
        geminiManagedRadio = managedRadio
        stack.addArrangedSubview(managedRadio)

        let managedHint = NSTextField(labelWithString:
            "Beta users get 2 months of Max — voice, vision, image, video on us. We mint per-session Gemini Live tokens; no keys to manage."
        )
        managedHint.font = .systemFont(ofSize: 11)
        managedHint.textColor = .secondaryLabelColor
        managedHint.maximumNumberOfLines = 3
        managedHint.lineBreakMode = .byWordWrapping
        managedHint.preferredMaxLayoutWidth = 600
        let managedHintInset = NSStackView()
        managedHintInset.orientation = .horizontal
        managedHintInset.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        managedHintInset.addArrangedSubview(managedHint)
        stack.addArrangedSubview(managedHintInset)

        let byokRadio = NSButton(
            radioButtonWithTitle: "Bring my own Gemini key  (Free tier)",
            target: self,
            action: #selector(geminiOnboardingModeChanged(_:))
        )
        byokRadio.font = .systemFont(ofSize: 13, weight: .medium)
        byokRadio.tag = 1
        byokRadio.state = .off
        geminiBYOKRadio = byokRadio
        stack.addArrangedSubview(byokRadio)

        let byokHint = NSTextField(labelWithString:
            "Get a key from Google AI Studio. Stored locally on this Mac; voice connects direct to Google."
        )
        byokHint.font = .systemFont(ofSize: 11)
        byokHint.textColor = .secondaryLabelColor
        byokHint.maximumNumberOfLines = 2
        byokHint.lineBreakMode = .byWordWrapping
        byokHint.preferredMaxLayoutWidth = 600
        let byokHintInset = NSStackView()
        byokHintInset.orientation = .horizontal
        byokHintInset.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        byokHintInset.addArrangedSubview(byokHint)
        stack.addArrangedSubview(byokHintInset)

        return stack
    }

    /// The "Sign in to Sutando" section. Shows Sign-in button when signed
    /// out; comp card + green status when signed in with an active comp.
    private func makeManagedGeminiSection() -> NSView {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)

        // Comp card — hidden until the snapshot returns with comp.active.
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 4
        card.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        card.layer?.cornerRadius = 6
        card.isHidden = true
        managedCompCardContainer = card

        let compLabel = NSTextField(labelWithString: "")
        compLabel.font = .systemFont(ofSize: 12, weight: .medium)
        compLabel.maximumNumberOfLines = 2
        compLabel.lineBreakMode = .byWordWrapping
        compLabel.preferredMaxLayoutWidth = 580
        managedCompLabel = compLabel
        card.addArrangedSubview(compLabel)
        outer.addArrangedSubview(card)

        // Action row — sign-in button + refresh button + spinner.
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .centerY

        let signInButton = NSButton(
            title: "Sign in to Sutando",
            target: self,
            action: #selector(signInToSutando)
        )
        signInButton.bezelStyle = .rounded
        managedSignInButton = signInButton
        actionRow.addArrangedSubview(signInButton)

        let refresh = NSButton(
            title: "I've signed in — refresh",
            target: self,
            action: #selector(refreshManagedFromAction)
        )
        refresh.bezelStyle = .rounded
        refresh.isHidden = true
        managedRefreshButton = refresh
        actionRow.addArrangedSubview(refresh)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        managedSignInSpinner = spinner
        actionRow.addArrangedSubview(spinner)

        outer.addArrangedSubview(actionRow)

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.preferredMaxLayoutWidth = 600
        managedStatusLabel = status
        outer.addArrangedSubview(status)

        return outer
    }

    /// The BYOK section — identical to the pre-Wave-4.9 step 2 body, just
    /// extracted into its own view so the mode chooser can show/hide it.
    private func makeBYOKGeminiSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)

        let helpRow = NSStackView()
        helpRow.orientation = .horizontal
        helpRow.spacing = 8
        helpRow.alignment = .firstBaseline
        let helpLabel = NSTextField(labelWithString: "Sutando uses Gemini for voice + vision. The free tier is enough for normal use.")
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.maximumNumberOfLines = 2
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.preferredMaxLayoutWidth = 460
        helpRow.addArrangedSubview(helpLabel)

        let getKey = NSButton(title: "Get a free key →", target: self, action: #selector(openGeminiSignup))
        getKey.bezelStyle = .recessed
        getKey.font = .systemFont(ofSize: 11)
        helpRow.addArrangedSubview(getKey)
        stack.addArrangedSubview(helpRow)

        let label = NSTextField(labelWithString: "Gemini API key")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(label)

        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        inputRow.alignment = .centerY

        geminiKeyField = NSSecureTextField()
        geminiKeyField.placeholderString = "AIza…  (stored locally at ~/Library/Application Support/Sutando/.env)"
        geminiKeyField.translatesAutoresizingMaskIntoConstraints = false
        geminiKeyField.widthAnchor.constraint(equalToConstant: 480).isActive = true
        geminiKeyField.target = self
        geminiKeyField.action = #selector(geminiKeyChanged)
        // Re-evaluate on every keystroke so the Continue button enables
        // the moment a previously-validated key is restored after a typo.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(geminiKeyEditing(_:)),
            name: NSControl.textDidChangeNotification,
            object: geminiKeyField
        )
        inputRow.addArrangedSubview(geminiKeyField)

        geminiValidateButton = NSButton(title: "Validate", target: self, action: #selector(validateGeminiKey))
        geminiValidateButton.bezelStyle = .rounded
        inputRow.addArrangedSubview(geminiValidateButton)

        geminiSpinner = NSProgressIndicator()
        geminiSpinner.style = .spinning
        geminiSpinner.controlSize = .small
        geminiSpinner.isDisplayedWhenStopped = false
        geminiSpinner.translatesAutoresizingMaskIntoConstraints = false
        geminiSpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        geminiSpinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        inputRow.addArrangedSubview(geminiSpinner)

        stack.addArrangedSubview(inputRow)

        geminiStatusLabel = NSTextField(labelWithString: "")
        geminiStatusLabel.font = .systemFont(ofSize: 11)
        geminiStatusLabel.textColor = .secondaryLabelColor
        geminiStatusLabel.maximumNumberOfLines = 2
        geminiStatusLabel.lineBreakMode = .byWordWrapping
        geminiStatusLabel.preferredMaxLayoutWidth = 580
        stack.addArrangedSubview(geminiStatusLabel)

        // Pre-fill from disk so re-entering the wizard after a quit
        // shows the previously-saved key. The field is masked anyway.
        let existing = EnvFile.at(onboardingEnvPath()).value(for: "GEMINI_API_KEY") ?? ""
        if !existing.isEmpty {
            geminiKeyField.stringValue = existing
            geminiKeyValidated = true
            geminiStatusLabel.stringValue = "Found a saved key. Click Validate to re-check, or continue."
            geminiStatusLabel.textColor = .secondaryLabelColor
        }

        return stack
    }

    // MARK: - Step 2 mode chooser actions

    @objc private func geminiOnboardingModeChanged(_ sender: NSButton) {
        geminiOnboardingMode = (sender.tag == 1) ? .byok : .managed
        applyGeminiOnboardingMode()
        updateContinueButton()
    }

    private func applyGeminiOnboardingMode() {
        switch geminiOnboardingMode {
        case .managed:
            geminiManagedRadio?.state = .on
            geminiBYOKRadio?.state = .off
            geminiManagedSection?.isHidden = false
            geminiBYOKSection?.isHidden = true
        case .byok:
            geminiManagedRadio?.state = .off
            geminiBYOKRadio?.state = .on
            geminiManagedSection?.isHidden = true
            geminiBYOKSection?.isHidden = false
        }
    }

    @objc private func signInToSutando() {
        managedSignInButton?.isEnabled = false
        managedSignInSpinner?.startAnimation(nil)
        managedStatusLabel?.stringValue = "Opening browser… approve sign-in there, then come back."
        managedStatusLabel?.textColor = .secondaryLabelColor
        managedRefreshButton?.isHidden = false
        _ = CloudAuth.shared.startSignIn()
    }

    @objc private func refreshManagedFromAction() {
        refreshManagedSnapshot()
    }

    /// Fired by CloudAuth on a successful sutando:// callback. Auto-refresh
    /// the snapshot so the comp card + Continue gate light up immediately,
    /// no manual poll-button click required.
    @objc private func onboardingCloudSignedIn(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshManagedSnapshot()
        }
    }

    private func refreshManagedSnapshot() {
        if managedSnapshotInFlight { return }
        guard CloudAuth.shared.isSignedIn else {
            applyManagedSnapshot(nil)
            return
        }
        managedSnapshotInFlight = true
        managedSignInSpinner?.startAnimation(nil)
        CloudClient.fetchMe { [weak self] snap in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.managedSnapshotInFlight = false
                self.managedSignInSpinner?.stopAnimation(nil)
                self.applyManagedSnapshot(snap)
            }
        }
    }

    private func applyManagedSnapshot(_ snap: CloudMeSnapshot?) {
        managedSnapshot = snap

        guard let s = snap else {
            // Not signed in (or fetch failed).
            managedCompCardContainer?.isHidden = true
            managedSignInButton?.title = "Sign in to Sutando"
            managedSignInButton?.isEnabled = true
            managedRefreshButton?.isHidden = true
            if CloudAuth.shared.isSignedIn {
                managedStatusLabel?.stringValue = "Couldn't load your account just now. Click \"I've signed in — refresh\" or check your connection."
                managedStatusLabel?.textColor = .systemOrange
                managedRefreshButton?.isHidden = false
            } else {
                managedStatusLabel?.stringValue = "Not signed in yet. We'll open the browser and finish on this Mac."
                managedStatusLabel?.textColor = .secondaryLabelColor
            }
            updateContinueButton()
            return
        }

        // Signed-in. Decide UX from comp + effectivePlan.
        managedSignInButton?.title = "Signed in"
        managedSignInButton?.isEnabled = false
        managedRefreshButton?.isHidden = true

        if let comp = s.comp, comp.active {
            let endsAt = String(comp.endsAt.prefix(10))
            managedCompLabel?.stringValue = String(
                format: "🎁 Beta gift unlocked — %@ tier through %@ (%d days). %d cr/mo grant.",
                comp.plan.capitalized,
                endsAt,
                comp.daysRemaining,
                comp.monthlyCreditGrant
            )
            managedCompCardContainer?.isHidden = false
            managedStatusLabel?.stringValue = "Click Continue and we'll switch you to managed Gemini."
            managedStatusLabel?.textColor = .systemGreen
        } else {
            let effective = (s.effectivePlan ?? s.plan).lowercased()
            if effective != "free" {
                managedCompCardContainer?.isHidden = true
                managedStatusLabel?.stringValue = String(
                    format: "Signed in on the %@ plan. Click Continue to use managed Gemini.",
                    effective.capitalized
                )
                managedStatusLabel?.textColor = .systemGreen
            } else {
                managedCompCardContainer?.isHidden = true
                managedStatusLabel?.stringValue = "Signed in, but your beta application isn't approved yet. Switch to \"Bring my own Gemini key\" to keep going, or wait for the approval email."
                managedStatusLabel?.textColor = .systemOrange
            }
        }
        updateContinueButton()
    }

    /// True if managed mode is currently viable for advancing past step 2.
    /// Requires sign-in AND a non-free effective plan (comp counts).
    private func managedReadyToProceed() -> Bool {
        guard CloudAuth.shared.isSignedIn, let s = managedSnapshot else { return false }
        if s.comp?.active == true { return true }
        let effective = (s.effectivePlan ?? s.plan).lowercased()
        return effective != "free"
    }

    private func makeClaudeCLIView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let blurb = NSTextField(labelWithString: "Sutando's core agent runs on Claude Code (the `claude` CLI). It's a one-time install + sign-in — Anthropic's terms don't allow us to bundle it inside the app.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor
        blurb.maximumNumberOfLines = 3
        blurb.lineBreakMode = .byWordWrapping
        blurb.preferredMaxLayoutWidth = 600
        stack.addArrangedSubview(blurb)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        claudeStatusLabel = NSTextField(labelWithString: "Checking…")
        claudeStatusLabel.font = .systemFont(ofSize: 12)
        claudeStatusLabel.maximumNumberOfLines = 2
        claudeStatusLabel.lineBreakMode = .byWordWrapping
        claudeStatusLabel.preferredMaxLayoutWidth = 460
        row.addArrangedSubview(claudeStatusLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        claudeSpinner = NSProgressIndicator()
        claudeSpinner.style = .spinning
        claudeSpinner.controlSize = .small
        claudeSpinner.isDisplayedWhenStopped = false
        claudeSpinner.translatesAutoresizingMaskIntoConstraints = false
        claudeSpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        claudeSpinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        row.addArrangedSubview(claudeSpinner)

        claudeActionButton = NSButton(title: "Install", target: self, action: #selector(claudePrimaryAction))
        claudeActionButton.bezelStyle = .rounded
        row.addArrangedSubview(claudeActionButton)

        stack.addArrangedSubview(row)

        let footnote = NSTextField(labelWithString: "Install runs `curl -fsSL https://claude.ai/install.sh | bash`. Sign-in opens a short browser flow via `claude auth login`.")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor
        footnote.maximumNumberOfLines = 3
        footnote.lineBreakMode = .byWordWrapping
        footnote.preferredMaxLayoutWidth = 600
        stack.addArrangedSubview(footnote)

        // Subtle escape hatch — power users who already plan to sign in
        // through Settings later (or who want to use Sutando's cloud-only
        // features without the CLI) can bypass the sign-in gate. Using a
        // recessed button instead of a checkbox to keep it visually quiet.
        let skipRow = NSStackView()
        skipRow.orientation = .horizontal
        skipRow.spacing = 4
        skipRow.alignment = .centerY
        let skipNote = NSTextField(labelWithString: "Don't have a Claude subscription handy?")
        skipNote.font = .systemFont(ofSize: 11)
        skipNote.textColor = .tertiaryLabelColor
        skipRow.addArrangedSubview(skipNote)

        claudeSkipButton = NSButton(title: "Skip and finish later",
                                    target: self,
                                    action: #selector(skipClaudeSignIn))
        claudeSkipButton.bezelStyle = .recessed
        claudeSkipButton.font = .systemFont(ofSize: 11)
        skipRow.addArrangedSubview(claudeSkipButton)
        stack.addArrangedSubview(skipRow)

        // Inline OAuth panel — hidden until the user clicks Sign in.
        // Hosts the URL Sutando opens in the browser plus the paste-code
        // field that `claude auth login` waits on.
        let panel = makeClaudeAuthPanel()
        panel.isHidden = true
        claudeAuthSignInPanel = panel
        stack.addArrangedSubview(panel)

        return stack
    }

    private func makeClaudeAuthPanel() -> NSStackView {
        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 10
        panel.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.cardBackground.cgColor
        panel.layer?.cornerRadius = 8
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Theme.separator.cgColor

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY
        let title = NSTextField(labelWithString: "Sign in to Claude Code")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        header.addArrangedSubview(title)
        let spacer1 = NSView()
        spacer1.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(spacer1)
        claudeAuthSpinner = NSProgressIndicator()
        claudeAuthSpinner.style = .spinning
        claudeAuthSpinner.controlSize = .small
        claudeAuthSpinner.isDisplayedWhenStopped = false
        claudeAuthSpinner.translatesAutoresizingMaskIntoConstraints = false
        claudeAuthSpinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        claudeAuthSpinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
        header.addArrangedSubview(claudeAuthSpinner)
        let cancel = NSButton(title: "Cancel",
                              target: self,
                              action: #selector(cancelClaudeAuth))
        cancel.bezelStyle = .recessed
        cancel.font = .systemFont(ofSize: 11)
        header.addArrangedSubview(cancel)
        panel.addArrangedSubview(header)

        let step1 = NSTextField(labelWithString:
            "1. We've opened claude.com in your browser. Sign in with your Anthropic / Claude account.")
        step1.font = .systemFont(ofSize: 12)
        step1.textColor = .secondaryLabelColor
        step1.maximumNumberOfLines = 2
        step1.lineBreakMode = .byWordWrapping
        step1.preferredMaxLayoutWidth = 580
        panel.addArrangedSubview(step1)

        // Important — call out the manual paste step. Users overwhelmingly
        // miss this on their first OAuth-via-CLI experience: they sign in,
        // see "Authorization successful" on the redirect page, and come
        // back expecting the app to know. The whole flow hinges on copying
        // the code that the redirect page shows.
        let calloutBox = NSStackView()
        calloutBox.orientation = .horizontal
        calloutBox.spacing = 10
        calloutBox.alignment = .top
        calloutBox.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        calloutBox.wantsLayer = true
        calloutBox.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.12).cgColor
        calloutBox.layer?.cornerRadius = 6
        let warnIcon = NSTextField(labelWithString: "⚠")
        warnIcon.font = .systemFont(ofSize: 14, weight: .bold)
        warnIcon.textColor = .systemOrange
        calloutBox.addArrangedSubview(warnIcon)
        let calloutText = NSTextField(labelWithString:
            "Don't close the browser tab! After you sign in, the page will show you an authorization code. Copy it from there and paste below — Sutando can't see what's on the page.")
        calloutText.font = .systemFont(ofSize: 12)
        calloutText.textColor = .labelColor
        calloutText.maximumNumberOfLines = 4
        calloutText.lineBreakMode = .byWordWrapping
        calloutText.preferredMaxLayoutWidth = 540
        calloutBox.addArrangedSubview(calloutText)
        panel.addArrangedSubview(calloutBox)

        let urlRow = NSStackView()
        urlRow.orientation = .horizontal
        urlRow.spacing = 8
        urlRow.alignment = .centerY
        claudeAuthURLField = NSTextField(string: "")
        claudeAuthURLField.font = .systemFont(ofSize: 11)
        claudeAuthURLField.textColor = .secondaryLabelColor
        claudeAuthURLField.isBordered = false
        claudeAuthURLField.isEditable = false
        claudeAuthURLField.isSelectable = true
        claudeAuthURLField.drawsBackground = false
        claudeAuthURLField.usesSingleLineMode = true
        claudeAuthURLField.cell?.lineBreakMode = .byTruncatingTail
        claudeAuthURLField.translatesAutoresizingMaskIntoConstraints = false
        claudeAuthURLField.widthAnchor.constraint(equalToConstant: 460).isActive = true
        urlRow.addArrangedSubview(claudeAuthURLField)
        let openAgain = NSButton(title: "Open browser",
                                 target: self,
                                 action: #selector(reopenClaudeAuthURL))
        openAgain.bezelStyle = .recessed
        openAgain.font = .systemFont(ofSize: 11)
        urlRow.addArrangedSubview(openAgain)
        let copyURL = NSButton(title: "Copy",
                               target: self,
                               action: #selector(copyClaudeAuthURL))
        copyURL.bezelStyle = .recessed
        copyURL.font = .systemFont(ofSize: 11)
        urlRow.addArrangedSubview(copyURL)
        panel.addArrangedSubview(urlRow)

        let step2 = NSTextField(labelWithString:
            "2. After signing in, copy the authorization code the page shows you and paste it here:")
        step2.font = .systemFont(ofSize: 12)
        step2.textColor = .secondaryLabelColor
        step2.maximumNumberOfLines = 2
        step2.lineBreakMode = .byWordWrapping
        step2.preferredMaxLayoutWidth = 580
        panel.addArrangedSubview(step2)

        let codeRow = NSStackView()
        codeRow.orientation = .horizontal
        codeRow.spacing = 8
        codeRow.alignment = .centerY
        claudeAuthCodeField = NSTextField()
        claudeAuthCodeField.placeholderString = "paste authorization code"
        claudeAuthCodeField.translatesAutoresizingMaskIntoConstraints = false
        claudeAuthCodeField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        claudeAuthCodeField.target = self
        claudeAuthCodeField.action = #selector(submitClaudeAuthCode)
        codeRow.addArrangedSubview(claudeAuthCodeField)
        claudeAuthSubmitButton = NSButton(title: "Submit",
                                          target: self,
                                          action: #selector(submitClaudeAuthCode))
        claudeAuthSubmitButton.bezelStyle = .rounded
        claudeAuthSubmitButton.keyEquivalent = "\r"
        codeRow.addArrangedSubview(claudeAuthSubmitButton)
        panel.addArrangedSubview(codeRow)

        claudeAuthStatusLabel = NSTextField(labelWithString: "")
        claudeAuthStatusLabel.font = .systemFont(ofSize: 11)
        claudeAuthStatusLabel.textColor = .secondaryLabelColor
        claudeAuthStatusLabel.maximumNumberOfLines = 2
        claudeAuthStatusLabel.lineBreakMode = .byWordWrapping
        claudeAuthStatusLabel.preferredMaxLayoutWidth = 580
        panel.addArrangedSubview(claudeAuthStatusLabel)

        // Per-row width constraint so the panel renders as a card flush
        // with the rest of the step content (no autoresizing surprises).
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 600).isActive = true

        return panel
    }

    private func makePermissionsView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let blurb = NSTextField(labelWithString: "macOS asks for these the first time the app needs them. Granting now means everything works on first use.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor
        blurb.maximumNumberOfLines = 2
        blurb.lineBreakMode = .byWordWrapping
        blurb.preferredMaxLayoutWidth = 600
        stack.addArrangedSubview(blurb)

        // Microphone — required.
        let micRow = makePermissionRow(
            title: "Microphone",
            requirement: "Required",
            requirementColor: .systemRed,
            body: "Used by the voice agent. Without it, conversation doesn't work.",
            statusOut: { [weak self] in self?.micStatusLabel = $0 },
            buttonOut: { [weak self] in self?.micActionButton = $0 },
            action: #selector(grantMicrophone)
        )
        stack.addArrangedSubview(micRow)

        // Screen Recording — optional.
        let screenRow = makePermissionRow(
            title: "Screen Recording",
            requirement: "Optional",
            requirementColor: .secondaryLabelColor,
            body: "Lets Sutando see what you're looking at when you ask. You can grant this later from Settings.",
            statusOut: { [weak self] in self?.screenStatusLabel = $0 },
            buttonOut: { [weak self] in self?.screenActionButton = $0 },
            action: #selector(grantScreenRecording)
        )
        stack.addArrangedSubview(screenRow)

        // Screen Recording restart hint. macOS's TCC daemon caches the
        // CGPreflightScreenCaptureAccess() result per-process at launch;
        // toggling the permission in System Settings updates the daemon's
        // grant table but does NOT refresh our cached value until the
        // process restarts. So once the user has clicked Grant, we
        // surface this banner explaining the restart requirement (with
        // a one-click restart that resumes back at this step).
        screenRestartHint = NSTextField(labelWithString:
            "Tip: macOS only applies Screen Recording grants after the app restarts. " +
            "If the row stays orange after toggling Sutando in System Settings, click " +
            "Restart Sutando below — we'll pick up where you left off.")
        screenRestartHint.font = .systemFont(ofSize: 11)
        screenRestartHint.textColor = .secondaryLabelColor
        screenRestartHint.maximumNumberOfLines = 4
        screenRestartHint.lineBreakMode = .byWordWrapping
        screenRestartHint.preferredMaxLayoutWidth = 600
        screenRestartHint.isHidden = true
        stack.addArrangedSubview(screenRestartHint)

        return stack
    }

    private func makePermissionRow(
        title: String,
        requirement: String,
        requirementColor: NSColor,
        body: String,
        statusOut: (NSTextField) -> Void,
        buttonOut: (NSButton) -> Void,
        action: Selector
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let status = NSTextField(labelWithString: "○")
        status.font = .systemFont(ofSize: 16, weight: .bold)
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 22).isActive = true
        statusOut(status)
        row.addArrangedSubview(status)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 14, weight: .semibold)
        titleRow.addArrangedSubview(t)
        let req = NSTextField(labelWithString: requirement)
        req.font = .systemFont(ofSize: 11, weight: .medium)
        req.textColor = requirementColor
        titleRow.addArrangedSubview(req)
        textStack.addArrangedSubview(titleRow)

        let b = NSTextField(labelWithString: body)
        b.font = .systemFont(ofSize: 12)
        b.textColor = .secondaryLabelColor
        b.maximumNumberOfLines = 2
        b.lineBreakMode = .byWordWrapping
        b.preferredMaxLayoutWidth = 460
        textStack.addArrangedSubview(b)

        row.addArrangedSubview(textStack)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let button = NSButton(title: "Grant", target: self, action: action)
        button.bezelStyle = .rounded
        buttonOut(button)
        row.addArrangedSubview(button)

        return row
    }

    private func makeServicesView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let blurb = NSTextField(labelWithString: "Sutando runs a handful of background services (voice, dashboard, task bridges) under launchd. They start with the app and stop when you quit. Click Install to set them up.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor
        blurb.maximumNumberOfLines = 3
        blurb.lineBreakMode = .byWordWrapping
        blurb.preferredMaxLayoutWidth = 600
        stack.addArrangedSubview(blurb)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        servicesStatusLabel = NSTextField(labelWithString: "Not installed yet.")
        servicesStatusLabel.font = .systemFont(ofSize: 12)
        servicesStatusLabel.maximumNumberOfLines = 2
        servicesStatusLabel.lineBreakMode = .byWordWrapping
        servicesStatusLabel.preferredMaxLayoutWidth = 460
        row.addArrangedSubview(servicesStatusLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        servicesSpinner = NSProgressIndicator()
        servicesSpinner.style = .spinning
        servicesSpinner.controlSize = .small
        servicesSpinner.isDisplayedWhenStopped = false
        servicesSpinner.translatesAutoresizingMaskIntoConstraints = false
        servicesSpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        servicesSpinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        row.addArrangedSubview(servicesSpinner)

        servicesActionButton = NSButton(title: "Install services", target: self, action: #selector(installServices))
        servicesActionButton.bezelStyle = .rounded
        row.addArrangedSubview(servicesActionButton)
        stack.addArrangedSubview(row)

        return stack
    }

    // MARK: - Step navigation

    private func showStep(_ step: Step) {
        currentStep = step
        for (s, v) in stepViews { v.isHidden = (s != step) }
        statusBanner.isHidden = true

        switch step {
        case .welcome:
            titleLabel.stringValue = "Welcome to Sutando"
            subtitleLabel.stringValue = "Your personal AI agent. A few quick steps and you're ready."
        case .geminiKey:
            titleLabel.stringValue = "Connect Sutando"
            subtitleLabel.stringValue = "Sign in for managed Gemini (2 months free for beta users), or bring your own Gemini key."
        case .claudeCLI:
            titleLabel.stringValue = "Install Claude Code"
            subtitleLabel.stringValue = "Powers the core agent that does the work behind your tasks."
            refreshClaudeStatus()
        case .permissions:
            titleLabel.stringValue = "Grant system access"
            subtitleLabel.stringValue = "Microphone is required. Screen Recording is optional but recommended."
            refreshPermissionStatus()
            startPermissionsPolling()
        case .services:
            titleLabel.stringValue = "Start background services"
            subtitleLabel.stringValue = "Sutando registers a few launchd jobs so the voice + task bridges run on demand."
        }
        if step != .permissions { stopPermissionsPolling() }
        if step != .services { stopServicesPolling() }
        if step != .claudeCLI {
            stopClaudeAuthPolling()
            // Tear down any in-flight `claude auth login` so navigating
            // away doesn't leave an orphaned subprocess waiting on stdin.
            if claudeAuthProcess != nil {
                cancelClaudeAuth()
            }
        }

        backButton.isHidden = (step == .welcome)
        updateContinueButton()
        refreshStepper()
        persistCurrentStep()
    }

    /// Disable Continue when the current step's prerequisites aren't met.
    /// Called every time a step's state changes (validation result,
    /// permission grant, install completion).
    private func updateContinueButton() {
        switch currentStep {
        case .welcome:
            continueButton.title = "Get started"
            continueButton.isEnabled = true
        case .geminiKey:
            continueButton.title = "Continue"
            switch geminiOnboardingMode {
            case .managed:
                continueButton.isEnabled = managedReadyToProceed() && !managedModeSetInFlight
            case .byok:
                // Allow continue if the user has a non-empty key AND has
                // either validated it this session or is using a saved key.
                let hasKey = !geminiKeyField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
                continueButton.isEnabled = hasKey && geminiKeyValidated
            }
        case .claudeCLI:
            continueButton.title = "Continue"
            // Sign-in is the strong gate. The "Skip and finish later"
            // escape hatch downgrades to install-only (claudeSkipped),
            // since the agent literally can't boot without the binary.
            let installed = (resolveClaudeBinary() != nil)
            let unblocked = (claudeState == .signedIn) || (claudeSkipped && installed)
            continueButton.isEnabled = unblocked
        case .permissions:
            continueButton.title = "Continue"
            // Only mic is required.
            continueButton.isEnabled = (SystemPermission.microphone.status() == .granted)
        case .services:
            continueButton.title = servicesInstalledCount > 0 ? "Done" : "Install services"
            continueButton.isEnabled = true
        }
    }

    @objc private func goBack() {
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
        showStep(prev)
    }

    @objc private func goForward() {
        switch currentStep {
        case .geminiKey:
            // Managed-mode users get a server-side `geminiMode='managed'` PATCH
            // before we advance, so the voice agent's first session starts in
            // managed mode without waiting for a Settings toggle. BYOK users
            // skip the PATCH entirely (default mode is already 'byok').
            if geminiOnboardingMode == .managed && managedReadyToProceed() {
                advanceManagedAfterPatch()
                return
            }
            if let next = Step(rawValue: currentStep.rawValue + 1) {
                showStep(next)
            }
        case .welcome, .claudeCLI, .permissions:
            if let next = Step(rawValue: currentStep.rawValue + 1) {
                showStep(next)
            }
        case .services:
            if servicesInstalledCount > 0 {
                completeOnboarding()
            } else {
                installServices()
            }
        }
    }

    private func advanceManagedAfterPatch() {
        managedModeSetInFlight = true
        managedSignInSpinner?.startAnimation(nil)
        managedStatusLabel?.stringValue = "Enabling managed Gemini…"
        managedStatusLabel?.textColor = .secondaryLabelColor
        updateContinueButton()
        CloudClient.setGeminiMode("managed") { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.managedModeSetInFlight = false
                self.managedSignInSpinner?.stopAnimation(nil)
                switch result {
                case .ok:
                    if let next = Step(rawValue: self.currentStep.rawValue + 1) {
                        self.showStep(next)
                    }
                case .requiresPaid:
                    // Shouldn't happen if managedReadyToProceed() passed, but
                    // be defensive — keep them on step 2 and explain.
                    self.managedStatusLabel?.stringValue = "Server says managed mode requires a paid plan. Switch to BYOK to continue."
                    self.managedStatusLabel?.textColor = .systemOrange
                    self.updateContinueButton()
                case .failure(let detail):
                    self.managedStatusLabel?.stringValue = "Couldn't enable managed mode: \(detail). Try again or switch to BYOK."
                    self.managedStatusLabel?.textColor = .systemRed
                    self.updateContinueButton()
                }
            }
        }
    }

    // MARK: - Step 2: Gemini key actions

    @objc private func openGeminiSignup() {
        if let url = URL(string: "https://aistudio.google.com/app/apikey") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func geminiKeyChanged() {
        geminiKeyValidated = false
        geminiStatusLabel.stringValue = ""
        updateContinueButton()
    }

    @objc private func geminiKeyEditing(_ note: Notification) {
        geminiKeyValidated = false
        updateContinueButton()
    }

    @objc private func validateGeminiKey() {
        let key = geminiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            showBanner("Paste your Gemini API key first.", color: .systemOrange)
            return
        }

        geminiValidateButton.isEnabled = false
        geminiSpinner.startAnimation(nil)
        geminiStatusLabel.stringValue = "Validating…"
        geminiStatusLabel.textColor = .secondaryLabelColor

        // Hit the official models endpoint. 200 = key is valid; 400 with
        // "API_KEY_INVALID" means the key is junk; anything else is a
        // network or upstream issue. We trust the binary signal because
        // a Sutando user without a working key gets a worse failure
        // mode (blank voice agent that hangs on first message) than a
        // 30s validation hop here.
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.geminiSpinner.stopAnimation(nil)
                self.geminiValidateButton.isEnabled = true
                if let error = error {
                    self.geminiStatusLabel.stringValue = "Network error: \(error.localizedDescription)"
                    self.geminiStatusLabel.textColor = .systemRed
                    self.geminiKeyValidated = false
                    self.updateContinueButton()
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    if self.persistGeminiKey(key) {
                        self.geminiKeyValidated = true
                        self.geminiStatusLabel.stringValue = "✓ Valid key. Saved to ~/Library/Application Support/Sutando/.env."
                        self.geminiStatusLabel.textColor = .systemGreen
                    } else {
                        self.geminiKeyValidated = false
                        self.geminiStatusLabel.stringValue = "Key validated but failed to write .env. Check permissions on ~/Library/Application Support/Sutando."
                        self.geminiStatusLabel.textColor = .systemRed
                    }
                } else {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let snippet = body.split(separator: "\n").first.map(String.init) ?? ""
                    self.geminiKeyValidated = false
                    if status == 400 || status == 403 {
                        self.geminiStatusLabel.stringValue = "Key rejected (HTTP \(status)). Double-check you copied the whole key."
                    } else {
                        self.geminiStatusLabel.stringValue = "Validation failed (HTTP \(status)). \(snippet.prefix(180))"
                    }
                    self.geminiStatusLabel.textColor = .systemRed
                }
                self.updateContinueButton()
            }
        }.resume()
    }

    private func persistGeminiKey(_ key: String) -> Bool {
        let path = onboardingEnvPath()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var env = EnvFile.at(path)
        env.set("GEMINI_API_KEY", key)
        do {
            try env.write(to: path, mode: 0o600)
            return true
        } catch {
            NSLog("OnboardingWindow: persistGeminiKey failed: \(error)")
            return false
        }
    }

    // MARK: - Step 3: Claude CLI actions

    /// Probe Claude Code's install + sign-in state.
    ///
    /// We intentionally don't trust `claude auth status` alone. When
    /// `claude` is spawned as a child of Sutando.app, the macOS keychain
    /// ACL on the `Claude Code-credentials` entry can silently deny the
    /// keychain read because the binary's caller-context doesn't match
    /// the one the entry was created under (Terminal / a previous build).
    /// In that case the CLI honestly reports `loggedIn: false` even
    /// though the OAuth token is sitting right there in the keychain.
    ///
    /// To get out of that pit, after the CLI says "not signed in" we
    /// look directly at the `Claude Code-credentials` generic-password
    /// item via the Security framework. Querying *metadata only* (no
    /// `kSecReturnData`) doesn't trigger the ACL prompt and works
    /// regardless of caller context, so the existence + expiry of the
    /// entry are reliable signals on their own.
    private func probeClaudeState(_ done: @escaping (ClaudeState) -> Void) {
        guard let path = resolveClaudeBinary() else {
            done(.notInstalled)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["auth", "status"]
            // Strip TTY: the CLI prints a legacy "Not logged in · /login"
            // banner to stderr when stdin looks like a terminal.
            proc.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                DispatchQueue.main.async { done(.notInstalled) }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            let cliSignedIn = out.contains("\"loggedIn\"") && out.contains("\"loggedIn\":true")
                && proc.terminationStatus == 0
            if cliSignedIn {
                DispatchQueue.main.async { done(.signedIn) }
                return
            }
            // CLI says no — fall back to the keychain entry itself
            // before giving up. ACL-safe metadata lookup.
            let keychainSignedIn = Self.hasValidClaudeKeychainEntry()
            DispatchQueue.main.async {
                done(keychainSignedIn ? .signedIn : .notSignedIn)
            }
        }
    }

    /// True if the macOS login keychain holds a `Claude Code-credentials`
    /// generic-password item. We don't read the password (that would
    /// trigger the ACL prompt); existence + the modification timestamp
    /// are enough to distinguish "user has signed in via the CLI at
    /// some point" from "completely fresh install". For the false-
    /// positive case (entry exists but contains an expired or revoked
    /// token), the user will hit the failure later and can re-sign-in
    /// from Settings — far rarer than today's "signed in but Sutando
    /// doesn't see it" failure mode.
    static func hasValidClaudeKeychainEntry() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            // CRITICAL: do NOT set kSecReturnData. Reading the password
            // requires ACL approval (and prompts the user). Reading
            // attributes does not.
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess && item != nil
    }

    /// Refresh the row's labels + button based on current state. Pulls
    /// the latest state asynchronously so the UI doesn't block on the
    /// `claude auth status` subprocess.
    private func refreshClaudeStatus() {
        guard claudeStatusLabel != nil else { return }
        // Fast pre-flight: if the binary is missing we don't even need
        // to spin the subprocess.
        if resolveClaudeBinary() == nil {
            applyClaudeState(.notInstalled)
            return
        }
        probeClaudeState { [weak self] state in
            self?.applyClaudeState(state)
        }
    }

    private func applyClaudeState(_ state: ClaudeState) {
        guard let label = claudeStatusLabel, let button = claudeActionButton else { return }
        claudeState = state
        button.isEnabled = true
        switch state {
        case .notInstalled:
            label.stringValue = "Claude Code is not installed yet."
            label.textColor = .secondaryLabelColor
            button.title = "Install"
            stopClaudeAuthPolling()
        case .notSignedIn:
            if let path = resolveClaudeBinary() {
                let rel = path.hasPrefix(NSHomeDirectory())
                    ? "~" + path.dropFirst(NSHomeDirectory().count)
                    : path
                label.stringValue = "Installed at \(rel) but not signed in."
            } else {
                label.stringValue = "Installed but not signed in."
            }
            label.textColor = .systemOrange
            button.title = "Sign in"
        case .signedIn:
            label.stringValue = "✓ Claude Code is installed and signed in."
            label.textColor = .systemGreen
            button.title = "Re-check"
            stopClaudeAuthPolling()
        case .unknown:
            label.stringValue = "Checking…"
            label.textColor = .secondaryLabelColor
            button.title = "Re-check"
        }
        // Inline OAuth panel visibility is purely a function of "is a
        // sign-in subprocess currently in flight". Centralising it here
        // (rather than per-state) prevents the stale-panel bug where a
        // previous Sign-in click leaves the panel open after the row
        // independently flips to ✓ via keychain auto-detect — there's
        // no flow-state combination that can leave it visible without
        // a live subprocess.
        claudeAuthSignInPanel?.isHidden = (claudeAuthProcess == nil)
        // Skip button is meaningful only while we're still gating; once
        // signed in there's nothing to skip past.
        claudeSkipButton?.isHidden = (state == .signedIn) || claudeSkipped
        updateContinueButton()
    }

    @objc private func claudePrimaryAction() {
        switch claudeState {
        case .notInstalled, .unknown:
            installClaudeCLI()
        case .notSignedIn:
            signInToClaude()
        case .signedIn:
            // "Re-check" — manual nudge while we re-probe.
            claudeStatusLabel.stringValue = "Re-checking…"
            claudeStatusLabel.textColor = .secondaryLabelColor
            refreshClaudeStatus()
        }
    }

    @objc private func skipClaudeSignIn() {
        // User opted out of the sign-in gate. We still require the
        // binary to be installed (the core agent literally won't run
        // without it), but proceed even if not signed in — the menu-bar
        // Settings → Claude Code row remains the path to finish later.
        guard resolveClaudeBinary() != nil else {
            showBanner("Install Claude Code first — the agent can't run without it.", color: .systemOrange)
            return
        }
        claudeSkipped = true
        claudeSkipButton.isHidden = true
        showBanner("Sign-in skipped. Finish from Settings → Claude Code when you're ready.",
                   color: .systemOrange)
        updateContinueButton()
    }

    private func installClaudeCLI() {
        claudeActionButton.isEnabled = false
        claudeSpinner.startAnimation(nil)
        claudeStatusLabel.stringValue = "Installing Claude Code (this can take ~30s)…"
        claudeStatusLabel.textColor = .secondaryLabelColor

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            // -l to inherit a normal login PATH (curl, install -d) since
            // launchd hands us a sparse env. -c for the inline pipeline.
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
                self.claudeSpinner.stopAnimation(nil)
                if success && resolveClaudeBinary() != nil {
                    self.showBanner("Installed Claude Code. Click Sign in to complete setup.", color: .systemGreen)
                    self.refreshClaudeStatus()
                } else {
                    let snippet = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                    self.showBanner("Install failed: \(snippet.prefix(220))", color: .systemRed)
                    self.claudeActionButton.isEnabled = true
                }
            }
        }
    }

    /// Drive `claude auth login --claudeai` directly from the wizard.
    ///
    /// The CLI's flow is:
    ///   1. Print "Opening browser to sign in…"
    ///   2. Print the OAuth URL
    ///   3. Wait on stdin for "Paste code here if prompted > "
    ///   4. Read code → exchange → write keychain → exit 0
    ///
    /// We spawn it as a child process with piped stdin/stdout, parse
    /// the URL out of stdout, open it via NSWorkspace, then surface a
    /// paste field. When the user submits, we feed the code to stdin.
    /// On exit 0 we re-probe and flip to the green ✓ state.
    ///
    /// Why not Terminal.app: AppleScript Terminal automation requires
    /// an Automation TCC grant the user hasn't given on first launch,
    /// so the previous flow died with "Couldn't open Terminal" before
    /// the user even knew what we were trying to do.
    private func signInToClaude() {
        guard let path = resolveClaudeBinary() else {
            refreshClaudeStatus()
            return
        }
        // Already in flight — guard against double-clicks.
        if claudeAuthProcess != nil {
            claudeAuthSignInPanel.isHidden = false
            return
        }
        claudeAuthURL = nil
        claudeAuthURLField.stringValue = "Waiting for the CLI to print the sign-in URL…"
        claudeAuthCodeField.stringValue = ""
        claudeAuthCodeField.isEnabled = true
        claudeAuthSubmitButton.isEnabled = false
        claudeAuthStatusLabel.stringValue = ""
        claudeAuthStatusLabel.textColor = .secondaryLabelColor
        claudeAuthSignInPanel.isHidden = false
        claudeAuthSpinner.startAnimation(nil)

        claudeStatusLabel.stringValue = "Sign-in in progress — follow the prompts below."
        claudeStatusLabel.textColor = .secondaryLabelColor
        claudeActionButton.isEnabled = false

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        // --claudeai is the default but we pass it explicitly so a future
        // CLI default change doesn't silently switch us to --console.
        proc.arguments = ["auth", "login", "--claudeai"]
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        claudeAuthProcess = proc
        claudeAuthStdin = stdin.fileHandleForWriting

        // Stream stdout/stderr line-by-line. The URL surfaces here —
        // also any "Successfully signed in" / error chatter.
        var stdoutBuffer = ""
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                stdoutBuffer += chunk
                self?.handleClaudeAuthOutput(stdoutBuffer)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            // CLI sometimes routes the URL/banner via stderr depending on
            // the version — collect for diagnostics, but the URL parser
            // already runs against stdout where it primarily lands.
            _ = handle.availableData
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleClaudeAuthExit(status: proc.terminationStatus)
            }
        }

        do {
            try proc.run()
            // Backup poll. If anything along the OAuth flow short-circuits
            // our subprocess detection (Node stdout buffering eats the
            // "Paste code here" prompt; user runs `claude auth login` in
            // another window; flow completes faster than our terminationHandler
            // schedules), this catches it within ~2s and updates UI.
            startClaudeAuthPolling()
        } catch {
            claudeAuthProcess = nil
            claudeAuthStdin = nil
            claudeAuthSpinner.stopAnimation(nil)
            claudeAuthSignInPanel.isHidden = true
            claudeActionButton.isEnabled = true
            showBanner("Failed to launch claude: \(error.localizedDescription)", color: .systemRed)
        }
    }

    /// Parse stdout for the OAuth URL. The "Paste code here >" prompt
    /// often gets stuck in Node's stdout buffer when piped (no newline,
    /// no flush), so we DON'T gate the submit button on detecting that
    /// prompt — once we know the URL, we know the next thing the CLI
    /// wants is a code, and writes to stdin are queued by the kernel
    /// regardless of whether the CLI has reached its readline yet.
    private func handleClaudeAuthOutput(_ buffer: String) {
        if claudeAuthURL == nil {
            for line in buffer.split(separator: "\n") {
                let l = String(line).trimmingCharacters(in: .whitespaces)
                if let range = l.range(of: "https://", options: .caseInsensitive) {
                    let url = String(l[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                    if url.contains("claude.") || url.contains("anthropic.") {
                        claudeAuthURL = url
                        claudeAuthURLField.stringValue = url
                        claudeAuthURLField.textColor = .labelColor
                        claudeAuthSubmitButton.isEnabled = true
                        claudeAuthCodeField.window?.makeFirstResponder(claudeAuthCodeField)
                        if let u = URL(string: url) {
                            NSWorkspace.shared.open(u)
                        }
                        break
                    }
                }
            }
        }
    }

    private func handleClaudeAuthExit(status: Int32) {
        claudeAuthProcess = nil
        try? claudeAuthStdin?.close()
        claudeAuthStdin = nil
        stopClaudeAuthPolling()
        claudeAuthSpinner.stopAnimation(nil)
        claudeActionButton.isEnabled = true
        if status == 0 {
            // Trust the subprocess exit. We just watched `claude auth
            // login` complete the full OAuth handshake + keychain write
            // in-process; spending another subprocess round-trip on
            // `claude auth status` only opens us up to the keychain-ACL
            // false-negative where the read-side spawn can't see what
            // the write-side spawn just stored. Mark as signed in,
            // collapse the panel, move on.
            claudeAuthStatusLabel.stringValue = "✓ Signed in."
            claudeAuthStatusLabel.textColor = .systemGreen
            claudeAuthSignInPanel.isHidden = true
            applyClaudeState(.signedIn)
            showBanner("Signed in to Claude Code.", color: .systemGreen)
        } else {
            // Non-zero exit: code rejected, network failure, user cancel.
            claudeAuthStatusLabel.stringValue =
                "Sign-in didn't finish (exit \(status)). Click Sign in again, or paste a fresh code."
            claudeAuthStatusLabel.textColor = .systemRed
            // Keep the panel up so the user can retry without losing the URL.
            claudeAuthCodeField.isEnabled = true
            claudeAuthSubmitButton.isEnabled = false
        }
    }

    @objc private func submitClaudeAuthCode() {
        guard let stdin = claudeAuthStdin else { return }
        let code = claudeAuthCodeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            claudeAuthStatusLabel.stringValue = "Paste the authorization code first."
            claudeAuthStatusLabel.textColor = .systemOrange
            return
        }
        claudeAuthCodeField.isEnabled = false
        claudeAuthSubmitButton.isEnabled = false
        claudeAuthStatusLabel.stringValue = "Exchanging code…"
        claudeAuthStatusLabel.textColor = .secondaryLabelColor
        // CLI reads a single line from stdin; close after to flush EOF
        // in case it does another read (defensive — current versions
        // read once and exit).
        if let data = (code + "\n").data(using: .utf8) {
            stdin.write(data)
        }
    }

    @objc private func cancelClaudeAuth() {
        if let proc = claudeAuthProcess {
            proc.terminate()
        }
        claudeAuthProcess = nil
        try? claudeAuthStdin?.close()
        claudeAuthStdin = nil
        claudeAuthSpinner.stopAnimation(nil)
        claudeAuthSignInPanel.isHidden = true
        refreshClaudeStatus()
    }

    @objc private func reopenClaudeAuthURL() {
        guard let urlString = claudeAuthURL, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyClaudeAuthURL() {
        guard let urlString = claudeAuthURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urlString, forType: .string)
        claudeAuthStatusLabel.stringValue = "URL copied to clipboard."
        claudeAuthStatusLabel.textColor = .secondaryLabelColor
    }

    private func startClaudeAuthPolling() {
        stopClaudeAuthPolling()
        claudeAuthPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.probeClaudeState { state in
                guard state == .signedIn else { return }
                // Out-of-band success — most commonly because the user
                // ran `claude auth login` in another terminal while our
                // subprocess was still waiting for input. Tear down the
                // hung subprocess so it doesn't outlive the wizard.
                if let proc = self.claudeAuthProcess {
                    proc.terminate()
                    self.claudeAuthProcess = nil
                    try? self.claudeAuthStdin?.close()
                    self.claudeAuthStdin = nil
                }
                self.applyClaudeState(state)
                self.showBanner("Signed in to Claude Code.", color: .systemGreen)
            }
        }
    }

    private func stopClaudeAuthPolling() {
        claudeAuthPollTimer?.invalidate()
        claudeAuthPollTimer = nil
    }

    // MARK: - Step 4: Permissions actions

    private func startPermissionsPolling() {
        stopPermissionsPolling()
        // The user often toggles permissions in System Settings while
        // the wizard is up. Poll for fresh status so the row check-marks
        // and Continue enablement update without requiring a click.
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
        // App activation = "user just came back from System Settings".
        // That's the moment a Screen Recording revoke could have just
        // happened. Run the SCShareableContent probe ONCE then —
        // doing it from the 1Hz timer would carpet-bomb the user with
        // permission prompts, since SCShareableContent re-prompts on
        // every call against a revoked-but-cached grant.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        SystemPermission.runLiveScreenRecordingProbe()
        // Re-render shortly after the probe lands so the row reflects
        // the fresh state without waiting for the next poll tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermissionStatus()
        }
    }

    private func stopPermissionsPolling() {
        permissionsTimer?.invalidate()
        permissionsTimer = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func refreshPermissionStatus() {
        let mic = SystemPermission.microphone.status()
        let screen = SystemPermission.screenRecording.status()

        // Detect a granted-→-revoked transition for Screen Recording.
        // If the user toggles Sutando off in System Settings while the
        // wizard is open, we want the row to revert to ✗ + "Grant" —
        // not stay stuck on "Restart Sutando" (which would be wrong:
        // restarting won't bring back a permission they just revoked).
        if let last = lastSeenScreenStatus, last == .granted, screen != .granted {
            screenGrantClickedAt = nil
            screenRestartHint?.isHidden = true
        }
        lastSeenScreenStatus = screen

        if let label = micStatusLabel {
            label.stringValue = mic.symbol
            label.textColor = mic.color
        }
        if let label = screenStatusLabel {
            label.stringValue = screen.symbol
            label.textColor = screen.color
        }
        if let button = micActionButton {
            switch mic {
            case .granted:
                button.title = "Granted"
                button.isEnabled = false
            case .denied:
                button.title = "Open Settings"
                button.isEnabled = true
            default:
                button.title = "Grant"
                button.isEnabled = true
            }
        }
        if let button = screenActionButton {
            // Truth flow:
            //   .granted             → ✓ Granted, button disabled.
            //   recently clicked,
            //   ≥4s passed,
            //   still not granted    → "Restart Sutando" (TCC cache fix).
            //   .denied              → "Open Settings" (re-prompt suppressed).
            //   otherwise            → "Grant" (initial / cleared state).
            //
            // The 4s grace period gives macOS time to push the freshly-
            // granted permission to our process via
            // `canReadForeignWindowNames()`, which usually flips well
            // under that window — so on a clean grant the user sees
            // ✓ without ever seeing a "Restart" prompt. Restart only
            // appears for the genuinely-stuck case.
            let stillStaleAfterGrant = (screen != .granted)
                && (screenGrantClickedAt.map { Date().timeIntervalSince($0) > 4.0 } ?? false)
            if screen == .granted {
                button.title = "Granted"
                button.isEnabled = false
                button.action = #selector(grantScreenRecording)
                screenRestartHint?.isHidden = true
                // Clear the click stamp on success so a later revoke +
                // re-grant cycle doesn't immediately fall back into the
                // Restart path on a transient miss.
                screenGrantClickedAt = nil
            } else if stillStaleAfterGrant {
                button.title = "Restart Sutando"
                button.isEnabled = true
                button.action = #selector(restartForScreenRecording)
                screenRestartHint?.isHidden = false
            } else if screen == .denied {
                button.title = "Open Settings"
                button.isEnabled = true
                button.action = #selector(grantScreenRecording)
            } else {
                button.title = "Grant"
                button.isEnabled = true
                button.action = #selector(grantScreenRecording)
            }
        }
        updateContinueButton()
    }

    /// Persist the wizard's current step + relaunch the app. The TCC
    /// daemon will refresh the Screen Recording cache for the new
    /// process; on restart, `OnboardingWindowController` reads the
    /// step marker and resumes back at Permissions instead of dragging
    /// the user through Welcome → Gemini → Claude all over again.
    @objc private func restartForScreenRecording() {
        persistCurrentStep()
        // Make sure outstanding state (validated key, services we may
        // already have installed) survives the relaunch. They already
        // do (everything's on disk under $SUTANDO_HOME), but we cancel
        // any active subprocess so it doesn't get orphaned.
        if claudeAuthProcess != nil { cancelClaudeAuth() }
        appDelegate?.restartSelf()
    }

    @objc private func grantMicrophone() {
        let current = SystemPermission.microphone.status()
        if current == .denied {
            // User said "Don't Allow" before — macOS won't re-prompt.
            // Deeplink to System Settings is the only path forward.
            if let url = SystemPermission.microphone.systemSettingsURL {
                NSWorkspace.shared.open(url)
            }
            return
        }
        SystemPermission.microphone.request { [weak self] _ in
            self?.refreshPermissionStatus()
        }
    }

    @objc private func grantScreenRecording() {
        // Stamp the click so refreshPermissionStatus() knows to surface
        // the "Restart Sutando" path if the TCC cache stays stale.
        screenGrantClickedAt = Date()
        let current = SystemPermission.screenRecording.status()
        if current == .denied {
            if let url = SystemPermission.screenRecording.systemSettingsURL {
                NSWorkspace.shared.open(url)
            }
            // Even with .denied → System Settings, the user is going to
            // come back, toggle, and need a restart to take effect.
            screenRestartHint?.isHidden = false
            return
        }
        SystemPermission.screenRecording.request { [weak self] _ in
            self?.refreshPermissionStatus()
        }
    }

    // MARK: - Step 5: Services install

    @objc private func installServices() {
        if servicesInstallStarted { return }
        servicesInstallStarted = true
        servicesActionButton.isEnabled = false
        servicesSpinner.startAnimation(nil)
        servicesStatusLabel.stringValue = "Installing background services…"
        servicesStatusLabel.textColor = .secondaryLabelColor

        guard let workspace = appDelegate?.workspace else {
            servicesSpinner.stopAnimation(nil)
            servicesStatusLabel.stringValue = "Internal error: workspace unresolved."
            servicesStatusLabel.textColor = .systemRed
            servicesActionButton.isEnabled = true
            servicesInstallStarted = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let installer = LaunchAgentInstaller()
            _ = installer.migrateLegacyPlists()
            let paths = LaunchAgentInstaller.defaultPaths(workspace: workspace)
            var summary = LaunchAgentInstallSummary()
            do {
                summary = try installer.install(paths: paths)
            } catch LaunchAgentError.bundleResourcesMissing {
                DispatchQueue.main.async {
                    self?.servicesSpinner.stopAnimation(nil)
                    self?.servicesStatusLabel.stringValue =
                        "Bundle resources missing — running from a dev binary? Build the .app first."
                    self?.servicesStatusLabel.textColor = .systemOrange
                    self?.servicesActionButton.isEnabled = true
                    self?.servicesInstallStarted = false
                }
                return
            } catch {
                DispatchQueue.main.async {
                    self?.servicesSpinner.stopAnimation(nil)
                    self?.servicesStatusLabel.stringValue = "Install failed: \(error.localizedDescription)"
                    self?.servicesStatusLabel.textColor = .systemRed
                    self?.servicesActionButton.isEnabled = true
                    self?.servicesInstallStarted = false
                }
                return
            }

            // Give launchd ~1s to settle so loadedLabels() returns the
            // freshly-bootstrapped jobs. Poll thereafter so a slow service
            // start still updates the count without a manual refresh.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let self = self else { return }
                self.servicesSpinner.stopAnimation(nil)
                let installedCount = LaunchAgentInstaller().loadedLabels().count
                self.servicesInstalledCount = installedCount
                if !summary.failed.isEmpty {
                    let failed = summary.failed.map { $0.label }.joined(separator: ", ")
                    self.servicesStatusLabel.stringValue =
                        "\(installedCount) services running. Some failed: \(failed). You can re-try later from Settings."
                    self.servicesStatusLabel.textColor = .systemOrange
                } else if installedCount == 0 {
                    self.servicesStatusLabel.stringValue =
                        "Installed but nothing is running yet. Click Done — services start when the app finishes setup."
                    self.servicesStatusLabel.textColor = .systemOrange
                } else {
                    self.servicesStatusLabel.stringValue =
                        "✓ \(installedCount) services running. Auto-managed: start with Sutando, stop on quit."
                    self.servicesStatusLabel.textColor = .systemGreen
                }
                self.servicesActionButton.title = "Re-install"
                self.servicesActionButton.isEnabled = true
                self.servicesInstallStarted = false
                self.startServicesPolling()
                self.updateContinueButton()
            }
        }
    }

    private func startServicesPolling() {
        stopServicesPolling()
        servicesTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async {
                let count = LaunchAgentInstaller().loadedLabels().count
                DispatchQueue.main.async {
                    if self.servicesInstalledCount != count {
                        self.servicesInstalledCount = count
                        self.servicesStatusLabel.stringValue =
                            "✓ \(count) services running. Auto-managed: start with Sutando, stop on quit."
                        self.servicesStatusLabel.textColor = .systemGreen
                        self.updateContinueButton()
                    }
                }
            }
        }
    }

    private func stopServicesPolling() {
        servicesTimer?.invalidate()
        servicesTimer = nil
    }

    // MARK: - Completion

    private func completeOnboarding() {
        // Write the marker file. From here on, needsOnboarding returns
        // false and the main app opens normally.
        let marker = onboardingCompleteMarker()
        let dir = (marker as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker, contents: Data())

        // Belt-and-suspenders: also drop the legacy .firstrun-complete
        // marker so SettingsWindowController.needsFirstLaunchSetup
        // (which runs on every launch) doesn't reopen Settings on top
        // of the now-opening main window.
        let legacy = sutandoHomePathForOnboarding() + "/.firstrun-complete"
        if !FileManager.default.fileExists(atPath: legacy) {
            FileManager.default.createFile(atPath: legacy, contents: Data())
        }

        // Resume marker is no longer needed once onboarding is done.
        try? FileManager.default.removeItem(atPath: onboardingStepMarker())

        stopPermissionsPolling()
        stopServicesPolling()
        stopClaudeAuthPolling()
        if claudeAuthProcess != nil { cancelClaudeAuth() }
        NotificationCenter.default.removeObserver(self)

        let cb = onComplete
        window?.orderOut(nil)
        cb?()
    }

    // MARK: - Helpers

    private func showBanner(_ text: String, color: NSColor) {
        statusBanner.stringValue = text
        statusBanner.textColor = color
        statusBanner.isHidden = false
    }

    // MARK: - NSWindowDelegate

    /// Window has no close button (styleMask omits .closable), but defend
    /// against red-button via the menu / scripting just in case: refuse
    /// to close while onboarding is incomplete. Quitting the app entirely
    /// is the user's escape valve.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return !Self.needsOnboarding
    }

    deinit {
        permissionsTimer?.invalidate()
        servicesTimer?.invalidate()
        claudeAuthPollTimer?.invalidate()
        // Last-chance cleanup if the controller is torn down with a
        // child still alive (e.g. user quits mid-OAuth). terminate()
        // is safe to call on an already-exited process.
        claudeAuthProcess?.terminate()
        NotificationCenter.default.removeObserver(self)
    }
}
