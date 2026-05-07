// Sparkle wiring. Compiled only when the build script defines
// `-DENABLE_SPARKLE` and links against Sparkle.framework. The
// `#if ENABLE_SPARKLE` gates around the Sparkle import keep the dev
// build (no Sparkle.framework) compiling cleanly.
//
// Update feed:
//   - Hosted on GitHub Releases (the release.yml workflow uploads
//     appcast.xml as a release asset on every tagged build).
//   - URL: github.com/AG2Platform/stando/releases/latest/download/appcast.xml
//   - GitHub redirects /releases/latest to whatever the most-recent
//     non-prerelease release is. release.yml marks all internal
//     releases as non-prerelease so they qualify as "latest" until
//     stable + beta channels actually diverge.
//   - SUPublicEDKey is embedded in Info.plist; clients verify the
//     EdDSA signature on each appcast item before downloading.
//   - Channels: read from SUSelectedChannel UserDefaults; defaults to
//     "internal". generate_appcast tags each item with its channel via
//     <sparkle:channel> so multi-channel filtering works without
//     per-channel URLs.
//   - When ag2.ai's CDN is set up, swap to
//     ag2.ai/sutando/updates/<channel>/appcast.xml in one commit.

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

    /// Build the feed URL. Hosted on GitHub Releases for now — channel
    /// filtering happens inside the appcast via <sparkle:channel> tags
    /// rather than per-channel URLs, so a single feed serves all
    /// channels. The SUSelectedChannel UserDefault still controls which
    /// items Sparkle picks from that feed.
    func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://github.com/AG2Platform/stando/releases/latest/download/appcast.xml"
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
