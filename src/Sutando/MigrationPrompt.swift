// One-time migration prompt for existing 0.4.x (native) users.
//
// The 0.5.0 app is a re-architected Electron build shipped from a separate repo
// (AG2Platform/stando-ui) with its own auto-updater — Sparkle can't hand off to
// it across app types. So this final native build (0.4.1) tells signed-in users
// about the move and, on their click, downloads the new dmg through the cloud
// download proxy (authenticated with the app's existing Bearer token) and opens
// it for a drag install. The shared bundle id + ~/.sutando/workspace mean their
// keys, sign-in, and memory carry over automatically.
//
// Shown once (a `.migrated-0.5.0` sentinel under the workspace) and
// non-trapping — "Later" dismisses it for good. The caller gates on
// CloudAuth.shared.isSignedIn, so the Bearer token is always present.

import Cocoa

enum MigrationPrompt {
    private static let markerName = ".migrated-0.5.0"
    private static let channel = "electron"

    private static func markerPath(_ stateRoot: String) -> String {
        stateRoot + "/" + markerName
    }

    static func alreadyHandled(stateRoot: String) -> Bool {
        FileManager.default.fileExists(atPath: markerPath(stateRoot))
    }

    private static func markHandled(stateRoot: String) {
        let marker = markerPath(stateRoot)
        let dir = (marker as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: marker) {
            FileManager.default.createFile(atPath: marker, contents: Data())
        }
    }

    /// Show the one-time prompt. No-op if already handled or not signed in.
    static func maybeShow(stateRoot: String) {
        guard !alreadyHandled(stateRoot: stateRoot) else { return }
        guard let auth = CloudAuth.shared.record() else { return }

        let alert = NSAlert()
        alert.messageText = "Sutando has a new version"
        alert.informativeText = "Sutando has moved to a faster, re-architected build (0.5.0). "
            + "Download and install it now — your settings, sign-in, and memory carry over automatically."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download & Install")  // .alertFirstButtonReturn
        alert.addButton(withTitle: "Later")               // .alertSecondButtonReturn
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        // Either choice counts as "seen" — don't nag on every launch.
        markHandled(stateRoot: stateRoot)

        if response == .alertFirstButtonReturn {
            download(token: auth.token, apiBase: auth.apiBase)
        }
    }

    /// Stream the new dmg from the cloud proxy with the app's Bearer token,
    /// save it to ~/Downloads, and open it (mounts in Finder for the drag).
    private static func download(token: String, apiBase: String) {
        guard let url = URL(string: apiBase + "/api/download/" + channel) else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 600

        let task = URLSession.shared.downloadTask(with: req) { tempURL, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            guard error == nil, status == 200, let tempURL = tempURL else {
                DispatchQueue.main.async { showFallback(status: status, apiBase: apiBase) }
                return
            }
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let dest = dir.appendingPathComponent("Sutando-0.5.0.dmg")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
                DispatchQueue.main.async { NSWorkspace.shared.open(dest) }
            } catch {
                DispatchQueue.main.async { showFallback(status: nil, apiBase: apiBase) }
            }
        }
        task.resume()
    }

    /// Download failed — point the user at the dashboard download instead.
    private static func showFallback(status: Int?, apiBase: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if status == 403 {
            alert.messageText = "Beta access pending"
            alert.informativeText = "Your beta access isn't approved yet. Reopen Sutando once it is to get the new build."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        alert.messageText = "Couldn't download the update"
        alert.informativeText = "You can download the new Sutando from your dashboard instead."
        alert.addButton(withTitle: "Open Dashboard")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let dash = URL(string: apiBase + "/dashboard") {
            NSWorkspace.shared.open(dash)
        }
    }
}
