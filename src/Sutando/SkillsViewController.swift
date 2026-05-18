import AppKit

// Skills pane — the user's full view of what Sutando can do today.
// Lives as a first-class sibling of Conversation / Core CLI / Dashboard
// / Settings in the unified window's left sidebar (Wave 4.10).
//
// Four groups + a built-in collapsible:
//   - Installed from Station — skill_installs JOIN skills (kind='skill')
//   - Cloud tools activated  — same with kind='cloud_tool', plus
//     cloud_tool_sessions for calls-this-period + credits-debited
//   - Local (private)        — walks $SUTANDO_PRIVATE_DIR/skills/
//   - Built-in (collapsed)   — walks Resources/repo/skills/
//
// Source of truth for the cloud rows is GET /api/me/inventory. We poll
// every 30s while the pane is visible; local walks run on every show
// (sub-100ms typical) so dropping a skill into $SUTANDO_PRIVATE_DIR
// shows up the next time the user clicks the Skills sidebar item.
//
// Earlier draft of this UI lived as a section inside SettingsWindow.swift
// (between Background services and Help us improve). That's been removed
// to keep Settings focused on configuration; Skills moved to the sidebar.

final class SkillsViewController: NSViewController {

    private struct LocalSkillInfo {
        let slug: String
        let name: String
        let description: String
        let path: String
    }

    private var pageHeader: NSTextField?
    private var summaryLabel: NSTextField?

    private var installedHeader: NSTextField?
    private var installedStack: NSStackView?
    private var cloudToolsHeader: NSTextField?
    private var cloudToolsStack: NSStackView?
    private var localHeader: NSTextField?
    private var localStack: NSStackView?

    private var builtinDisclosure: NSButton?
    private var builtinStack: NSStackView?
    private var builtinExpanded = false

    private var lastInventory: CloudClient.CloudInventory?
    private var lastInventoryFetchTs: TimeInterval = 0
    private var pollTimer: Timer?

    // MARK: - View lifecycle

    override func loadView() {
        let bg = ThemedBackgroundView()
        bg.themedBackgroundColor = Theme.pageBackground
        bg.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)

        // Title row.
        let titleRow = NSStackView()
        titleRow.orientation = .vertical
        titleRow.alignment = .leading
        titleRow.spacing = 4

        let title = NSTextField(labelWithString: "Skills")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .labelColor
        pageHeader = title
        titleRow.addArrangedSubview(title)

        let summary = NSTextField(labelWithString: "Counting…")
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summaryLabel = summary
        titleRow.addArrangedSubview(summary)
        content.addArrangedSubview(titleRow)

        // Action row.
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10
        let browse = NSButton(title: "Browse Station →", target: self, action: #selector(openStationCatalog))
        browse.bezelStyle = .rounded
        actionRow.addArrangedSubview(browse)
        let publish = NSButton(title: "Publish a skill →", target: self, action: #selector(openStationPublish))
        publish.bezelStyle = .rounded
        actionRow.addArrangedSubview(publish)
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshRequested))
        refresh.bezelStyle = .rounded
        actionRow.addArrangedSubview(refresh)
        content.addArrangedSubview(actionRow)

        // Group: Installed from Station.
        installedHeader = groupHeader("Installed from Station")
        content.addArrangedSubview(installedHeader!)
        let inst = makeGroupStack()
        installedStack = inst
        content.addArrangedSubview(inst)

        // Group: Cloud tools activated.
        cloudToolsHeader = groupHeader("Cloud tools activated")
        content.addArrangedSubview(cloudToolsHeader!)
        let tools = makeGroupStack()
        cloudToolsStack = tools
        content.addArrangedSubview(tools)

        // Group: Local (private).
        localHeader = groupHeader("Local (private to this Mac)")
        content.addArrangedSubview(localHeader!)
        let local = makeGroupStack()
        localStack = local
        content.addArrangedSubview(local)

