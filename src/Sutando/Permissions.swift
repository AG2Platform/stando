import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

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
            // CGPreflightScreenCaptureAccess() avoids prompting; pair with
            // CGRequestScreenCaptureAccess() when the user explicitly clicks
            // a "request" button.
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        }
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
