import Foundation
import Security
import Cocoa

// Cloud-account integration: keychain-stored token, URL-scheme callback,
// device heartbeat, machine-ID provisioning. Pairs with the agent-universe
// cloud control plane (see /Users/lianghaochen/agent-universe).
//
// Sign-in flow:
//   1. User clicks menu → Sign in to Sutando…
//   2. CloudAuth generates a 32-char nonce, persists it to
//      $SUTANDO_HOME/cli-login-pending.json (with timestamp; expires after 5 min).
//   3. CloudAuth opens
//      https://<NEXT_PUBLIC_APP_URL>/cli-login?challenge=<nonce>&via=urlscheme
//      in the user's default browser.
//   4. Browser → Clerk auth (if needed) → mints API key →
//      redirects to sutando://auth?token=…&userId=…&challenge=<nonce>.
//   5. macOS launches Sutando.app with that URL; CloudAuth.handle(url:) sees
//      the auth event, validates the challenge against the pending file,
//      stores token in keychain, writes $SUTANDO_HOME/cloud-auth.json (mode
//      0600), persists machine_id, and POSTs /api/devices to register.

private let kKeychainService = "com.sutando.app.cloud"
private let kKeychainAccount = "default-token"
private let kKeychainUserId = "default-user-id"
private let kAuthFilename = "cloud-auth.json"
private let kPendingFilename = "cli-login-pending.json"
private let kDeviceFilename = "device.json"
private let kPendingExpirySeconds: TimeInterval = 300

struct CloudAuthRecord: Codable {
    var token: String
    var userId: String
    var machineId: String
    var apiBase: String
    var savedAt: TimeInterval
}

struct CloudPendingChallenge: Codable {
    var challenge: String
    var startedAt: TimeInterval
}

struct CloudDeviceRecord: Codable {
    var machineId: String
    var hostname: String
}

// MARK: - Path helpers