        // Built-in disclosure.
        let disclosure = NSButton()
        disclosure.bezelStyle = .recessed
        disclosure.title = "▶ Built-in (loading…)"
        disclosure.setButtonType(.momentaryChange)
        disclosure.font = .systemFont(ofSize: 12, weight: .medium)
        disclosure.target = self
        disclosure.action = #selector(toggleBuiltin)
        builtinDisclosure = disclosure
        content.addArrangedSubview(disclosure)

        let builtin = makeGroupStack()
        builtin.spacing = 4
        builtin.isHidden = true
        builtinStack = builtin
        content.addArrangedSubview(builtin)

        // Footer note.
        let footer = NSTextField(labelWithString:
            "Dashboard installs sync within ~1 min via background loop. Voice-agent picks up new tools on its next session. Local skills load on agent restart.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.maximumNumberOfLines = 3
        footer.preferredMaxLayoutWidth = 720
        content.addArrangedSubview(footer)

        // Wire scroll → content.
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)
        scroll.documentView = documentView

        bg.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: bg.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            content.topAnchor.constraint(equalTo: documentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        self.view = bg
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshAll()
        // Poll every 30s — same cadence as the SettingsWindow tier panel.
        // Cheap (one HTTP fetch + small file walks). Cancelled on disappear.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Refresh

    @objc private func refreshRequested() {
        lastInventoryFetchTs = 0
        refreshAll()
    }

    private func refreshAll() {
        applyLocalSkills()
        applyBuiltinSkills()
        updateSummary()
        guard CloudAuth.shared.isSignedIn else {
            applyCloudInventory(inventory: nil)
            return
        }
        let now = Date().timeIntervalSince1970
        if now - lastInventoryFetchTs < 25.0 && lastInventory != nil {
            applyCloudInventory(inventory: lastInventory)
            return
        }
        lastInventoryFetchTs = now
        CloudClient.fetchInventory { [weak self] inv in
            DispatchQueue.main.async {
                self?.lastInventory = inv
                self?.applyCloudInventory(inventory: inv)
                self?.updateSummary()
            }
        }
    }

    private func applyCloudInventory(inventory: CloudClient.CloudInventory?) {
        guard let installed = installedStack,
              let tools = cloudToolsStack,
              let installedH = installedHeader,
              let toolsH = cloudToolsHeader else { return }
        installed.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tools.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let inst = inventory?.installed ?? []
        let cts = inventory?.cloudTools ?? []
        installedH.stringValue = "Installed from Station  (\(inst.count))"
        toolsH.stringValue = "Cloud tools activated  (\(cts.count))"

        if inst.isEmpty {
            installed.addArrangedSubview(emptyRow(
                inventory == nil
                    ? "Sign in to Sutando to see installed skills."
                    : "No skills installed yet. Browse the Station to add some."))
        } else {
            for skill in inst { installed.addArrangedSubview(installedRow(skill)) }
        }
        if cts.isEmpty {
            tools.addArrangedSubview(emptyRow(
                inventory == nil
                    ? "Sign in to Sutando to see activated cloud tools."
                    : "No cloud tools activated. Browse the Station to try one."))
        } else {
            for tool in cts { tools.addArrangedSubview(cloudToolRow(tool)) }
        }
    }

    private func applyLocalSkills() {
        guard let stack = localStack, let header = localHeader else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = walkLocalSkills()
        header.stringValue = "Local (private to this Mac)  (\(entries.count))"
        if entries.isEmpty {
            stack.addArrangedSubview(emptyRow(
                "Drop a skill dir at $SUTANDO_PRIVATE_DIR/skills/<slug>/ — Sutando picks it up on next voice-agent restart."))
        } else {
            for entry in entries { stack.addArrangedSubview(localRow(entry)) }
        }
    }

    private func applyBuiltinSkills() {
        guard let stack = builtinStack, let disclosure = builtinDisclosure else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = walkBuiltinSkills()
        let symbol = builtinExpanded ? "▼" : "▶"
        disclosure.title = "\(symbol) Built-in  (\(entries.count) — always available)"
        for entry in entries {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            let name = NSTextField(labelWithString: entry.name)
            name.font = .systemFont(ofSize: 11, weight: .medium)
            row.addArrangedSubview(name)
            let desc = NSTextField(labelWithString: entry.description.isEmpty ? "—" : entry.description)
            desc.font = .systemFont(ofSize: 10)
            desc.textColor = .tertiaryLabelColor
            desc.maximumNumberOfLines = 1
            desc.lineBreakMode = .byTruncatingTail
            row.addArrangedSubview(desc)
            stack.addArrangedSubview(row)
        }
    }

    private func updateSummary() {
        guard let summary = summaryLabel else { return }
        let builtin = walkBuiltinSkills().count
        let local = walkLocalSkills().count
        let installed = lastInventory?.installed.count ?? 0
        let tools = lastInventory?.cloudTools.count ?? 0
        if CloudAuth.shared.isSignedIn {
            summary.stringValue = "\(builtin) built-in · \(installed) installed · \(tools) cloud tools · \(local) local"
        } else {
            summary.stringValue = "\(builtin) built-in · \(local) local · sign in for Station inventory"
        }
    }

    // MARK: - Row builders

    private func makeGroupStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
        return stack
    }

