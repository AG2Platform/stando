import AppKit
@preconcurrency import WebKit

// Generic WKWebView window controller. Used for the voice client
// (localhost:8080) and the dashboard (localhost:7844).
//
// Why this exists: the previous design opened both URLs in Chrome via
// AppleScript. That:
//   - Required Apple Events permission to Chrome (extra TCC dance).
//   - Forced the user to keep a browser open as a hard dependency.
//   - Made the .app feel like glue around web pages instead of an app.
//
// Keeping these as launchd-managed servers means we don't change the
// architecture — we just own the rendering surface. The voice client
// keeps its WebSocket to :9900; the dashboard keeps its Python server
// at :7844. This class wraps the rendering, retries on cold-start
// (when launchd hasn't bootstrapped the service yet), and auto-grants
// microphone capture for localhost origins.

final class WebWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private let url: URL
    private let allowMedia: Bool
    private var attempt = 0
    private let maxRetries = 30
    private let retryInterval: TimeInterval = 1.0

    init(title: String, url: URL, allowMedia: Bool, autosaveName: String,
         contentSize: NSSize = NSSize(width: 1100, height: 720)) {
        self.url = url
        self.allowMedia = allowMedia
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 480, height: 320)
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName(autosaveName)
        buildWebView()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        if allowMedia {
            // Page can autoplay <audio>/<video> without a user gesture
            // (the voice client streams TTS audio without one).
            config.mediaTypesRequiringUserActionForPlayback = []
        }
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let frame = window?.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1100, height: 720)
        webView = WKWebView(frame: frame, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window?.contentView?.addSubview(webView)
    }

    func showAndFocus() {
        if !(window?.isVisible ?? false) {
            attempt = 0
            webView.load(URLRequest(url: url))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func reload(_ sender: Any?) {
        attempt = 0
        webView.load(URLRequest(url: url))
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Stop the page (releases mic, audio, network) but keep the
        // controller alive so the next open is fast.
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    // MARK: - WKNavigationDelegate

    /// On cold start the launchd service may not be up yet — retry on
    /// "cannot connect" up to maxRetries × retryInterval.
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
        attempt += 1
        if attempt <= maxRetries {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                guard let self = self else { return }
                self.webView.load(URLRequest(url: self.url))
            }
        } else {
            // Give up; show a static page explaining the situation.
            let html = """
            <html><body style="font-family:-apple-system; padding:40px; color:#444">
            <h2>Service not reachable</h2>
            <p>The Sutando service at <code>\(self.url.absoluteString)</code> isn't responding.</p>
            <p>Open <b>Settings</b> (⌘,) → <b>Background Services</b> and click <b>Install</b>.</p>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: - WKUIDelegate

    /// Auto-grant microphone/camera for localhost origins. Anything else
    /// is denied — we never load non-localhost URLs in these windows.
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host
        if host == "localhost" || host == "127.0.0.1" {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }
}
