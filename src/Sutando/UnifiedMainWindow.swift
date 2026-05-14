import AppKit
@preconcurrency import WebKit

// Unified main window. Replaces the per-feature window sprawl (separate
// voice WebView, separate dashboard WebView, separate Settings window)
// with one sidebar-tabbed window. Backend services are unchanged — the
// voice agent still serves localhost:8080, the dashboard still serves
// localhost:7844, Settings still writes $SUTANDO_HOME/.env. This is
// purely a rendering refactor so the user has one place to look.
//
// Theme matches the cloud control plane at sutando.ag2.ai — pure-neutral
// palette, system font, dark-first, no accent colors, generous spacing.
// Reference: Linear / Vercel / Raycast.
//
// Lifecycle: the window is created lazily on first menu-bar invocation
// and kept alive thereafter. Closing it hides it; the next "Open …"
// menu item re-shows it with the same pane state. The voice WebView is
// loaded on first access and reused across pane switches (so the user
// doesn't lose conversation context when they peek at Settings).

enum UnifiedPane: String, CaseIterable {
    case conversation
    case cli
    case dashboard
    case settings

    var label: String {
        switch self {
        case .conversation: return "Conversation"
        case .cli:          return "Core CLI"
        case .dashboard:    return "Dashboard"
        case .settings:     return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .conversation: return "waveform"
        case .cli:          return "terminal"
        case .dashboard:    return "chart.bar.fill"
        case .settings:     return "slider.horizontal.3"
        }
    }
}

