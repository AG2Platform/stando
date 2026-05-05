import Foundation

// LaunchAgent installer.
//
// Reads `com.sutando.*.plist.template` files from the .app bundle's
// `Resources/LaunchAgents/` directory, substitutes placeholders to point at
// the bundled runtime + the user's `SUTANDO_HOME`, and writes them to
// `~/Library/LaunchAgents/`. Then runs `launchctl bootstrap` so launchd
// picks them up.
//
// Placeholders match `app/LaunchAgents/README.md`:
//   {{REPO_DIR}}       — bundled repo source root
//   {{NPX_BIN}}        — path to npx (bundled or system)
//   {{TSX_BIN}}        — path to tsx (bundled or system; not currently used in templates)
//   {{NODE_BIN}}       — path to node binary
//   {{NODE_BIN_DIR}}   — directory containing node + npx (added to PATH)
//   {{PYTHON_BIN}}     — path to python3 (bundled or system)
//   {{SUTANDO_HOME}}   — ~/Library/Application Support/Sutando
//   {{LOG_DIR}}        — {{SUTANDO_HOME}}/logs

enum LaunchAgentError: Error {
    case bundleResourcesMissing
    case launchctlFailed(label: String, status: Int32, output: String)
}

struct LaunchAgentPaths {
    let repoDir: String
    let sutandoHome: String
    let runtimeBinDir: String?  // nil → use system fallbacks
}

class LaunchAgentInstaller {

    /// Default paths derived from the running .app bundle and HOME.
    /// `repoDir`: `Bundle.main.resourcePath/repo` if bundled, else the dev
    /// repo (resolved by main.swift's `workspace`).
    /// `sutandoHome`: `~/Library/Application Support/Sutando`.
    /// `runtimeBinDir`: `Bundle.main.resourcePath/runtime/bin` if it exists,
    /// otherwise nil (fall back to system paths).
    static func defaultPaths(workspace: String) -> LaunchAgentPaths {
        let resourcePath = Bundle.main.resourcePath
        let bundledRepo = resourcePath.map { $0 + "/repo" }
        let repoDir: String
        if let r = bundledRepo, FileManager.default.fileExists(atPath: r + "/CLAUDE.md") {
            repoDir = r
        } else {
            repoDir = workspace
        }
        let runtimeBin = resourcePath.map { $0 + "/runtime/bin" }
        let runtimeBinDir = runtimeBin.flatMap { dir in
            FileManager.default.fileExists(atPath: dir + "/node") ? dir : nil
        }
        let home = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Sutando")
        return LaunchAgentPaths(repoDir: repoDir, sutandoHome: home, runtimeBinDir: runtimeBinDir)
    }

