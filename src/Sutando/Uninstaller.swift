import AppKit
import Foundation

// Full in-app uninstall.
//
// Two-phase teardown because a running .app can't `rm -rf` itself:
//   1. From the live process, tear down everything except the .app bundle
//      and the UserDefaults plist (which the app rewrites on quit).
//   2. Spawn a detached helper script that waits for our PID to die,
//      removes the .app and the plist, then deletes itself.
//
// Caller fires `performUninstall(keepUserData:)` and the app terminates
// itself ~immediately. There is no "undo" — the confirmation prompt
// lives in SettingsWindow.swift.

enum Uninstaller {

    /// Perform the full uninstall and terminate the app.
    /// Runs steps 1–N inline on a background queue, then schedules
    /// `NSApp.terminate(nil)` on the main queue once the helper script
    /// has been spawned.
    ///
    /// - Parameter keepUserData: when true, preserves
    ///   `~/Library/Application Support/Sutando/` (`.env`, results,
    ///   notes). When false, that directory is removed too.
    static func performUninstall(keepUserData: Bool) {
        let bundlePath = Bundle.main.bundlePath
        let appPid = ProcessInfo.processInfo.processIdentifier
        let home = NSHomeDirectory()

        DispatchQueue.global(qos: .userInitiated).async {
            // 1. Stop launchd services + the leftover core-agent tmux.
            _ = LaunchAgentInstaller().uninstall()

            // 2. Sign out of cloud (clears keychain + cloud-auth.json).
            CloudAuth.shared.signOut()

            // 3. Remove skill symlinks that point into our .app bundle.
            //    Don't blow away the user's own skills — only ours.
            let skillsDir = home + "/.claude/skills"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: skillsDir) {
                for entry in entries {
                    let path = skillsDir + "/" + entry
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                    if !exists { continue }
                    if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                       dest.contains("Sutando.app/Contents/Resources/repo/skills/") {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                }
            }

            // 4. App-scoped state under ~/Library. Preferences plist is
            //    handled in the helper script — the app rewrites it on
            //    quit, so deleting it now is racy.
            let libraryItems = [
                home + "/Library/Caches/com.sutando.app",
                home + "/Library/HTTPStorages/com.sutando.app",
                home + "/Library/WebKit/com.sutando.app",
                home + "/Library/Saved Application State/com.sutando.app.savedState",
            ]
            for path in libraryItems {
                try? FileManager.default.removeItem(atPath: path)
            }

            // 5. User data — only if the user opted out of "keep my settings".
            if !keepUserData {
                let support = home + "/Library/Application Support/Sutando"
                try? FileManager.default.removeItem(atPath: support)
            }

            // 6. TCC permissions. Best-effort — `tccutil` may not be on
            //    PATH from launchd-spawned children, but System Settings
            //    will still show the entry until reset.
            let tcc = Process()
            tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tcc.arguments = ["reset", "All", "com.sutando.app"]
            tcc.standardOutput = FileHandle.nullDevice
            tcc.standardError = FileHandle.nullDevice
            try? tcc.run()
            tcc.waitUntilExit()

            // 7. Spawn the detached helper. Only delete the .app if we
            //    were actually launched from a .app bundle — dev users
            //    running the raw binary from a build dir would lose
            //    their checkout otherwise.
            let removeBundle = bundlePath.hasSuffix(".app")
            spawnFinishHelper(appPid: appPid,
                              bundlePath: removeBundle ? bundlePath : nil,
                              home: home)

            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    /// Write a /tmp shell script that waits for our PID to exit, removes
    /// the .app and the UserDefaults plist, then self-deletes. Spawn it
    /// detached so it survives our termination.
    private static func spawnFinishHelper(appPid: Int32, bundlePath: String?, home: String) {
        let scriptPath = "/tmp/sutando-uninstall-\(appPid)-\(UUID().uuidString.prefix(8)).sh"
        let prefsPlist = home + "/Library/Preferences/com.sutando.app.plist"

        let bundleRm: String
        if let bundlePath = bundlePath {
            // Single-quote the path to handle spaces; escape any embedded
            // single quotes by closing-escape-reopening.
            bundleRm = "rm -rf '\(bundlePath.replacingOccurrences(of: "'", with: "'\\''"))'"
        } else {
            bundleRm = "# (skipped: not launched from a .app bundle)"
        }

        let script = """
        #!/bin/bash
        # Sutando uninstall finisher — auto-generated, deletes itself.
        while kill -0 \(appPid) 2>/dev/null; do sleep 0.2; done
        sleep 0.5
        \(bundleRm)
        defaults delete com.sutando.app 2>/dev/null
        rm -f '\(prefsPlist.replacingOccurrences(of: "'", with: "'\\''"))'
        rm -f '\(scriptPath)'
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}
