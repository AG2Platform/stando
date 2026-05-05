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
        case .screenRecording: return "Required for describe_screen and screen-record."
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion(self.status())
            }
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
