import AppKit
import FarCore

/// A menu item retains its destination panel, so a later focus change cannot redirect it.
@MainActor private final class ResourceMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}

extension AppDelegate {
    func resourceMenu(for panel: PanelView) -> NSMenu {
        let menu = NSMenu(title: L10n.text("Сменить диск"))
        func add(_ title: String, id: String, action: @escaping () -> Void) {
            let target = ResourceMenuAction(action)
            let item = NSMenuItem(title: L10n.text(title), action: #selector(ResourceMenuAction.invoke(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = target; item.identifier = .init(id)
            menu.addItem(item)
        }
        var seen = Set<String>()
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        for url in [URL(fileURLWithPath: "/"), FileManager.default.homeDirectoryForCurrentUser] + volumes where seen.insert(url.path).inserted {
            add(url.path, id: "volume:" + url.path) { [weak self, weak panel] in
                guard let self, let panel, self.canChangePanelResource else { return }
                self.activate(panel); panel.onRemoteReturn = nil; panel.navigateHistory(to: url.path)
            }
        }
        menu.addItem(.separator())
        add("Сеть", id: "localNetwork") { [weak self, weak panel] in
            guard let self, let panel, self.canChangePanelResource else { return }; self.showLocalNetwork(in: panel)
        }
        add("NetBox — подключения", id: "savedConnections") { [weak self, weak panel] in
            guard let self, let panel, self.canChangePanelResource else { return }; self.showSavedConnections(in: panel)
        }
        add("Процессы", id: "processList") { [weak self, weak panel] in
            guard let self, let panel, self.canChangePanelResource else { return }; self.showProcesses(in: panel)
        }
        for (index, entry) in FarLuaPlugins.shared.diskMenuEntries(for: panel).enumerated() {
            add(entry.title, id: "luaPlugin:\(index)", action: entry.activate)
        }
        return menu
    }
    func showResourceMenu(for panel: PanelView, anchor: NSView? = nil) {
        guard canChangePanelResource else { return }
        let view = anchor ?? panel.resourceButton
        resourceMenu(for: panel).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }
    func showSavedConnections(in panel: PanelView) {
        activate(panel)
        let browser: SavedConnectionsPanelView
        if let existing = savedConnectionsPanels[panel.locationKey] { browser = existing }
        else {
            browser = SavedConnectionsPanelView(storeURL: AppRuntime.smokeStateDirectory?.appendingPathComponent("resource-profiles.json") ?? NetworkProfileStore.defaultURL)
            savedConnectionsPanels[panel.locationKey] = browser
        }
        browser.onFocus = { [weak self, weak panel] in if let panel { self?.activate(panel) } }
        browser.onClose = { [weak panel] in panel?.leaveResource() }
        browser.onSwitchPanel = { [weak self, weak panel] in guard let self, let panel else { return }; self.activate(panel === self.left ? self.right : self.left); self.active.focus() }
        browser.onChange = { [weak panel, weak browser] in if let browser { panel?.updateResourceCaption(browser.caption) } }
        browser.exportDirectory = { [weak self] in guard let self, !self.passive.isResource, !self.passive.isRemote, !self.passive.isArchive, !self.passive.isVirtual, !self.passive.isTemporary else { return nil }; return self.passive.directory }
        browser.onConnect = { [weak self, weak panel] connection in
            guard let self, let panel else { return }
            panel.onRemoteReturn = { [weak self] in self?.showSavedConnections(in: $0) }
            self.network.connectProfile(connection, in: panel)
        }
        browser.onConnectEdited = { [weak self, weak panel] connection, password in
            guard let self, let panel else { return }
            panel.onRemoteReturn = { [weak self] in self?.showSavedConnections(in: $0) }
            self.network.connectProfile(connection, password: password, in: panel)
        }
        browser.canConnect = { [weak self, weak panel] in panel != nil && self?.canChangePanelResource == true }
        panel.showResource(browser, kind: .connections, caption: browser.caption,
            focus: { browser.focus() }, refresh: { browser.refresh() }, stop: { [weak self] in self?.network.cancel() },
            setActive: { browser.setActive($0) }, perform: { browser.perform(function: $0, shifted: $1) })
        browser.refresh()
    }
    func showLocalNetwork(in panel: PanelView) {
        activate(panel); panel.onRemoteReturn = nil
        let browser = LocalNetworkPanelView()
        browser.onFocus = { [weak self, weak panel] in if let panel { self?.activate(panel) } }
        browser.onClose = { [weak panel] in panel?.leaveResource() }
        browser.onSwitchPanel = { [weak self, weak panel] in guard let self, let panel else { return }; self.activate(panel === self.left ? self.right : self.left); self.active.focus() }
        browser.onChange = { [weak panel, weak browser] in if let browser { panel?.updateResourceCaption(browser.caption) } }
        browser.onOpenMounted = { [weak self, weak panel] url in
            guard let self, let panel else { return }; panel.navigateHistory(to: url.path, focus: self.active === panel)
        }
        panel.showResource(browser, kind: .localNetwork, caption: browser.caption,
            focus: { browser.focus() }, refresh: { browser.refresh() }, stop: { browser.stop() },
            setActive: { browser.setActive($0) }, perform: { function, shifted in !shifted && browser.performFunction(function) })
        panel.resourceParent = { browser.goUp() }
        browser.start()
    }
    func showProcesses(in panel: PanelView) {
        activate(panel); panel.onRemoteReturn = nil
        let browser = ProcessPanelView()
        browser.onFocus = { [weak self, weak panel] in if let panel { self?.activate(panel) } }
        browser.onClose = { [weak panel] in panel?.leaveResource() }
        browser.onSwitchPanel = { [weak self, weak panel] in guard let self, let panel else { return }; self.activate(panel === self.left ? self.right : self.left); self.active.focus() }
        panel.showResource(browser, kind: .processes, caption: "Процессы",
            focus: { browser.focus() }, refresh: { browser.refresh() }, stop: { browser.stop() },
            setActive: { browser.setActive($0) }, perform: { browser.perform(function: $0, shifted: $1) })
        browser.refresh()
    }
}