    /// Resolve a placeholder map. Falls back to common system paths when
    /// the bundled runtime isn't present (so the installer works even
    /// before Phase 1.5 ships the bundled Node/Python).
    func placeholders(_ p: LaunchAgentPaths) -> [String: String] {
        let runtimeBin = p.runtimeBinDir
        func bundleOrSystem(_ name: String, systemFallbacks: [String]) -> String {
            if let dir = runtimeBin {
                let bundled = dir + "/" + name
                if FileManager.default.fileExists(atPath: bundled) { return bundled }
            }
            for path in systemFallbacks where FileManager.default.fileExists(atPath: path) {
                return path
            }
            // Last-resort: bare command name. launchctl will rely on PATH.
            return name
        }
        let nodeBin = bundleOrSystem("node", systemFallbacks: ["/opt/homebrew/bin/node", "/usr/local/bin/node"])
        let npxBin = bundleOrSystem("npx", systemFallbacks: ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"])
        let tsxBin = bundleOrSystem("tsx", systemFallbacks: ["/opt/homebrew/bin/tsx", "/usr/local/bin/tsx"])
        let pythonBin = bundleOrSystem("python3", systemFallbacks: ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"])
        let nodeBinDir = (nodeBin as NSString).deletingLastPathComponent
        let logDir = p.sutandoHome + "/logs"
        return [
            "{{REPO_DIR}}": p.repoDir,
            "{{NODE_BIN}}": nodeBin,
            "{{NPX_BIN}}": npxBin,
            "{{TSX_BIN}}": tsxBin,
            "{{NODE_BIN_DIR}}": nodeBinDir,
            "{{PYTHON_BIN}}": pythonBin,
            "{{SUTANDO_HOME}}": p.sutandoHome,
            "{{LOG_DIR}}": logDir,
        ]
    }

    /// Render a template by simple string substitution.
    func render(_ template: String, placeholders: [String: String]) -> String {
        var out = template
        for (key, value) in placeholders {
            out = out.replacingOccurrences(of: key, with: value)
        }
        return out
    }

    /// Where deployed plists live on this user's machine.
    var userLaunchAgentsDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
    }

    /// Where the templates live in the bundle. Returns nil when running
    /// from a raw binary (no `Resources/LaunchAgents/` available) — caller
    /// can fall back to `<repoDir>/app/LaunchAgents/` for the dev workflow.
    var bundleTemplatesDir: String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let dir = resourcePath + "/LaunchAgents"
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    /// Install the LaunchAgent set. Reads templates, substitutes
    /// placeholders, writes plists to ~/Library/LaunchAgents, and bootstraps
    /// each one. Returns the list of installed labels.
    @discardableResult
    func install(paths: LaunchAgentPaths, templatesDirOverride: String? = nil) throws -> [String] {
        let templatesDir = templatesDirOverride ?? bundleTemplatesDir ?? (paths.repoDir + "/app/LaunchAgents")
        guard FileManager.default.fileExists(atPath: templatesDir) else {
            throw LaunchAgentError.bundleResourcesMissing
        }

        // Ensure ~/Library/LaunchAgents and SUTANDO_HOME/logs exist.
        try FileManager.default.createDirectory(atPath: userLaunchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: paths.sutandoHome + "/logs", withIntermediateDirectories: true)

        let phs = placeholders(paths)
        let files = try FileManager.default.contentsOfDirectory(atPath: templatesDir)
        var installed: [String] = []
        for file in files where file.hasSuffix(".plist.template") {
            let label = String(file.dropLast(".plist.template".count))
            let templatePath = templatesDir + "/" + file
            guard let template = try? String(contentsOfFile: templatePath, encoding: .utf8) else { continue }
            let rendered = render(template, placeholders: phs)
            let destPath = userLaunchAgentsDir + "/" + label + ".plist"
            try rendered.write(toFile: destPath, atomically: true, encoding: .utf8)
            try bootstrap(label: label, plistPath: destPath)
            installed.append(label)
        }
        return installed
    }

    /// Bootout + bootstrap an agent. Idempotent — bootout first to avoid
    /// "service already loaded" errors.
    private func bootstrap(label: String, plistPath: String) throws {
        let uid = String(getuid())

        // Bootout (silent if not loaded). Errors here are fine.
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        out.arguments = ["bootout", "gui/\(uid)/\(label)"]
        out.standardOutput = FileHandle.nullDevice
        out.standardError = FileHandle.nullDevice
        try? out.run()
        out.waitUntilExit()

        // Bootstrap.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootstrap", "gui/\(uid)", plistPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LaunchAgentError.launchctlFailed(label: label, status: proc.terminationStatus, output: output)
        }
    }

    /// Bootout all com.sutando.* agents and remove their plists.
    @discardableResult
    func uninstall() -> [String] {
        let uid = String(getuid())
        let files = (try? FileManager.default.contentsOfDirectory(atPath: userLaunchAgentsDir)) ?? []
        var removed: [String] = []
        for file in files where file.hasPrefix("com.sutando.") && file.hasSuffix(".plist") {
            let label = String(file.dropLast(".plist".count))
            let plistPath = userLaunchAgentsDir + "/" + file
            let out = Process()
            out.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            out.arguments = ["bootout", "gui/\(uid)/\(label)"]
            out.standardOutput = FileHandle.nullDevice
            out.standardError = FileHandle.nullDevice
            try? out.run()
            out.waitUntilExit()
            try? FileManager.default.removeItem(atPath: plistPath)
            removed.append(label)
        }
        return removed
    }

    /// Query loaded com.sutando.* agents. Returns labels for which
    /// `launchctl print gui/<uid>/<label>` exits 0.
    func loadedLabels() -> [String] {
        let uid = String(getuid())
        let files = (try? FileManager.default.contentsOfDirectory(atPath: userLaunchAgentsDir)) ?? []
        var loaded: [String] = []
        for file in files where file.hasPrefix("com.sutando.") && file.hasSuffix(".plist") {
            let label = String(file.dropLast(".plist".count))
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["print", "gui/\(uid)/\(label)"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                loaded.append(label)
            }
        }
        return loaded
    }
}