final class UnifiedMainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    weak var appDelegate: AppDelegate?

    private var sidebarStack: NSStackView!
    private var sidebarButtons: [UnifiedPane: SidebarButton] = [:]
    private var contentContainer: NSView!
    private var cloudFooterLabel: NSTextField?

    private var conversationWebView: WKWebView?
    private var conversationRetry = 0
    private var cliWebView: WKWebView?
    private var cliRetry = 0
    private var dashboardWebView: WKWebView?
    private var dashboardRetry = 0

    private var settingsController: SettingsWindowController?

    private var currentPane: UnifiedPane = .conversation
    private let maxRetries = 30
    private let retryInterval: TimeInterval = 1.0

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sutando"
        window.minSize = NSSize(width: 880, height: 540)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setFrameAutosaveName("SutandoUnifiedWindow")
        // Match cloud's body background — neutral-950 dark / neutral-50
        // light. The window's backgroundColor propagates to subviews
        // that don't override, killing the default system mid-gray.
        window.backgroundColor = Theme.pageBackground
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
        selectPane(.conversation, fromUserAction: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showAndFocus(pane: UnifiedPane? = nil) {
        if let p = pane { selectPane(p, fromUserAction: true) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshCloudFooter()
    }

    /// Cmd+R force-reloads the active WebView pane. Useful after a code
    /// push (web-client.ts / dashboard.py edits) so the user can see new
    /// HTML without restarting the whole app — WKWebView's HTTP cache
    /// can hold the previous page across service restarts.
    @objc func reloadActivePane(_ sender: Any?) {
        switch currentPane {
        case .conversation:
            conversationRetry = 0
            conversationWebView?.reloadFromOrigin()
        case .cli:
            cliRetry = 0
            cliWebView?.reloadFromOrigin()
        case .dashboard:
            dashboardRetry = 0
            dashboardWebView?.reloadFromOrigin()
        case .settings:
            break
        }
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let window = window, let contentView = window.contentView else { return }

        // Sidebar + content side by side. NSSplitView would give us
        // user-resizable dividers, but for the unified layout we want a
        // fixed-width sidebar matching cloud's left rail. Use a plain
        // container with two children and explicit constraints.
        let sidebar = makeSidebar()
        let bg = ThemedBackgroundView()
        bg.themedBackgroundColor = Theme.pageBackground
        bg.translatesAutoresizingMaskIntoConstraints = false
        contentContainer = bg

        // Thin vertical separator between sidebar and content. Matches
        // cloud's neutral-200/800 dividers.
        let divider = ThemedBackgroundView()
        divider.themedBackgroundColor = Theme.separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(sidebar)
        contentView.addSubview(divider)
        contentView.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),

            divider.topAnchor.constraint(equalTo: contentView.topAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func makeSidebar() -> NSView {
        let sidebar = ThemedBackgroundView()
        sidebar.themedBackgroundColor = Theme.sidebarBackground
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        // Wordmark — matches cloud's "Sutando" at the top-left of the
        // dashboard header. Plain text mark, no logo glyph next to it
        // (the cockroach-looking icon is being replaced separately).
        let wordmark = NSTextField(labelWithString: "Sutando")
        wordmark.font = .systemFont(ofSize: 17, weight: .semibold)
        wordmark.textColor = .labelColor
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(wordmark)

        // Tagline / status row. Shows signed-in email (or "Signed out")
        // so the user knows which account they're operating as. Cloud
        // dashboard does the same thing under the page title.
        let footer = NSTextField(labelWithString: "")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.maximumNumberOfLines = 2
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(footer)
        cloudFooterLabel = footer

        // Navigation stack.
        sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 2
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        for pane in UnifiedPane.allCases {
            let btn = SidebarButton(pane: pane, label: pane.label, symbolName: pane.symbolName)
            btn.target = self
            btn.action = #selector(sidebarButtonPressed(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false
            sidebarButtons[pane] = btn
            sidebarStack.addArrangedSubview(btn)
            NSLayoutConstraint.activate([
                btn.leadingAnchor.constraint(equalTo: sidebarStack.leadingAnchor),
                btn.trailingAnchor.constraint(equalTo: sidebarStack.trailingAnchor),
                btn.heightAnchor.constraint(equalToConstant: 34),
            ])
        }

        // Sign out at the bottom — destructive action (uninstalls
        // services + quits app, per cloudSignOut() in main.swift).
        let signOut = NSButton(title: "Sign out", target: self, action: #selector(signOutPressed))
        signOut.bezelStyle = .inline
        signOut.isBordered = false
        signOut.font = .systemFont(ofSize: 12)
        signOut.contentTintColor = .secondaryLabelColor
        signOut.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(signOut)

        NSLayoutConstraint.activate([
            wordmark.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 30),
            wordmark.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),

            footer.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: 4),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),

            sidebarStack.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 28),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

            signOut.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            signOut.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20),
        ])

        return sidebar
    }

    // MARK: - Pane switching

    @objc private func sidebarButtonPressed(_ sender: NSButton) {
        guard let btn = sender as? SidebarButton else { return }
        selectPane(btn.pane, fromUserAction: true)
    }

    func selectPane(_ pane: UnifiedPane, fromUserAction: Bool) {
        currentPane = pane
        for (p, btn) in sidebarButtons {
            btn.setSelected(p == pane)
        }
        // Swap content. We keep the previous view in memory (don't
        // remove from cache) so the next selection is instant.
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let v = view(for: pane)
        v.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func view(for pane: UnifiedPane) -> NSView {
        switch pane {
        case .conversation: return conversationPaneView()
        case .cli:          return cliPaneView()
        case .dashboard:    return dashboardPaneView()
        case .settings:     return settingsPaneView()
        }
    }

    // MARK: - Pane builders

    private func conversationPaneView() -> NSView {
        if let wv = conversationWebView { return wv }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.load(URLRequest(url: URL(string: "http://localhost:8080")!))
        conversationWebView = wv
        return wv
    }

    private func cliPaneView() -> NSView {
        if let wv = cliWebView { return wv }
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        // Terminal bridge: localhost:7847 serves xterm.js HTML and a WS
        // PTY-attached to the sutando-core tmux session. Backed by
        // src/terminal-server.ts and com.sutando.terminal-server.plist.
        wv.load(URLRequest(url: URL(string: "http://localhost:7847")!))
        cliWebView = wv
        return wv
    }

    private func dashboardPaneView() -> NSView {
        if let wv = dashboardWebView { return wv }
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.load(URLRequest(url: URL(string: "http://localhost:7844")!))
        dashboardWebView = wv
        return wv
    }

    private func settingsPaneView() -> NSView {
        if settingsController == nil, let app = appDelegate {
            settingsController = SettingsWindowController(appDelegate: app)
        }
        guard let c = settingsController else { return NSView() }
        return c.adoptedContentView()
    }

    // MARK: - Cloud footer

    private func refreshCloudFooter() {
        guard let label = cloudFooterLabel else { return }
        if CloudAuth.shared.isSignedIn, let rec = CloudAuth.shared.record() {
            // userId is a UUID; the visible identity comes from /api/me
            // which Settings already polls. For now show a short device-
            // hostname-ish line so the user knows which Mac + account.
            let host = Host.current().localizedName ?? ""
            label.stringValue = host.isEmpty ? "Signed in" : "Signed in · \(host)"
            // Mark `rec` as used (silences any -Wunused if a future
            // refactor drops the host fallback).
            _ = rec.userId
        } else {
            label.stringValue = "Signed out"
        }
    }

    @objc private func signOutPressed() {
        appDelegate?.cloudSignOut()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide instead of close so the next openWebUI() / openDashboard()
        // re-uses the same window + WebViews (preserves conversation
        // history).
        window?.orderOut(nil)
        return false
    }

    // MARK: - WKNavigationDelegate (cold-start retry)

    /// Mirrors WebWindow.swift: on launchd cold-start the WKWebView may
    /// land before the localhost service is up. Retry on connection
    /// failures up to maxRetries × retryInterval.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsErr = error as NSError
        guard nsErr.domain == NSURLErrorDomain else { return }
        let connectionFailures: Set<Int> = [
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotFindHost,
            NSURLErrorTimedOut,
        ]
        guard connectionFailures.contains(nsErr.code) else { return }

        // Bump the right retry counter, retry against the right URL.
        if webView === conversationWebView {
            conversationRetry += 1
            if conversationRetry <= maxRetries {
                DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                    self?.conversationWebView?.load(URLRequest(url: URL(string: "http://localhost:8080")!))
                }
            } else {
                showServiceUnreachable(in: webView, url: "http://localhost:8080")
            }
        } else if webView === cliWebView {
            cliRetry += 1
            if cliRetry <= maxRetries {
                DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                    self?.cliWebView?.load(URLRequest(url: URL(string: "http://localhost:7847")!))
                }
            } else {
                showServiceUnreachable(in: webView, url: "http://localhost:7847")
            }
        } else if webView === dashboardWebView {
            dashboardRetry += 1
            if dashboardRetry <= maxRetries {
                DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                    self?.dashboardWebView?.load(URLRequest(url: URL(string: "http://localhost:7844")!))
                }
            } else {
                showServiceUnreachable(in: webView, url: "http://localhost:7844")
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Reset retry counters once we connect.
        if webView === conversationWebView { conversationRetry = 0 }
        if webView === cliWebView { cliRetry = 0 }
        if webView === dashboardWebView { dashboardRetry = 0 }
    }

    private func showServiceUnreachable(in webView: WKWebView, url: String) {
        let html = """
        <html><body style="font-family:-apple-system,system-ui; padding:48px; color:#999; background:#0a0a0a">
        <h2 style="color:#eee; font-weight:600">Service not reachable</h2>
        <p>The Sutando service at <code>\(url)</code> isn't responding.</p>
        <p>Try Settings → Background services → Restart.</p>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - WKUIDelegate

    /// Auto-grant mic/camera for localhost (voice client + dashboard).
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        if origin.host == "localhost" || origin.host == "127.0.0.1" {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }
}

// MARK: - Sidebar button

/// Custom NSButton with a selected-state background highlight, matching
/// cloud's sidebar item style (subtle filled background + bold text on
/// the active item). NSButton's default styling doesn't get us there
/// without a more elaborate cell subclass.
final class SidebarButton: NSButton {
    let pane: UnifiedPane
    private var isSelectedState = false

    init(pane: UnifiedPane, label: String, symbolName: String) {
        self.pane = pane
        super.init(frame: .zero)
        title = "  " + label
        font = .systemFont(ofSize: 13, weight: .regular)
        if #available(macOS 11.0, *) {
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        bezelStyle = .inline
        isBordered = false
        contentTintColor = .secondaryLabelColor
        alignment = .left
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        applySelectionStyling()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // CALayer caches the resolved CGColor at set time — re-resolve
        // against the new appearance so dark→light flips don't strand
        // the active item with a stale tint.
        applySelectionStyling()
    }

    private func applySelectionStyling() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if self.isSelectedState {
                self.layer?.backgroundColor = Theme.sidebarSelection.cgColor
                self.contentTintColor = .labelColor
                self.font = .systemFont(ofSize: 13, weight: .semibold)
            } else {
                self.layer?.backgroundColor = NSColor.clear.cgColor
                self.contentTintColor = .secondaryLabelColor
                self.font = .systemFont(ofSize: 13, weight: .regular)
            }
        }
        needsDisplay = true
    }
}

// MARK: - Theme

/// Cloud-matching color tokens. Pure-neutral palette, no accent colors,
/// dark-first with automatic light-mode adaptation. Reference values
/// mirror Tailwind neutral-50 (light) and neutral-950 (dark) from the
/// cloud's globals.css.
///
/// Use these via `NSWindow.backgroundColor =` or via `ThemedBackgroundView`
/// for layer-backed views — see header on ThemedBackgroundView for the
/// dynamic-color-on-CALayer pitfall.
enum Theme {
    /// Cloud body background: neutral-950 dark / neutral-50 light.
    /// Matches `body` in `agent-universe/app/globals.css`.
    static let pageBackground: NSColor = NSColor(name: "SutandoPageBackground", dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        return isDark
            ? NSColor(red: 0.039, green: 0.039, blue: 0.039, alpha: 1.0)  // #0a0a0a
            : NSColor(red: 0.980, green: 0.980, blue: 0.980, alpha: 1.0)  // #fafafa
    })

    /// Sidebar background — same as the page in both modes so the whole
    /// window reads as one surface. The thin separator + selection
    /// highlight do the visual heavy lifting.
    static let sidebarBackground: NSColor = pageBackground

    /// Card / panel surface (e.g. usage bars, tier pills). Slightly
    /// distinct from the page so cards read as containers. Mirrors
    /// `bg-neutral-100` (light) and `bg-neutral-900` (dark).
    static let cardBackground: NSColor = NSColor(name: "SutandoCardBackground", dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        return isDark
            ? NSColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1.0)  // ~#181818
            : NSColor(red: 0.961, green: 0.961, blue: 0.961, alpha: 1.0)  // ~#f5f5f5
    })

    /// Subtle 1px divider color — neutral-200 light, neutral-800 dark.
    static let separator: NSColor = NSColor(name: "SutandoSeparator", dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        return isDark
            ? NSColor(white: 0.13, alpha: 1.0)
            : NSColor(white: 0.90, alpha: 1.0)
    })

    /// Highlight on the active sidebar item.
    static let sidebarSelection: NSColor = NSColor(name: "SutandoSidebarSelection", dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        return isDark
            ? NSColor(white: 1.0, alpha: 0.08)
            : NSColor(white: 0.0, alpha: 0.06)
    })
}

// MARK: - ThemedBackgroundView

/// NSView whose layer background tracks a dynamic NSColor across
/// appearance changes. The naive approach
/// (`layer?.backgroundColor = dynamicColor.cgColor`) captures the
/// resolved CGColor *at the call site* — CALayer doesn't observe
/// NSAppearance, so a dark→light system flip leaves the view in its
/// stale color. We re-resolve in `viewDidChangeEffectiveAppearance()`
/// and on every set so toggling the system theme updates immediately.
final class ThemedBackgroundView: NSView {
    var themedBackgroundColor: NSColor = .clear {
        didSet { applyBackground() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        applyBackground()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = self.themedBackgroundColor.cgColor
        }
    }
}
