import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// macOS permission status + System Settings deeplinks.
//
// Sutando's privacy-relevant scopes:
//   - Microphone        for the voice agent
//   - Accessibility     for global hotkeys + macos-use skill
//   - Screen Recording  for describe_screen + screen-record skill
//
// Permission grants happen via macOS prompts, but the System Settings
// deeplinks let us shortcut users who said "Don't Allow" by mistake.
// Each preflight is non-blocking and can be polled.

enum SystemPermission: String, CaseIterable {
    case microphone
    case accessibility
    case screenRecording

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    var purpose: String {
        switch self {
        case .microphone: return "Required for voice conversations."
        case .accessibility: return "Required for global hotkeys and clicking/typing in apps."
        case .screenRecording: return "Required for describe_screen. Enable both Sutando and python3 in the list."
        }
    }

    /// Deep link that opens the right pane of System Settings.
    var systemSettingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    /// Best-effort status check. None of these prompt the user — for that,
    /// call `request()` (which only meaningfully exists for microphone;
    /// accessibility + screen-recording grants happen via the System
    /// Settings dialog).
    func status() -> Status {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        case .accessibility:
            // AXIsProcessTrusted() returns true if the running process is
            // approved for AX. No-prompt variant.
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            // Layered detection. CRITICAL constraint: NEVER call
            // `SCShareableContent.current` from a polling loop —
            // SCShareableContent re-prompts the user every time it's
            // invoked against a revoked-but-cached grant, so polling
            // would carpet-bomb dialogs at 1Hz. SCShareableContent is
            // only run from `runLiveScreenRecordingProbe()`, which
            // wizard code calls explicitly on app activation.
            //
            // Order of trust within status():
            //   1. Most recent SCShareableContent result if it's
            //      under ~30s old (catches the toggle-off case that
            //      activation-driven probing was designed to detect).
            //      Currently disabled — see `runLiveScreenRecordingProbe()`.
            //   2. `CGPreflightScreenCaptureAccess()` — Apple's
            //      canonical no-prompt check, authoritative.
            //
            // We deliberately do NOT use a foreign-window-name
            // heuristic as a positive grant signal. On macOS 15+
            // some system/Apple-owned windows expose names via
            // `CGWindowListCopyWindowInfo` even when the calling
            // process has no Screen Recording grant, which produced
            // false positives in Settings (✓ green for users who
            // never granted). Sticking to CGPreflight avoids that.
            // The fresh-grant case where CGPreflight stays stale
            // until restart is already handled by the wizard's
            // "Restart Sutando" path.
            if let live = Self.recentLiveScreenResult() {
                return live ? .granted : .notDetermined
            }
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        }
    }

    // MARK: - Live Screen Recording probe (ScreenCaptureKit-backed)

    /// Last result from `SCShareableContent.current` and when it landed.
    /// Read by `recentLiveScreenResult()` and updated by the async task
    /// in `startLiveScreenRecordingCheck()`. Plain Bool reads/writes are
    /// atomic on aligned 64-bit, but we still serialise via the lock to
    /// keep the (value, timestamp) pair coherent.
    nonisolated(unsafe) private static var liveScreenGranted: Bool? = nil
    nonisolated(unsafe) private static var liveScreenAt: Date = .distantPast
    nonisolated(unsafe) private static var liveScreenInFlight: Bool = false
    private static let liveScreenLock = NSLock()

    /// True iff the in-process Screen Recording prompt
    /// (`CGRequestScreenCaptureAccess`) is unsafe to call from this
    /// process on the current macOS.
    ///
    /// Background: Apple tightened the Screen Recording TCC model in
    /// macOS 15 (Sequoia, per-app granular capture) and again in
    /// macOS 26. On macOS 26 specifically, the request API traps
    /// before returning when called from an app that doesn't carry
    /// the new (still-undocumented) screen-capture entitlement —
    /// which `app/Sutando.entitlements` does not. The observed
    /// symptom was the v0.3.0 onboarding wizard crashing on first
    /// launch and locking every user on macOS 26 out of the app.
    ///
    /// We default to "unsafe" on macOS 26+ where we have hard
    /// evidence, and also honor `SUTANDO_SKIP_SCREEN_RECORDING_PROMPT=1`
    /// as a no-rebuild escape hatch for users hitting similar crashes
    /// on other versions. On older macOS the in-process prompt has
    /// worked for years; we keep it as the default UX there.
    ///
    /// When this returns true, callers must open the System Settings
    /// deeplink instead of calling `CGRequestScreenCaptureAccess()`.
    /// The deeplink works on every macOS version that has TCC.
    static var shouldSkipScreenRecordingPrompt: Bool {
        if ProcessInfo.processInfo.environment["SUTANDO_SKIP_SCREEN_RECORDING_PROMPT"] == "1" {
            return true
        }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    /// Return the live SCShareableContent result if we ran the probe in
    /// the last 30 seconds — otherwise nil so callers fall through to
    /// the synchronous CG checks. 30s matches the typical
    /// "user clicks Grant → Settings → toggles → comes back" window
    /// without burning CPU on prompts the user already answered.
    private static func recentLiveScreenResult() -> Bool? {
        liveScreenLock.lock()
        defer { liveScreenLock.unlock() }
        guard let v = liveScreenGranted, Date().timeIntervalSince(liveScreenAt) < 30 else {
            return nil
        }
        return v
    }

    /// Run the SCShareableContent-based live probe ONCE and stash the
    /// result for `recentLiveScreenResult()` to surface. This is the
    /// only place SCShareableContent is invoked.
    ///
    /// SCShareableContent re-prompts the user each time it's called
    /// against a revoked-but-cached grant, so callers MUST NOT invoke
    /// this from a polling loop. The wizard hooks
    /// `NSApplication.didBecomeActiveNotification` and runs it once
    /// per activation — i.e. exactly when the user has plausibly just
    /// toggled the permission in System Settings.
    ///
    /// Coalesced: at most one in-flight probe at a time. Subsequent
    /// calls while one is running are no-ops.
    static func runLiveScreenRecordingProbe() {
        // Disabled across all macOS versions. Calling
        // `SCShareableContent.current` was crashing the v0.3.0
        // onboarding wizard on macOS 26 (no screen-capture
        // entitlement), and Apple has touched this surface in every
        // major macOS release since 15 (Sequoia) — keeping the call
        // alive on "supposedly safe" versions is asking for the same
        // app-doesn't-open regression to recur. The probe was only
        // ever defensive (catching revoke-while-wizard-is-open), not
        // load-bearing: skipping it makes `status()` fall through to
        // the synchronous `CGPreflightScreenCaptureAccess` +
        // window-name checks, which is the same fallback path used
        // on macOS < 12.3 and which covers the install flow fine.
        //
        // Re-enable only after the .app carries the macOS 26
        // screen-capture entitlement (and a regression test confirms
        // first-launch survival on every supported macOS major).
        // The original implementation lives in git history at the
        // commit that introduced this guard — restore via `git log
        // -p src/Sutando/Permissions.swift` rather than ressurecting
        // dead code in the file.
        return
    }

    /// Trigger a permission prompt where applicable. For accessibility +
    /// screen recording, returns `notDetermined` and surfaces the System
    /// Settings deeplink instead — macOS won't prompt these without a real
    /// access attempt, and the deeplink is a more reliable UX.
    func request(completion: @escaping (Status) -> Void) {
        switch self {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted ? .granted : .denied)
                }
            }
        case .accessibility:
            // Prompt option asks the user; returns true only if already trusted.
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(opts)
            completion(trusted ? .granted : .notDetermined)
        case .screenRecording:
            // See `shouldSkipScreenRecordingPrompt` doc-comment. The
            // CG request path traps on macOS 26 without the new
            // (still-undocumented) screen-capture entitlement and may
            // regress on other versions, so when the safety gate is
            // tripped we skip the in-process prompt entirely and
            // route the user straight to System Settings. The helper-
            // trigger path still runs because that's a separate
            // python3 process and the entitlement constraint applies
            // to the calling binary, not us.
            if Self.shouldSkipScreenRecordingPrompt {
                if let url = self.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
                // Without this, macOS 26 users land on an empty
                // Screen Recording list — `CGRequestScreenCaptureAccess`
                // would normally register us, but we can't call it,
                // and opening System Settings on its own doesn't
                // populate the list. Spawning `screencapture` as a
                // child of Sutando.app makes TCC attribute the
                // capture attempt to our bundle (we're the
                // responsible app), so Sutando appears in the list
                // ready to be toggled on.
                Self.registerSutandoInScreenRecordingTCC()
                Self.triggerHelperScreenAccess()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    completion(self.status())
                }
                return
            }
            // Async prompt; we poll on the main queue.
            CGRequestScreenCaptureAccess()
            // ALSO trigger a screen-capture attempt from the launchd
            // helpers so they appear in System Settings → Privacy &
            // Security → Screen Recording. Without this, only Sutando.app
            // shows up — but the launchd-spawned python3 (which actually
            // does `screencapture` for the screen-capture-server) is a
            // separate binary and TCC tracks it separately. Hitting the
            // running service is the cleanest trigger; the direct-python
            // fallback covers the case where services aren't installed yet.
            Self.triggerHelperScreenAccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion(self.status())
            }
        }
    }

    /// Force-register Sutando.app in the Screen Recording entry of
    /// System Settings → Privacy & Security by spawning a one-shot
    /// `screencapture` child process.
    ///
    /// Why: on macOS 26 we can't call `CGRequestScreenCaptureAccess()`
    /// (it traps without the new screen-capture entitlement — see
    /// `shouldSkipScreenRecordingPrompt`), and merely opening the
    /// Screen Recording settings pane does NOT add Sutando to the
    /// list. macOS only adds an app to the list once that app has
    /// attempted a screen-capture API call. Without this nudge,
    /// users land on an empty Screen Recording list after clicking
    /// "Grant" and have nothing to toggle on.
    ///
    /// How: spawn `/usr/sbin/screencapture` as a child of Sutando.app
    /// targeting a throwaway tmp file. TCC attributes the capture
    /// request to the responsible code-signing identity — for a
    /// process spawned by Sutando.app, that's our bundle, so
    /// "Sutando" shows up in the list. The screencapture binary
    /// itself is system-signed and is NOT tracked separately
    /// (mirrors how the launchd-spawned python3 helper, which also
    /// shells out to screencapture, registers as `python3` rather
    /// than as `screencapture`).
    ///
    /// Side effect: if Sutando hasn't been granted yet, this fires
    /// the native TCC consent dialog. That's intentional on the
    /// macOS-26 path — it gives the user a second one-click path to
    /// grant (alongside the System Settings deeplink), and a single
    /// prompt isn't subject to the "back-to-back dialog" trap that
    /// `triggerHelperScreenAccess()` is documented to avoid.
    static func registerSutandoInScreenRecordingTCC() {
        let tmpPath = NSTemporaryDirectory()
            + "sutando-tcc-register-\(UUID().uuidString).png"
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        // `-x` suppresses the camera shutter sound. `-t png` matches
        // the helper for parity. The tmp file is only written if we
        // already have permission; cleanup is best-effort either way.
        task.arguments = ["-x", "-t", "png", tmpPath]
        do {
            try task.run()
        } catch {
            return
        }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }
    }

    /// Provoke the bundled screen-capture supervisor's python child into
    /// attempting Screen Recording so it appears in System Settings (and
    /// to surface a TCC prompt when we don't yet have a grant).
    ///
    /// Behavior depends on current grant state:
    ///   - Granted     → fire one /capture against the supervisor as a
    ///     smoke test. Responsibility rolls up to Sutando.app, so no
    ///     extra TCC prompt is shown.
    ///   - Not granted → no-op. We deliberately do NOT spawn a second
    ///     screencapture process here. macOS owns the consent dialog,
    ///     and back-to-back screencapture calls under a missing grant
    ///     queue back-to-back dialogs — the user clicks "Open System
    ///     Settings" on one and a fresh one springs up a beat later,
    ///     making the dialog look like it never dismissed. The dev/UX
    ///     path for "not granted yet" is: open the System Settings
    ///     deeplink (callers already do this) and let the user grant
    ///     once. The supervisor's /capture path is gated server-side
    ///     by the same CGPreflightScreenCaptureAccess check (see
    ///     `src/screen-capture-server.py::_has_screen_recording_permission`),
    ///     so accidental hits while ungranted also no-op without a
    ///     prompt.
    static func triggerHelperScreenAccess() {
        guard CGPreflightScreenCaptureAccess() else { return }
        if let url = URL(string: "http://localhost:7845/capture") {
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
        }
    }

    enum Status {
        case granted, denied, notDetermined, unknown
        var symbol: String {
            switch self {
            case .granted: return "✓"
            case .denied: return "✗"
            case .notDetermined: return "○"
            case .unknown: return "?"
            }
        }
        var color: NSColor {
            switch self {
            case .granted: return .systemGreen
            case .denied: return .systemRed
            case .notDetermined, .unknown: return .secondaryLabelColor
            }
        }
    }
}
