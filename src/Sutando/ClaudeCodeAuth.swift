import Foundation
import AppKit
import Security

// Shared Claude Code probing + sign-in subprocess driver.
//
// Used by both OnboardingWindow (first-launch wizard) and SettingsWindow
// (Settings → Claude Code section). Keeping the install-detect,
// keychain-probe, and `claude auth login --claudeai` orchestration in
// one place means both surfaces get the same fixes for things like the
// keychain-ACL false-negative and the inline OAuth paste flow.
//
// This file deliberately owns NO UI of its own — both windows render
// their own row/panel views. The shared layer hands them:
//   - `ClaudeCodeState` to switch on
//   - `ClaudeCodeAuth.resolveBinary()` / `.probeState()` to query
//   - `ClaudeCodeAuthSession` to drive the OAuth subprocess
//
// Keep this layer dependency-free (no AppDelegate, no Theme) so it can
// be unit-tested or reused from a future CLI surface without dragging
// the whole app graph in.

enum ClaudeCodeState {
    case notInstalled
    case notSignedIn
    case signedIn
    case unknown
}

enum ClaudeCodeAuth {
    /// Resolve the `claude` binary on PATH or the well-known install
    /// locations the official installer + Homebrew + npm use. Settings
    /// inherits a sparse PATH from launchd, so we have to widen the
    /// search ourselves.
    static func resolveBinary() -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs.append(contentsOf: [
            NSHomeDirectory() + "/.local/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            NSHomeDirectory() + "/.npm-global/bin",
        ])
        for dir in dirs where !dir.isEmpty {
            let path = dir + "/claude"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Probe Claude Code's install + sign-in state.
    ///
    /// We intentionally don't trust `claude auth status` alone. When
    /// `claude` is spawned as a child of Sutando.app, the macOS keychain
    /// ACL on the `Claude Code-credentials` entry can silently deny the
    /// keychain read because the binary's caller-context doesn't match
    /// the one the entry was created under (Terminal / a previous build).
    /// In that case the CLI honestly reports `loggedIn: false` even
    /// though the OAuth token is sitting right there in the keychain.
    ///
    /// To get out of that pit, after the CLI says "not signed in" we
    /// look directly at the `Claude Code-credentials` generic-password
    /// item via the Security framework. Querying metadata only (no
    /// `kSecReturnData`) doesn't trigger the ACL prompt and works
    /// regardless of caller context, so existence of the entry is a
    /// reliable signal on its own.
    static func probeState(_ done: @escaping (ClaudeCodeState) -> Void) {
        guard let path = resolveBinary() else {
            done(.notInstalled)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["auth", "status"]
            // Strip TTY: the CLI prints a legacy "Not logged in · /login"
            // banner to stderr when stdin looks like a terminal.
            proc.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                DispatchQueue.main.async { done(.notInstalled) }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            let cliSignedIn = out.contains("\"loggedIn\"") && out.contains("\"loggedIn\":true")
                && proc.terminationStatus == 0
            if cliSignedIn {
                DispatchQueue.main.async { done(.signedIn) }
                return
            }
            let keychainSignedIn = hasValidKeychainEntry()
            DispatchQueue.main.async {
                done(keychainSignedIn ? .signedIn : .notSignedIn)
            }
        }
    }

    /// True if the macOS login keychain holds a `Claude Code-credentials`
    /// generic-password item. We don't read the password (that would
    /// trigger the ACL prompt); existence is enough to distinguish
    /// "user signed in via the CLI at some point" from "completely
    /// fresh install". A false positive (entry exists but expired) just
    /// means the user will hit the failure later and can re-sign-in.
    static func hasValidKeychainEntry() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            // CRITICAL: do NOT set kSecReturnData. Reading the password
            // requires ACL approval (and prompts the user). Reading
            // attributes does not.
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess && item != nil
    }

