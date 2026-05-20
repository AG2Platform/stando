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

// Workspace dir — `$SUTANDO_WORKSPACE`, default `~/.sutando/workspace/`.
private func _sutandoHomeForCloudClient() -> String {
    if let ws = ProcessInfo.processInfo.environment["SUTANDO_WORKSPACE"], !ws.isEmpty {
        return (ws as NSString).expandingTildeInPath
    }
    return NSHomeDirectory() + "/.sutando/workspace"
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

/// Tier-usage row mirroring the cloud's `UsagePanelRow` (lib/usage-rollup.ts).
struct CloudUsagePanelRow: Decodable {
    let group: String
    let currentCanonical: Double
    let capCanonical: Double
    let percent: Double
    let displayUnit: String
    let overCap: Bool
    let managedInCurrentRelease: Bool
}

/// Active plan comp (Wave 4.2) returned inside CloudMeSnapshot.
struct CloudCompInfo: Decodable {
    let active: Bool
    let plan: String                 // 'plus' | 'pro' | 'max'
    let reason: String               // 'beta_admission' | 'influencer' | ...
    let startsAt: String             // ISO date
    let endsAt: String               // ISO date
    let monthlyCreditGrant: Int
    let daysRemaining: Int
}

/// Current-user snapshot returned by GET /api/me.
struct CloudMeSnapshot: Decodable {
    let id: String
    let email: String
    let plan: String
    // paidPlan + effectivePlan land in Wave 4.2; older builds will see them
    // absent and fall back to the legacy `plan` field. Decodable handles
    // missing-field by leaving the optional nil.
    let paidPlan: String?
    let effectivePlan: String?
    let geminiMode: String?          // 'byok' | 'managed'
    let comp: CloudCompInfo?
    let walletCredits: Int
    let autoTopupEnabled: Bool
    let autoTopupThresholdCredits: Int
    let hasSavedPaymentMethod: Bool
    let usagePanel: [CloudUsagePanelRow]
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

    /// Async GET /api/me. Used by the Settings tier panel. Returns nil
    /// when signed out, network errors, or the server returns
    /// non-success. Caller MUST hop to the main thread before touching
    /// UI with the result.
    static func fetchMe(completion: @escaping (CloudMeSnapshot?) -> Void) {
        guard let auth = _loadCloudAuth() else { completion(nil); return }
        guard let url = URL(string: auth.apiBase + "/api/me") else { completion(nil); return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "GET"
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                NSLog("CloudClient: GET /api/me failed: \(error.localizedDescription)")
                completion(nil); return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data else {
                completion(nil); return
            }
            do {
                let snap = try JSONDecoder().decode(CloudMeSnapshot.self, from: data)
                completion(snap)
            } catch {
                NSLog("CloudClient: /api/me decode failed: \(error)")
                completion(nil)
            }
        }
        task.resume()
    }

    /// Toggle the user's auto-topup preference. Fire-and-forget; the
    /// next /api/me fetch will reflect the new state.
    static func updateAutoTopup(enabled: Bool?, thresholdCredits: Int?) {
        var body: [String: Any] = [:]
        if let enabled = enabled { body["autoTopupEnabled"] = enabled }
        if let thresholdCredits = thresholdCredits { body["autoTopupThresholdCredits"] = thresholdCredits }
        guard !body.isEmpty, let auth = _loadCloudAuth(),
              let url = URL(string: auth.apiBase + "/api/me"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = payload
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - Skills inventory (Wave 4.10)

    /// One installed skill row from /api/me/inventory.
    struct CloudInstalledSkill: Decodable {
        let skillId: String
        let slug: String
        let name: String
        let description: String?
        let version: String
        let tierRequired: String
        let priceCredits: Int
        let installedAt: String
        let userRating: Int?
    }

    /// One activated cloud tool row from /api/me/inventory.
    struct CloudActivatedTool: Decodable {
        let skillId: String
        let slug: String
        let name: String
        let description: String?
        let version: String
        let tierRequired: String
        let unitPriceCredits: Double?
        let unitLabel: String?
        let callsThisPeriod: Int
        let creditsDebitedThisPeriod: Double
        let lastCallAt: String?
        let userRating: Int?
    }

    /// Combined response shape from GET /api/me/inventory.
    struct CloudInventory: Decodable {
        let installed: [CloudInstalledSkill]
        let cloudTools: [CloudActivatedTool]
    }

    /// Fetch the user's installed skills + activated cloud tools.
    /// Returns nil when signed out or on network errors. Caller MUST
    /// hop to the main thread before touching UI.
    static func fetchInventory(completion: @escaping (CloudInventory?) -> Void) {
        guard let auth = _loadCloudAuth() else { completion(nil); return }
        guard let url = URL(string: auth.apiBase + "/api/me/inventory") else { completion(nil); return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "GET"
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, error in
            if error != nil { completion(nil); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data else { completion(nil); return }
            do {
                let inv = try JSONDecoder().decode(CloudInventory.self, from: data)
                completion(inv)
            } catch {
                NSLog("CloudClient: /api/me/inventory decode failed: \(error)")
                completion(nil)
            }
        }.resume()
    }

    enum UninstallResult {
        case ok
        case notFound
        case failure(String)
    }

    /// Uninstall a skill or deactivate a cloud tool. `slugOrId` accepts
    /// either the skill slug (recommended) or its UUID. For paid
    /// skills, reinstall via the Station re-charges price_credits —
    /// surface that in the caller's confirmation copy.
    static func uninstallSkill(_ slugOrId: String, completion: @escaping (UninstallResult) -> Void) {
        guard let auth = _loadCloudAuth(),
              let encoded = slugOrId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: auth.apiBase + "/api/skills/\(encoded)/uninstall") else {
            completion(.failure("not signed in")); return
        }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error = error { completion(.failure(error.localizedDescription)); return }
            guard let http = response as? HTTPURLResponse else { completion(.failure("no response")); return }
            if http.statusCode == 404 { completion(.notFound); return }
            if (200..<300).contains(http.statusCode) { completion(.ok); return }
            completion(.failure("HTTP \(http.statusCode)"))
        }.resume()
    }

    /// Set the user's Gemini mode (Wave 4.8). Server rejects 'managed'
    /// for free effectivePlan with HTTP 402; completion fires with
    /// `.requiresPaid` so the UI can surface "upgrade to use managed
    /// Gemini". Network errors complete `.failure` — caller may retry.
    enum GeminiModeResult {
        case ok
        case requiresPaid
        case failure(String)
    }

    static func setGeminiMode(_ mode: String, completion: @escaping (GeminiModeResult) -> Void) {
        guard let auth = _loadCloudAuth(),
              let url = URL(string: auth.apiBase + "/api/me"),
              let payload = try? JSONSerialization.data(withJSONObject: ["geminiMode": mode]) else {
            completion(.failure("not signed in")); return
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = payload
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error = error {
                completion(.failure(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure("no response"))
                return
            }
            if http.statusCode == 402 { completion(.requiresPaid); return }
            if (200..<300).contains(http.statusCode) { completion(.ok); return }
            completion(.failure("HTTP \(http.statusCode)"))
        }.resume()
    }
}
