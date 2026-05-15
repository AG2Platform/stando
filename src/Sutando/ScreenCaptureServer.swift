import Foundation
import Network
import UserNotifications
import CoreGraphics

// In-process screen-capture HTTP server.
//
// Replaces the Python launchd daemon (com.sutando.screen-capture) that
// shelled out to `screencapture` from /usr/bin/python3 — which on this
// machine resolves through `xcode-select` to Xcode's bundled Python.app,
// a binary TCC has never seen and silently denies. The result was an
// infinite "could not create image from display" loop in the log no
// matter how many Python entries the user toggled on in System Settings.
//
// By serving /capture from inside Sutando.app itself, the `screencapture`
// child inherits the .app's TCC entitlement — Sutando.app is a single,
// stable, code-signed identity that the user grants Screen Recording
// permission to once. No more per-Python-binary roulette.
//
// API (preserved exactly from screen-capture-server.py — every existing
// caller in src/inline-tools.ts, src/browser-tools.ts, src/recording-tools.ts,
// src/Sutando/FeedbackWindow.swift, etc. keeps working):
//
//   GET /capture                  → { status: "ok", path: "..." }
//   GET /capture?display=N        → capture only display N (1..9)
//   GET /capture?all=true         → capture every display, returns first
//                                   path + { all_paths: [...], displays: N }
//   GET /ping                     → { pong: true }
//
// Side effects on /capture:
//   - Fire-and-forget POST to localhost:8080/mute-state?state=seeing
//     so the menu-bar avatar flashes "seeing" for ~1.5s.
//   - Debounced macOS notification ("Sutando captured screen"), opt-out
//     via SUTANDO_CAPTURE_NOTIFY=0.

class ScreenCaptureServer {
    static let shared = ScreenCaptureServer()

    private let queue = DispatchQueue(label: "com.sutando.screen-capture", qos: .userInitiated)
    private var listener: NWListener?
    private let screenshotDir: String
    private let port: NWEndpoint.Port
    private let webClientStateURL = URL(string: "http://localhost:8080/mute-state?state=seeing&ttl_ms=1500&source=tool")
    private let notifyEnabled: Bool
    private let notifyDebounceSeconds: TimeInterval = 5.0
    private var lastNotifyAt: Date = .distantPast
    private let notifyLock = NSLock()

    private init() {
        let env = ProcessInfo.processInfo.environment
        self.screenshotDir = env["SUTANDO_SCREENSHOT_DIR"] ?? "/tmp/sutando-screenshots"
        let portString = env["SCREEN_CAPTURE_PORT"] ?? "7845"
        self.port = NWEndpoint.Port(rawValue: UInt16(portString) ?? 7845) ?? NWEndpoint.Port(rawValue: 7845)!
        self.notifyEnabled = (env["SUTANDO_CAPTURE_NOTIFY"] ?? "1") != "0"
    }

