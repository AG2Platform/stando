// Sparkle wiring. Compiled only when the build script defines
// `-DENABLE_SPARKLE` and links against Sparkle.framework. The
// `#if ENABLE_SPARKLE` gates around the Sparkle import keep the dev
// build (no Sparkle.framework) compiling cleanly.
//
// Phase 2 plan:
//   - SUFeedURL → ag2.ai/sutando/updates/<channel>/appcast.xml
//   - SUPublicEDKey → embedded in Info.plist
//   - Channel: read from SUSelectedChannel or default "internal"
//   - "Check for Updates…" menu item
//   - Auto-check on launch (gated by SUEnableAutomaticChecks)

import Cocoa
#if ENABLE_SPARKLE
import Sparkle
#endif

#if ENABLE_SPARKLE

/// Wraps `SPUStandardUpdaterController` with a thin façade so `main.swift`
/// can call into Sparkle without sprinkling `#if ENABLE_SPARKLE` blocks
/// throughout. When the build excludes Sparkle, the no-op stub below
/// (compiled in `#else`) keeps the same API.
final class SparkleUpdater: NSObject, SPUUpdaterDelegate {
    // Implicitly-unwrapped because Sparkle 2's SPUUpdater doesn't expose
    // `delegate` as a settable property — the delegate has to be passed
    // at controller-construction time. So we super.init() first to make
    // `self` valid, then construct the controller with `self` as
    // updaterDelegate.
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // startingUpdater: true → Sparkle starts background checks.
        // updaterDelegate: self → we control feed-URL channel selection.
        // userDriverDelegate: nil → use the default UI.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    /// Trigger the standard update-check UI. Wired to the menu item.
    @objc func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Build the feed URL, optionally per channel. Channel defaults to
    /// "internal" but can be overridden by setting SUSelectedChannel in
    /// UserDefaults (e.g. via a hidden menu item).
    func feedURLString(for updater: SPUUpdater) -> String? {
        let channel = UserDefaults.standard.string(forKey: "SUSelectedChannel") ?? "internal"
        return "https://ag2.ai/sutando/updates/\(channel)/appcast.xml"
    }
}

#else

/// No-op stub used when ENABLE_SPARKLE is not defined. Keeps `main.swift`
/// callable in either build mode without conditional code in the call site.
final class SparkleUpdater: NSObject {
    @objc func checkForUpdates() {
        let alert = NSAlert()
        alert.messageText = "Auto-update not enabled in this build"
        alert.informativeText = "Rebuild with ENABLE_SPARKLE=1 to enable Sparkle, or check the GitHub Releases page manually."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

#endif
