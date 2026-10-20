import AppKit

@MainActor protocol FolderPicking: AnyObject { func pickFolder() -> URL? }
@MainActor final class OpenPanelFolderPicker: FolderPicking {
    func pickFolder() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settingsStore: SettingsPersisting
    private let captureHandler: CaptureCommandHandling
    private let loginService: LoginItemServicing
    private let shortcutCoordinator: ShortcutSettingsCoordinator
    private let folderPicker: FolderPicking
    private let displayProvider: any DisplayDescriptorProviding
    private let bookmarkService: FolderBookmarkService
    private let errorHandler: (Error) -> Void
    private(set) var menu = NSMenu(title: "VibeShot")

    init(statusBar: NSStatusBar = .system, settingsStore: SettingsPersisting, captureHandler: CaptureCommandHandling, loginService: LoginItemServicing, shortcutService: HotKeyRegistering, folderPicker: FolderPicking = OpenPanelFolderPicker(), displayProvider: any DisplayDescriptorProviding = NSScreenDisplayProvider(), bookmarkService: FolderBookmarkService = FolderBookmarkService(), errorHandler: @escaping (Error) -> Void = { NSAlert(error: $0).runModal() }) {
        self.settingsStore = settingsStore
        self.captureHandler = captureHandler
        self.loginService = loginService
        self.shortcutCoordinator = ShortcutSettingsCoordinator(settingsStore: settingsStore, registrar: shortcutService)
        self.folderPicker = folderPicker
        self.displayProvider = displayProvider
        self.bookmarkService = bookmarkService
        self.errorHandler = errorHandler
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.toolTip = "VibeShot"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if let loadError = settingsStore.loadError { present(loadError) }
        do { try shortcutCoordinator.installPersisted() } catch { present(error) }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        handleStatusItemClick(eventType: NSApp.currentEvent?.type ?? .leftMouseUp)
    }
    func handleStatusItemClick(eventType: NSEvent.EventType, presentMenu: Bool = true) {
        if eventType == .rightMouseUp {
            rebuildMenu()
            if presentMenu, let button = statusItem.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button) }
        }
        else if eventType == .leftMouseUp { captureHandler.requestCapture(.region) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
    func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(item("Capture Region", #selector(captureRegion)))
        menu.addItem(fullScreenMenuItem())
        menu.addItem(.separator())
        menu.addItem(shortcutsMenuItem())
        menu.addItem(loginMenuItem())
        menu.addItem(rememberLastRegionMenuItem())
        menu.addItem(formatMenuItem())
        menu.addItem(qualityMenuItem())
        menu.addItem(destinationMenuItem())
        menu.addItem(.separator())
        menu.addItem(item("About VibeShot", #selector(showAbout)))
        let quit = item("Quit VibeShot", #selector(quit)); quit.keyEquivalent = "q"; menu.addItem(quit)
    }
    private func item(_ title: String, _ action: Selector?) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: ""); result.target = self; return result
    }
    private func fullScreenMenuItem() -> NSMenuItem {
        let displays = (try? displayProvider.currentDisplayDescriptors()) ?? []
        guard displays.count > 1 else {
            // With zero or one active display there is no ambiguity, so retain the generic intent.
            // The shortcut uses this same nil display ID; only the multi-display submenu carries a
            // typed per-display ID.
            return item("Capture Full Screen", #selector(captureFullScreen))
        }

        let parent = item("Capture Full Screen", nil)
        let submenu = NSMenu(title: "Capture Full Screen")
        for display in displays.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let child = item("Display \(display.id.rawValue)", #selector(captureFullScreenDisplay(_:)))
            child.representedObject = display.id
            submenu.addItem(child)
        }
        parent.submenu = submenu
        return parent
    }
    private func shortcutsMenuItem() -> NSMenuItem {
        let parent = item("Shortcuts", nil); let submenu = NSMenu(title: "Shortcuts")
        submenu.addItem(item("Region: \(settingsStore.settings.regionShortcut.displayName)…", #selector(recordRegionShortcut)))
        submenu.addItem(item("Full Screen: \(settingsStore.settings.fullScreenShortcut.displayName)…", #selector(recordFullScreenShortcut)))
        submenu.addItem(.separator())
        submenu.addItem(item("Disable Region Shortcut", #selector(disableRegionShortcut)))
        submenu.addItem(item("Disable Full Screen Shortcut", #selector(disableFullScreenShortcut)))
        parent.submenu = submenu; return parent
    }
    private func loginMenuItem() -> NSMenuItem {
        let result = item("Launch at Login", #selector(toggleLoginItem))
        switch loginService.state {
        case .enabled: result.state = .on
        case .disabled: result.state = .off
        case .requiresApproval: result.state = .mixed; result.toolTip = "Approval required in System Settings > General > Login Items."
        case let .unavailable(message): result.isEnabled = false; result.toolTip = message
        }
        return result
    }
    private func formatMenuItem() -> NSMenuItem {
        let parent = item("Output Format", nil); let submenu = NSMenu(title: "Output Format")
        for format in OutputFormat.allCases {
            let child = item(format.displayName, #selector(selectFormat(_:))); child.representedObject = format.rawValue
            child.state = settingsStore.settings.outputFormat == format ? .on : .off; submenu.addItem(child)
        }
        parent.submenu = submenu; return parent
    }
    private func rememberLastRegionMenuItem() -> NSMenuItem {
        let result = item("Remember Last Region", #selector(toggleRememberLastRegion(_:)))
        result.state = settingsStore.settings.rememberLastRegion ? .on : .off
        return result
    }
    private func qualityMenuItem() -> NSMenuItem {
        let result = item("Image Quality: 100%", nil)
        result.toolTip = "PNG and BMP are lossless. JPEG at 100% still uses lossy compression."
        return result
    }
    private func destinationMenuItem() -> NSMenuItem {
        let parent = item("Save Destination", nil); let submenu = NSMenu(title: "Save Destination")
        let ask = item("Ask Every Time", #selector(selectAskEveryTime)); ask.state = settingsStore.settings.saveDestination == .askEveryTime ? .on : .off; submenu.addItem(ask)
        let title = settingsStore.settings.recentFolderPath.map { "Most Recent: \(($0 as NSString).lastPathComponent)" } ?? "Choose Recent Folder…"
        let recent = item(title, #selector(selectRecentFolder)); recent.state = settingsStore.settings.saveDestination == .recentFolder ? .on : .off; submenu.addItem(recent)
        parent.submenu = submenu; return parent
    }
    @objc private func captureRegion() { captureHandler.requestCapture(.region) }
    @objc private func captureFullScreen() { captureHandler.requestCapture(.fullScreen) }
    @objc private func captureFullScreenDisplay(_ sender: NSMenuItem) {
        guard let displayID = sender.representedObject as? DisplayID else { return }
        captureHandler.requestCapture(.fullScreen(displayID: displayID))
    }
    @objc private func selectFormat(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = OutputFormat(rawValue: raw) else { return }
        do { try settingsStore.update { $0.outputFormat = format } } catch { present(error) }
    }
    @objc private func toggleRememberLastRegion(_ sender: NSMenuItem) {
        do {
            try settingsStore.update {
                $0.rememberLastRegion.toggle()
                if !$0.rememberLastRegion { $0.rememberedRegions.removeAll() }
            }
        } catch { present(error) }
        sender.state = settingsStore.settings.rememberLastRegion ? .on : .off
    }
    @objc private func selectAskEveryTime() { do { try settingsStore.update { $0.saveDestination = .askEveryTime } } catch { present(error) } }
    @objc private func selectRecentFolder() {
        guard let url = folderPicker.pickFolder() else { return }
        do {
            let bookmark = try? bookmarkService.makeBookmark(for: url)
            try settingsStore.update {
                $0.recentFolderPath = url.path
                $0.recentFolderBookmark = bookmark
                $0.saveDestination = .recentFolder
            }
        } catch { present(error) }
    }
    @objc private func toggleLoginItem() {
        do { try loginService.setEnabled(loginService.state != .enabled) } catch { present(error) }
    }
    @objc private func recordRegionShortcut() { recordShortcut(kind: .region) }
    @objc private func recordFullScreenShortcut() { recordShortcut(kind: .fullScreen) }
    @objc private func disableRegionShortcut() { replaceShortcut(kind: .region, with: ShortcutDefinition(keyCode: 0, modifiers: 0, isEnabled: false)) }
    @objc private func disableFullScreenShortcut() { replaceShortcut(kind: .fullScreen, with: ShortcutDefinition(keyCode: 0, modifiers: 0, isEnabled: false)) }
    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    private func recordShortcut(kind: ShortcutKind) {
        let alert = NSAlert(); alert.messageText = "Record Shortcut"; alert.informativeText = "Press a key with a modifier."
        alert.addButton(withTitle: "Restore Default"); alert.addButton(withTitle: "Disable"); alert.addButton(withTitle: "Cancel")
        let recorder = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        let label = NSTextField(labelWithString: "Click here, then press the shortcut"); label.frame = NSRect(x: 12, y: 12, width: 240, height: 20); recorder.addSubview(label)
        recorder.onRecord = { [weak self, weak alert] shortcut in
            if self?.replaceShortcut(kind: kind, with: shortcut) == true { alert?.window.close(); NSApp.abortModal() }
        }
        recorder.onCancel = { [weak alert] in alert?.window.close(); NSApp.abortModal() }
        alert.accessoryView = recorder; alert.window.initialFirstResponder = recorder
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            _ = replaceShortcut(kind: kind, with: kind == .region ? .defaultRegion : .disabledFullScreen)
        } else if response == .alertSecondButtonReturn {
            _ = replaceShortcut(kind: kind, with: ShortcutDefinition(keyCode: 0, modifiers: 0, isEnabled: false))
        }
    }
    @discardableResult func replaceShortcut(kind: ShortcutKind, with shortcut: ShortcutDefinition) -> Bool {
        do {
            _ = try shortcutCoordinator.replace(kind: kind, with: shortcut)
            return true
        } catch { present(error); return false }
    }
    private func present(_ error: Error) { errorHandler(error) }
}
