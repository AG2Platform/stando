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
            // wizard code calls explicitly on app activation (the
            // single moment when the user could have just toggled
            // Sutando off in System Settings).
            //
            // Order of trust within status():
            //   1. Most recent SCShareableContent result if it's
            //      under ~30s old (catches the toggle-off case that
            //      activation-driven probing was designed to detect).
            //   2. Sync checks: preflight + window-name probe. Both
            //      catch the grant case, neither prompts. Sticky
            //      after a runtime grant, but that's fine because
            //      revokes are caught by layer (1).
            if let live = Self.recentLiveScreenResult() {
                return live ? .granted : .notDetermined
            }
            if CGPreflightScreenCaptureAccess() { return .granted }
            return Self.canReadForeignWindowNames() ? .granted : .notDetermined
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
        liveScreenLock.lock()
        if liveScreenInFlight {
            liveScreenLock.unlock()
            return
        }
        liveScreenInFlight = true
        liveScreenLock.unlock()

        guard #available(macOS 12.3, *) else {
            liveScreenLock.lock()
            liveScreenInFlight = false
            liveScreenLock.unlock()
            return
        }

        Task.detached(priority: .utility) {
            let granted: Bool
            do {
                _ = try await SCShareableContent.current
                granted = true
            } catch {
                // SCShareableContent throws SCStreamError.userDeclined
                // when permission isn't granted. Anything else (window
                // server unavailable, etc.) we conservatively treat as
                // ungranted so the row stays ✗ rather than going stale-✓.
                granted = false
            }
            liveScreenLock.lock()
            liveScreenGranted = granted
            liveScreenAt = Date()
            liveScreenInFlight = false
            liveScreenLock.unlock()
        }
    }

    /// Live probe: returns true iff we can read at least one window name
    /// owned by a different process. macOS only populates `kCGWindowName`
    /// (and a few other identifying attributes) for foreign windows when
    /// the calling process holds Screen Recording permission. Used as a
    /// fast-path complement to SCShareableContent — catches grants
    /// without waiting for the async probe to settle, but (like preflight)
    /// is sticky after a runtime grant so it can't see revokes.
    private static func canReadForeignWindowNames() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let myPid = getpid()
        for window in windows {
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid != myPid else { continue }
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                return true
            }
        }
        return false
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

    /// Provoke the launchd-spawned python helpers into attempting Screen
    /// Recording so they appear alongside Sutando.app in System Settings.
    /// Best-effort — failures are silent because the goal is "show up in
    /// the list", not "successfully capture".
    static func triggerHelperScreenAccess() {
        // Path 1 — hit the running service. Uses the exact same python
        // binary launchd uses, so the right entry shows up. Fire-and-
        // forget; we don't care about the response.
        if let url = URL(string: "http://localhost:7845/capture") {
            URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
        }

        // Path 2 — direct python3 spawn. Runs in parallel with path 1 so
        // the prompt registration still happens even when no service is up
        // (e.g. very first run before "Install Background Services").
        DispatchQueue.global(qos: .utility).async {
            let candidates = [
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/usr/bin/python3",
            ]
            guard let pythonPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonPath)
            // Trigger BOTH Screen Recording (via /usr/sbin/screencapture)
            // AND System Audio Recording (via AVAudioEngine on a system
            // tap). The audio probe is a no-op on systems where ScreenCaptureKit
            // doesn't expose audio, and harmless when it does.
            proc.arguments = ["-c", """
            import subprocess, os, tempfile
            # Screen Recording trigger
            tmp = tempfile.mktemp(suffix='.png')
            subprocess.run(['/usr/sbin/screencapture', '-x', tmp], capture_output=True, timeout=3)
            try: os.remove(tmp)
            except OSError: pass
            """]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
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
