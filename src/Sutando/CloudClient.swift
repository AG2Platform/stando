import Foundation

// Swift-side cloud telemetry. Mirrors the surface that lives in
// src/cloud-client.ts (Node) and src/cloud_metrics.py (Python). The
// menu bar app emits onboarding milestones (Settings stepper
// checkpoints) and error events (LaunchAgentInstaller failures);
// usage_events stay in the Node services where the actual work happens.
//
// Reads the auth record from $SUTANDO_HOME/cloud-auth.json — the same
// file CloudAuth.swift writes on sign-in. We read on every call so
// sign-out from the menu takes effect without restarting the app.
//
// All sends are fire-and-forget. Telemetry must NEVER crash the caller.

private struct _CloudAuthRecord: Decodable {
    let token: String
    let userId: String
    let apiBase: String
}

private func _sutandoHomeForCloudClient() -> String {
    if let home = ProcessInfo.processInfo.environment["SUTANDO_HOME"], !home.isEmpty {
        return (home as NSString).expandingTildeInPath
    }
    // Mirror CloudAuth.swift's dev fallback: walk up looking for CLAUDE.md.
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

private func _loadCloudAuth() -> _CloudAuthRecord? {
    let path = _sutandoHomeForCloudClient() + "/cloud-auth.json"
    guard FileManager.default.fileExists(atPath: path),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        return nil
    }
    return try? JSONDecoder().decode(_CloudAuthRecord.self, from: data)
}

private func _appVersion() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
}

private func _postJSON(path: String, body: [String: Any]) {
    guard let auth = _loadCloudAuth() else { return }
    guard let url = URL(string: auth.apiBase + path) else { return }
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
    var req = URLRequest(url: url, timeoutInterval: 5)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
    req.httpBody = payload
    let task = URLSession.shared.dataTask(with: req) { _, _, error in
        if let error = error {
            NSLog("CloudClient: POST \(path) failed: \(error.localizedDescription)")
        }
    }
    task.resume()
}

/// Approved onboarding steps. Anything else is dropped silently to
/// keep typos out of the funnel.
private let _knownOnboardingSteps: Set<String> = [
    "gemini_key_set",
    "claude_installed",
    "perms_granted",
    "services_installed",
    "firstrun_complete",
    "first_voice",
    "first_task",
    "first_phone",
    "first_image",
]

enum CloudErrorSeverity: String {
    case info, warn, error, fatal
}

enum CloudClient {
    /// Fire an onboarding milestone. Idempotent server-side
    /// (unique index on user_id+step). No-op when not signed in.
    static func recordOnboarding(_ step: String, metadata: [String: Any]? = nil) {
        guard _knownOnboardingSteps.contains(step) else { return }
        var event: [String: Any] = ["step": step]
        if let metadata = metadata { event["metadata"] = metadata }
        let body: [String: Any] = ["events": [event]]
        _postJSON(path: "/api/onboarding", body: body)
    }

    /// Report an error to the cloud reliability board.
    static func recordError(
        kind: String,
        severity: CloudErrorSeverity,
        message: String,
        metadata: [String: Any]? = nil
    ) {
        var event: [String: Any] = [
            "kind": kind,
            "severity": severity.rawValue,
            "message": String(message.prefix(2000)),
            "appVersion": _appVersion(),
        ]
        if let metadata = metadata { event["metadata"] = metadata }
        let body: [String: Any] = ["events": [event]]
        _postJSON(path: "/api/errors", body: body)
    }
}
