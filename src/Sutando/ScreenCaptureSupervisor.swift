import Foundation
import AppKit

/// Supervises `src/screen-capture-server.py` as a direct child process of
/// the Sutando.app menu-bar binary.
///
/// Why not launchd?
/// macOS TCC (Screen Recording) grants are tracked per-binary, but TCC
/// also tracks a "responsible process" — the parent app whose grant
/// applies to subprocesses that touch protected resources. When launchd
/// spawns a service, the responsible process is launchd itself, so the
/// service needs its OWN Screen Recording grant (which the user usually
/// hasn't given because they only see "Sutando" in System Settings —
/// not the obscure `/Applications/Xcode.app/.../Python` binary that
/// `/usr/bin/python3` actually resolves to). The capture silently fails
/// with `screencapture: could not create image from display`.
///
/// When Sutando.app spawns the same Python script via `Process()`
/// (posix_spawn under the hood), the responsible process attribution
/// rolls up to Sutando.app — so Sutando's Screen Recording grant covers
/// the screencapture call inside the child. One TCC entry, granted
/// during onboarding, works forever.
///
/// Also handles:
///   - Restart on crash (with backoff) so a transient failure doesn't
///     leave the agent unable to see the screen until the next app
///     restart.
///   - Migration: bootout the legacy `com.sutando.screen-capture`
///     launchd job on first start so we don't fight over port 7845.
///   - Clean shutdown via SIGTERM in `stop()` (called from
///     applicationWillTerminate) so port 7845 is released for the next
///     Sutando launch.
final class ScreenCaptureSupervisor {
    private var process: Process?
    private var stopping = false
    private var lastStartAt: Date = .distantPast
    private var consecutiveFailures = 0
    private let queue = DispatchQueue(label: "com.sutando.screen-capture-supervisor")

    /// Path to the bundled `screen-capture-server.py`. Resolved from the
    /// .app bundle (`Resources/repo/src/...`); falls back to the dev
    /// workspace path so this works for raw-binary runs too.
    private let scriptPath: String
    private let pythonPath: String
    private let logPath: String
    private let sutandoHome: String

    init(workspace: String, sutandoHome: String) {
        self.sutandoHome = sutandoHome
        let logDir = sutandoHome + "/logs"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        self.logPath = logDir + "/screen-capture.log"

        // Prefer the bundle-staged copy so the script path is stable
        // across app upgrades. Dev fallback walks the workspace.
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = resourcePath + "/repo/src/screen-capture-server.py"
            if FileManager.default.fileExists(atPath: bundled) {
                self.scriptPath = bundled
            } else {
                self.scriptPath = workspace + "/src/screen-capture-server.py"
            }
        } else {
            self.scriptPath = workspace + "/src/screen-capture-server.py"
        }

        // Stick with /usr/bin/python3 — only really used as a launcher,
        // since the responsible-process attribution we care about is
        // Sutando.app (us), not the python binary.
        self.pythonPath = "/usr/bin/python3"
    }

    /// Bootout any leftover launchd-managed screen-capture service from
    /// older Sutando installs. Safe to call when the service doesn't
    /// exist (launchctl bootout returns non-zero, which we ignore).
    private func evictLegacyLaunchdJob() {
        let labels = [
            "com.sutando.screen-capture",
        ]
        let uid = getuid()
        for label in labels {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["bootout", "gui/\(uid)/\(label)"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()

            // Also remove the rendered plist so a future install pass
            // doesn't bring it back. The template file in the bundle
            // is left in place for now (in case a release rolls back),
            // but the rendered copy under SUTANDO_HOME shouldn't exist.
            let plist = sutandoHome + "/LaunchAgents/\(label).plist"
            try? FileManager.default.removeItem(atPath: plist)
        }
    }

    /// Start the supervisor. Idempotent — calling twice is a no-op.
    func start() {
        queue.sync {
            guard process == nil, !stopping else { return }
            evictLegacyLaunchdJob()
            // Give launchd a beat to release port 7845 before we bind.
            // 250ms is empirically enough on M1; if it isn't, the spawn
            // will fail fast and the restart loop covers us.
            Thread.sleep(forTimeInterval: 0.25)
            spawnLocked()
        }
    }

    /// Stop the supervisor and the running child. Called from
    /// applicationWillTerminate so cmd+Q tears down screen-capture
    /// alongside the launchd-managed services. Synchronous — port
    /// 7845 must be free before the next Sutando.app launch attempts
    /// to rebind.
    func stop() {
        queue.sync {
            stopping = true
            if let proc = process, proc.isRunning {
                // SIGTERM first; the python http.server handles the
                // KeyboardInterrupt path and exits cleanly. Fall back
                // to SIGKILL after 1s if it's still around.
                proc.terminate()
                let deadline = Date().addingTimeInterval(1.0)
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
            process = nil
        }
    }

    /// Internal: spawn the python child. Must be called inside `queue`
    /// to keep `process` access serialised.
    private func spawnLocked() {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            appendLog("supervisor: script missing at \(scriptPath); not starting")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            appendLog("supervisor: python missing at \(pythonPath); not starting")
            return
        }

        // Dedupe rapid restarts. 5 failures in 30s = give up until
        // explicit restart() (or app relaunch).
        if Date().timeIntervalSince(lastStartAt) < 30, consecutiveFailures >= 5 {
            appendLog("supervisor: backoff — \(consecutiveFailures) failures in last 30s, giving up")
            return
        }
        lastStartAt = Date()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath]
        proc.currentDirectoryURL = URL(fileURLWithPath: (scriptPath as NSString).deletingLastPathComponent + "/..")

        // Inherit a sensible PATH + carry SUTANDO_HOME so the script
        // writes screenshots under the right state root.
        var env = ProcessInfo.processInfo.environment
        env["SUTANDO_HOME"] = sutandoHome
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin"
        proc.environment = env

        // Append-mode log file matching the legacy launchd setup so
        // existing log-tailing flows keep working.
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let logHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            logHandle.seekToEndOfFile()
            proc.standardOutput = logHandle
            proc.standardError = logHandle
        }

        proc.terminationHandler = { [weak self] finished in
            self?.queue.async {
                guard let self = self else { return }
                let exitCode = finished.terminationStatus
                self.appendLog("supervisor: child exited with status \(exitCode)")
                self.process = nil
                if self.stopping { return }
                // Track consecutive failures vs. clean exits. A clean
                // exit (status 0) shouldn't happen for a long-running
                // server; treat it as a failure too so we restart.
                self.consecutiveFailures += 1
                let backoff = min(Double(self.consecutiveFailures), 5.0)
                self.queue.asyncAfter(deadline: .now() + backoff) { [weak self] in
                    guard let self = self else { return }
                    if !self.stopping {
                        self.spawnLocked()
                    }
                }
            }
        }

        do {
            try proc.run()
            process = proc
            // Reset the failure counter once the process has been alive
            // for 10s — at that point this start counts as healthy.
            queue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                guard let self = self else { return }
                if let p = self.process, p.isRunning {
                    self.consecutiveFailures = 0
                }
            }
            appendLog("supervisor: spawned pid=\(proc.processIdentifier) (responsible=Sutando.app)")
        } catch {
            appendLog("supervisor: failed to spawn — \(error)")
            consecutiveFailures += 1
        }
    }

    private func appendLog(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: data)
            return
        }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