    /// Bind the listener and start accepting connections. Idempotent —
    /// safe to call multiple times. Logs to stderr (forwarded to the .app
    /// log file in main.swift).
    func start() {
        if listener != nil {
            NSLog("ScreenCaptureServer: already running on port \(port.rawValue)")
            return
        }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            try? FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
            let lst = try NWListener(using: params, on: port)
            lst.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    NSLog("ScreenCaptureServer: listening on 127.0.0.1:\(self.port.rawValue)")
                case .failed(let err):
                    NSLog("ScreenCaptureServer: listener failed — \(err)")
                    self.listener = nil
                default:
                    break
                }
            }
            lst.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            lst.start(queue: queue)
            self.listener = lst
        } catch {
            NSLog("ScreenCaptureServer: bind failed on port \(port.rawValue) — \(error). Another process may already be listening (raw-binary dev workflow runs the Python server via startup.sh).")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Read up to 8KB of the request — far more than any GET line we
        // care about. The request body is irrelevant; we only need the
        // request line.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            self.dispatch(request: request, on: conn)
        }
    }

    private func dispatch(request: String, on conn: NWConnection) {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "GET" else {
            send(conn, status: 405, jsonBody: #"{"error":"method not allowed"}"#)
            return
        }
        let target = String(parts[1])
        let (path, query) = splitTarget(target)

        switch path {
        case "/capture":
            handleCapture(query: query, on: conn)
        case "/ping":
            send(conn, status: 200, jsonBody: #"{"pong":true}"#)
        default:
            send(conn, status: 404, jsonBody: #"{"error":"not found"}"#)
        }
    }

    private func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        let queryString = String(target[target.index(after: q)...])
        var dict: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0])
            let v = kv.count > 1 ? String(kv[1]) : ""
            dict[k] = v.removingPercentEncoding ?? v
        }
        return (path, dict)
    }

    // MARK: - /capture

    private func handleCapture(query: [String: String], on conn: NWConnection) {
        // Side-effects fire first, in parallel with the capture itself.
        signalSeeing()
        notifyCapture()

        let allDisplays = (query["all"]?.lowercased() == "true")
        // Constrain display index to 1..9 (matches the Python server's
        // taint-flow guard). Anything else → nil = capture main display.
        let display: Int? = {
            if let raw = query["display"], let n = Int(raw), (1...9).contains(n) {
                return n
            }
            return nil
        }()

        let timestamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()

        do {
            try FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
        } catch {
            send(conn, status: 500, jsonBody: jsonError("mkdir failed: \(error.localizedDescription)"))
            return
        }

        if allDisplays {
            var paths: [String] = []
            // Probe up to 4 displays. screencapture exits non-zero on
            // unknown -D, so we stop at the first failure.
            for d in 1...4 {
                let path = "\(screenshotDir)/screen-\(timestamp)-d\(d).png"
                let ok = runScreencapture(displayIndex: d, outputPath: path)
                if ok, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? UInt64, size > 0 {
                    paths.append(path)
                } else {
                    try? FileManager.default.removeItem(atPath: path)
                    break
                }
            }
            if paths.isEmpty {
                send(conn, status: 500, jsonBody: jsonError("screencapture returned no displays — Screen Recording permission likely missing"))
                return
            }
            var resp: [String: Any] = ["status": "ok", "path": paths[0]]
            if paths.count > 1 {
                resp["all_paths"] = paths
                resp["displays"] = paths.count
            }
            sendJSON(conn, status: 200, body: resp)
        } else {
            let suffix = display != nil ? "-d\(display!)" : ""
            let path = "\(screenshotDir)/screen-\(timestamp)\(suffix).png"
            if runScreencapture(displayIndex: display, outputPath: path) {
                sendJSON(conn, status: 200, body: ["status": "ok", "path": path])
            } else {
                send(conn, status: 500, jsonBody: jsonError("screencapture failed — Screen Recording permission likely missing for Sutando.app"))
            }
        }
    }

    /// Shell out to /usr/sbin/screencapture. `-x` suppresses the camera
    /// shutter sound. Optional `-D` selects a specific display. Returns
    /// true on exit code 0, file present, and non-zero size.
    private func runScreencapture(displayIndex: Int?, outputPath: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        var args = ["-x"]
        if let d = displayIndex {
            args.append("-D\(d)")
        }
        args.append(outputPath)
        proc.arguments = args
        let stderr = Pipe()
        proc.standardError = stderr
        proc.standardOutput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            NSLog("ScreenCaptureServer: spawn failed — \(error)")
            return false
        }
        // 5-second timeout — screencapture should complete in <500ms.
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { usleep(20_000) }
        if proc.isRunning {
            proc.terminate()
            NSLog("ScreenCaptureServer: screencapture timed out")
            return false
        }
        if proc.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("ScreenCaptureServer: screencapture exit \(proc.terminationStatus) — \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            return false
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath)
        let size = (attrs?[.size] as? UInt64) ?? 0
        return size > 0
    }

    // MARK: - Side effects

    private func signalSeeing() {
        guard let url = webClientStateURL else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.3
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    private func notifyCapture() {
        guard notifyEnabled else { return }
        notifyLock.lock()
        defer { notifyLock.unlock() }
        let now = Date()
        if now.timeIntervalSince(lastNotifyAt) < notifyDebounceSeconds { return }
        lastNotifyAt = now
        DispatchQueue.global(qos: .utility).async {
            // Prefer the notification framework when running as a real
            // .app bundle (UNUserNotificationCenter requires a bundle id).
            // Fall back to osascript otherwise so the dev raw-binary path
            // still surfaces the notification.
            if Bundle.main.bundleIdentifier != nil {
                let content = UNMutableNotificationContent()
                content.title = "Sutando"
                content.body = "Captured screen"
                let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
            } else {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", "display notification \"Captured screen\" with title \"Sutando\""]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
            }
        }
    }

    // MARK: - HTTP response helpers

    private func send(_ conn: NWConnection, status: Int, jsonBody: String) {
        let reason = httpReason(status)
        let body = Data(jsonBody.utf8)
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func sendJSON(_ conn: NWConnection, status: Int, body: [String: Any]) {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: body, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = #"{"status":"error","error":"json encode failed"}"#
        }
        send(conn, status: status, jsonBody: json)
    }

    private func jsonError(_ message: String) -> String {
        let safe = message.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"status\":\"error\",\"error\":\"\(safe)\"}"
    }

    private func httpReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