    private func groupHeader(_ title: String) -> NSTextField {
        let h = NSTextField(labelWithString: title)
        h.font = .systemFont(ofSize: 11, weight: .semibold)
        h.textColor = .secondaryLabelColor
        return h
    }

    private func emptyRow(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.maximumNumberOfLines = 2
        l.preferredMaxLayoutWidth = 600
        return l
    }

    private func installedRow(_ skill: CloudClient.CloudInstalledSkill) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let name = NSTextField(labelWithString: "\(skill.name)  v\(skill.version)")
        name.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(name)

        if let rating = skill.userRating {
            let stars = NSTextField(labelWithString: String(repeating: "★", count: rating))
            stars.font = .systemFont(ofSize: 11)
            stars.textColor = .systemYellow
            row.addArrangedSubview(stars)
        }
        if skill.priceCredits > 0 {
            let price = NSTextField(labelWithString: "\(skill.priceCredits) cr")
            price.font = .systemFont(ofSize: 11)
            price.textColor = .secondaryLabelColor
            row.addArrangedSubview(price)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let uninstall = NSButton(title: "Uninstall", target: self, action: #selector(uninstallFromRow(_:)))
        uninstall.bezelStyle = .rounded
        uninstall.controlSize = .small
        uninstall.identifier = NSUserInterfaceItemIdentifier(rawValue: skill.slug)
        row.addArrangedSubview(uninstall)
        return row
    }

    private func cloudToolRow(_ tool: CloudClient.CloudActivatedTool) -> NSView {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 2

        let head = NSStackView()
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 10

        let name = NSTextField(labelWithString: tool.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        head.addArrangedSubview(name)

        if let price = tool.unitPriceCredits, price > 0 {
            let unit = tool.unitLabel ?? "call"
            let pl = NSTextField(labelWithString: String(format: "%g cr / %@", price, unit))
            pl.font = .systemFont(ofSize: 11)
            pl.textColor = .secondaryLabelColor
            head.addArrangedSubview(pl)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        head.addArrangedSubview(spacer)

        let deactivate = NSButton(title: "Deactivate", target: self, action: #selector(uninstallFromRow(_:)))
        deactivate.bezelStyle = .rounded
        deactivate.controlSize = .small
        deactivate.identifier = NSUserInterfaceItemIdentifier(rawValue: tool.slug)
        head.addArrangedSubview(deactivate)
        outer.addArrangedSubview(head)

        let meter = NSTextField(labelWithString:
            String(format: "%d calls this period · %g credits debited",
                   tool.callsThisPeriod, tool.creditsDebitedThisPeriod))
        meter.font = .systemFont(ofSize: 11)
        meter.textColor = .tertiaryLabelColor
        outer.addArrangedSubview(meter)
        return outer
    }

    private func localRow(_ skill: LocalSkillInfo) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let name = NSTextField(labelWithString: skill.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        row.addArrangedSubview(name)

        let desc = NSTextField(labelWithString: skill.description.isEmpty ? "—" : skill.description)
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .tertiaryLabelColor
        desc.maximumNumberOfLines = 1
        desc.lineBreakMode = .byTruncatingTail
        row.addArrangedSubview(desc)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        let open = NSButton(title: "Open folder", target: self, action: #selector(openLocalFromRow(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.identifier = NSUserInterfaceItemIdentifier(rawValue: skill.path)
        row.addArrangedSubview(open)
        return row
    }

    // MARK: - Actions

    @objc private func openStationCatalog() {
        let base = CloudAuth.shared.record()?.apiBase ?? "https://sutando.ag2.ai"
        if let u = URL(string: base + "/superpower") { NSWorkspace.shared.open(u) }
    }

    @objc private func openStationPublish() {
        let base = CloudAuth.shared.record()?.apiBase ?? "https://sutando.ag2.ai"
        if let u = URL(string: base + "/superpower/publish") { NSWorkspace.shared.open(u) }
    }

    @objc private func toggleBuiltin() {
        guard let stack = builtinStack else { return }
        builtinExpanded.toggle()
        stack.isHidden = !builtinExpanded
        applyBuiltinSkills()  // refreshes the disclosure label arrow
    }

    @objc private func uninstallFromRow(_ sender: NSButton) {
        guard let slug = sender.identifier?.rawValue else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall \(slug)?"
        alert.informativeText = "Reinstall from the Station re-charges the price for paid skills. Cloud-tool usage counters reset on re-activation."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn { return }
        sender.isEnabled = false
        sender.title = "Uninstalling…"
        CloudClient.uninstallSkill(slug) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .ok:
                    self.lastInventoryFetchTs = 0
                    self.refreshAll()
                case .notFound:
                    sender.title = "Not found"
                case .failure(let detail):
                    NSLog("Uninstall failed for \(slug): \(detail)")
                    sender.isEnabled = true
                    sender.title = "Retry"
                }
            }
        }
    }

    @objc private func openLocalFromRow(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    // MARK: - File walks

    private var builtinSkillsDir: String {
        if let bundleResourceRepo = Bundle.main.resourcePath,
           FileManager.default.fileExists(atPath: bundleResourceRepo + "/repo/skills") {
            return bundleResourceRepo + "/repo/skills"
        }
        let fm = FileManager.default
        var dir = fm.currentDirectoryPath
        for _ in 0..<8 {
            let candidate = dir + "/skills"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            if dir == "/" { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return fm.currentDirectoryPath + "/skills"
    }

    private var privateSkillsDir: String? {
        if let raw = ProcessInfo.processInfo.environment["SUTANDO_PRIVATE_DIR"], !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return expanded + "/skills"
        }
        return nil
    }

    private func walkBuiltinSkills() -> [LocalSkillInfo] {
        return walkSkillsDir(builtinSkillsDir)
    }

    private func walkLocalSkills() -> [LocalSkillInfo] {
        guard let dir = privateSkillsDir else { return [] }
        return walkSkillsDir(dir)
    }

    private func walkSkillsDir(_ dir: String) -> [LocalSkillInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var results: [LocalSkillInfo] = []
        for entry in entries {
            let full = dir + "/" + entry
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestPath = full + "/manifest.json"
            var name = entry
            var description = ""
            if let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let n = obj["name"] as? String, !n.isEmpty { name = n }
                if let d = obj["description"] as? String { description = d }
                if let enabled = obj["enabled"] as? Bool, enabled == false { continue }
            }
            results.append(LocalSkillInfo(slug: entry, name: name, description: description, path: full))
        }
        return results.sorted(by: { $0.name.lowercased() < $1.name.lowercased() })
    }
}