private func sutandoHome() -> String {
    if let home = ProcessInfo.processInfo.environment["SUTANDO_HOME"], !home.isEmpty {
        return (home as NSString).expandingTildeInPath
    }
    // Dev / raw-binary fallback: parent of the repo (matches main.swift's
    // `workspace` / `stateRoot` choice).
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

private func cloudAuthFile() -> String { sutandoHome() + "/" + kAuthFilename }
private func cliLoginPendingFile() -> String { sutandoHome() + "/" + kPendingFilename }
private func deviceFile() -> String { sutandoHome() + "/" + kDeviceFilename }

private func apiBaseURL() -> String {
    if let env = ProcessInfo.processInfo.environment["SUTANDO_CLOUD_URL"], !env.isEmpty {
        return env
    }
    if let plistBase = Bundle.main.object(forInfoDictionaryKey: "SutandoCloudURL") as? String,
       !plistBase.isEmpty {
        return plistBase
    }
    return "https://sutando.ag2.ai"
}

private func loginURL(challenge: String) -> URL? {
    var components = URLComponents(string: apiBaseURL())
    components?.path = "/cli-login"
    components?.queryItems = [
        URLQueryItem(name: "challenge", value: challenge),
        URLQueryItem(name: "via", value: "urlscheme"),
    ]
    return components?.url
}

// MARK: - Keychain helpers

private func keychainStore(account: String, value: String) -> Bool {
    let data = Data(value.utf8)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kKeychainService,
        kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(insert as CFDictionary, nil)
    return status == errSecSuccess
}

private func keychainLoad(account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kKeychainService,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data,
          let s = String(data: data, encoding: .utf8) else {
        return nil
    }
    return s
}

private func keychainDelete(account: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kKeychainService,
        kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
}

// MARK: - File helpers

private func writeJSON<T: Encodable>(_ value: T, to path: String, mode: mode_t = 0o600) -> Bool {
    do {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(value)
        let tmp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        chmod(tmp, mode)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        return true
    } catch {
        try? FileManager.default.removeItem(atPath: path + ".tmp")
        return false
    }
}

private func readJSON<T: Decodable>(_ type: T.Type, from path: String) -> T? {
    guard FileManager.default.fileExists(atPath: path),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    let dec = JSONDecoder()
    return try? dec.decode(type, from: data)
}

// MARK: - Machine ID

func cloudMachineId() -> String {
    if let rec = readJSON(CloudDeviceRecord.self, from: deviceFile()) {
        return rec.machineId
    }
    let id = UUID().uuidString
    let host = (Host.current().localizedName ?? Host.current().name ?? "mac")
    _ = writeJSON(CloudDeviceRecord(machineId: id, hostname: host), to: deviceFile(), mode: 0o644)
    return id
}

// MARK: - Public API

extension Notification.Name {
    /// Posted on the main thread after `CloudAuth.handle(url:)` accepts
    /// a sutando:// auth callback and persists the new record. Observers
    /// (e.g. memory backup hydrate) can trigger one-shot setup work.
    static let cloudAuthDidSignIn = Notification.Name("CloudAuthDidSignIn")
}

final class CloudAuth {
    /// Singleton. Created lazily — safe to construct from main.swift's
    /// `applicationDidFinishLaunching`.
    static let shared = CloudAuth()

    /// True if a token is currently stored. Reads from disk every call so
    /// the menu can update state after an external sign-out.
    var isSignedIn: Bool { record() != nil }

    /// Read the current auth record (token + userId + machineId + base URL).
    func record() -> CloudAuthRecord? {
        readJSON(CloudAuthRecord.self, from: cloudAuthFile())
    }

    /// Begin a sign-in flow. Generates a fresh challenge, persists it,
    /// opens the browser. Returns the challenge so the caller can log it.
    @discardableResult
    func startSignIn() -> String {
        let challenge = makeNonce()
        let pending = CloudPendingChallenge(challenge: challenge, startedAt: Date().timeIntervalSince1970)
        _ = writeJSON(pending, to: cliLoginPendingFile(), mode: 0o600)
        if let url = loginURL(challenge: challenge) {
            NSWorkspace.shared.open(url)
        }
        return challenge
    }

    /// Handle an incoming sutando:// URL. Returns true if the URL was an
    /// auth callback we recognized and processed (whether or not it succeeded).
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "sutando", url.host == "auth" else { return false }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let q = comps.queryItems ?? []
        func value(_ name: String) -> String? { q.first(where: { $0.name == name })?.value }
        guard let token = value("token"), !token.isEmpty,
              let userId = value("userId"), !userId.isEmpty,
              let challenge = value("challenge"), !challenge.isEmpty else {
            return true
        }
        // Verify challenge matches the one we started — and that it's recent.
        guard let pending = readJSON(CloudPendingChallenge.self, from: cliLoginPendingFile()),
              pending.challenge == challenge,
              Date().timeIntervalSince1970 - pending.startedAt < kPendingExpirySeconds else {
            NSLog("CloudAuth: challenge mismatch or expired — discarding callback")
            return true
        }
        try? FileManager.default.removeItem(atPath: cliLoginPendingFile())

        let machineId = cloudMachineId()
        let record = CloudAuthRecord(
            token: token,
            userId: userId,
            machineId: machineId,
            apiBase: apiBaseURL(),
            savedAt: Date().timeIntervalSince1970
        )
        _ = keychainStore(account: kKeychainAccount, value: token)
        _ = keychainStore(account: kKeychainUserId, value: userId)
        _ = writeJSON(record, to: cloudAuthFile(), mode: 0o600)

        // Fire a heartbeat to register the device. Best-effort, async.
        DispatchQueue.global(qos: .utility).async {
            self.heartbeat()
        }
        // Notify observers — main.swift kicks off cloud-memory hydrate
        // when the user signs in on a fresh Mac.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cloudAuthDidSignIn, object: nil)
        }
        return true
    }

    /// POST /api/devices — registers (or updates) this machine.
    func heartbeat() {
        guard let rec = record() else { return }
        guard let url = URL(string: rec.apiBase + "/api/devices") else { return }
        let host = (Host.current().localizedName ?? Host.current().name ?? "mac")
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let body: [String: String] = [
            "machineId": rec.machineId,
            "hostname": host,
            "appVersion": appVersion,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(rec.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = payload
        let task = URLSession.shared.dataTask(with: req) { _, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                NSLog("CloudAuth: heartbeat got 401 — token invalid, signing out")
                self.signOut()
            } else if let error = error {
                NSLog("CloudAuth: heartbeat error: \(error.localizedDescription)")
            }
        }
        task.resume()
    }

    /// Forget the cached credentials. Doesn't revoke server-side; that
    /// happens later via /api/auth/revoke (Phase 4 stretch).
    func signOut() {
        keychainDelete(account: kKeychainAccount)
        keychainDelete(account: kKeychainUserId)
        try? FileManager.default.removeItem(atPath: cloudAuthFile())
    }

    private func makeNonce() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        for _ in 0..<32 {
            out.append(alphabet.randomElement()!)
        }
        return out
    }
}