    /// Run `curl -fsSL https://claude.ai/install.sh | bash` asynchronously.
    /// Callback receives `(success, lastLinesOfOutput)` on the main queue.
    /// The official installer lands the binary at ~/.local/bin/claude
    /// (no sudo) and updates the user's shell rc.
    static func runInstaller(_ done: @escaping (_ success: Bool, _ output: String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            // -l so the installer's PATH lookups (curl, install -d) pick up
            // Homebrew + system paths cleanly; -c for the inline pipeline.
            proc.arguments = ["-lc", "curl -fsSL https://claude.ai/install.sh | bash"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var output = ""
            var success = false
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output = String(data: data, encoding: .utf8) ?? ""
                success = proc.terminationStatus == 0
            } catch {
                output = error.localizedDescription
            }
            DispatchQueue.main.async { done(success, output) }
        }
    }
}

/// Drives `claude auth login --claudeai` as a long-lived subprocess.
///
/// Lifecycle:
///   1. `start()` spawns the CLI, pipes stdin + stdout + stderr.
///   2. Stdout is parsed for the OAuth URL → `onURL` fires (and the
///      caller should `NSWorkspace.shared.open(url)` + reveal a paste
///      field).
///   3. Caller pipes the user's authorization code in via
///      `submitCode(_:)`. CLI exchanges + writes keychain + exits.
///   4. Process termination → `onExit(status)` fires on the main queue.
///
/// The session also fires `onURL` only once per session (we cache the
/// URL); subsequent stdout chunks just update internal state. It's safe
/// to call `cancel()` from any state — the subprocess is terminated and
/// stdin is closed.
///
/// Why not Terminal.app: AppleScript Terminal automation requires an
/// Automation TCC grant the user hasn't given on first launch, so the
/// previous "open Terminal and run claude" flow died with "Couldn't
/// open Terminal" before the user even knew what we were trying to do.
final class ClaudeCodeAuthSession {
    /// Fires once when the OAuth URL is parsed out of CLI stdout.
    var onURL: ((String) -> Void)?
    /// Fires when the subprocess exits. status 0 == success, otherwise
    /// the CLI rejected the code / hit a network error / was cancelled.
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutBuffer = ""
    private var capturedURL: String?

    var url: String? { capturedURL }
    var isRunning: Bool { process != nil }

    /// Spawn the CLI. Throws if the binary can't be found or NSTask
    /// rejects the launch. Callers should `applyState` to the UI
    /// optimistically and let `onExit` flip back on error.
    func start() throws {
        guard let path = ClaudeCodeAuth.resolveBinary() else {
            throw NSError(domain: "ClaudeCodeAuth", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Claude Code binary not found on PATH"
            ])
        }
        if process != nil {
            // Idempotent — caller is welcome to call start() twice; we
            // just keep the existing session.
            return
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        // --claudeai is the default today but we pass it explicitly so a
        // future CLI default change doesn't silently switch us to --console.
        proc.arguments = ["auth", "login", "--claudeai"]
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        process = proc
        stdin = stdinPipe.fileHandleForWriting
        stdoutBuffer = ""
        capturedURL = nil

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.stdoutBuffer += chunk
                self.parseURLIfNeeded()
            }
        }
        // Drain stderr to avoid PIPE-full deadlock; nothing in the
        // current CLI's stderr we need to act on, but a future version
        // might route the URL there.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                try? self.stdin?.close()
                self.stdin = nil
                self.onExit?(p.terminationStatus)
            }
        }
        try proc.run()
    }

    /// Pipe the user-supplied authorization code to the CLI's stdin.
    /// The CLI reads a single line and exchanges it for an OAuth token.
    func submitCode(_ code: String) {
        guard let stdin = stdin else { return }
        if let data = (code + "\n").data(using: .utf8) {
            stdin.write(data)
        }
    }

    /// Terminate the subprocess and close stdin. Safe to call from any
    /// state; no-op if no session is in flight. Does NOT fire `onExit`
    /// directly — the kernel will, and the terminationHandler routes it.
    func cancel() {
        if let proc = process {
            proc.terminate()
        }
        process = nil
        try? stdin?.close()
        stdin = nil
    }

    private func parseURLIfNeeded() {
        guard capturedURL == nil else { return }
        for line in stdoutBuffer.split(separator: "\n") {
            let l = String(line).trimmingCharacters(in: .whitespaces)
            guard let range = l.range(of: "https://", options: .caseInsensitive) else { continue }
            let candidate = String(l[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            guard candidate.contains("claude.") || candidate.contains("anthropic.") else { continue }
            capturedURL = candidate
            onURL?(candidate)
            return
        }
    }
}
