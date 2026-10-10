import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var shortcutService: GlobalShortcutService?
    private var captureCoordinator: CaptureCoordinator?
    private var lifecycleMonitor: CaptureLifecycleMonitor?
    private var syntheticConsumer: CaptureOverlaySessionConsumer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "VibeShot")
        let quit = appMenu.addItem(withTitle: "Quit VibeShot", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--synthetic-capture") {
            launchSyntheticCapture()
            return
        }
        #endif
        let settings = SettingsStore()
        let displayProvider = NSScreenDisplayProvider()
        let metrics = PrivacySafeMetrics()
        let lifecycleMonitor = CaptureLifecycleMonitor()
        let overlayConsumer = CaptureOverlaySessionConsumer(
            settingsStore: settings,
            lifecycleMonitor: lifecycleMonitor,
            metrics: metrics
        )
        overlayConsumer.onExportFailure = { error in NSAlert(error: error).runModal() }
        overlayConsumer.onSettingsFailure = { error in NSAlert(error: error).runModal() }
        let capture = CaptureCoordinator(
            displayProvider: displayProvider,
            sessionConsumer: overlayConsumer,
            lifecycleMonitor: lifecycleMonitor,
            metrics: metrics
        )
        capture.onFailure = { error in NSAlert(error: error).runModal() }
        let registrar: HotKeyRegistering
        do {
            let shortcuts = try GlobalShortcutService()
            shortcuts.onTrigger = { [weak capture] kind in capture?.requestCapture(kind == .region ? .region : .fullScreen) }
            shortcutService = shortcuts
            registrar = shortcuts
        } catch {
            registrar = UnavailableHotKeyService(error: error)
        }
        statusItemController = StatusItemController(settingsStore: settings, captureHandler: capture, loginService: LoginItemService(), shortcutService: registrar, displayProvider: displayProvider)
        captureCoordinator = capture
        self.lifecycleMonitor = lifecycleMonitor
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureCoordinator?.cancelCapture()
        syntheticConsumer?.cancelActiveCapture()
    }

    @objc private func quitApplication() {
        captureCoordinator?.cancelCapture()
        syntheticConsumer?.cancelActiveCapture()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    #if DEBUG
    /// Generated artwork only. This path never requests TCC or calls a screenshot API.
    private func launchSyntheticCapture() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let width = Int(frame.width * 2), height = Int(frame.height * 2)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(red: 0.15, green: 0.25, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return }
        let args = ProcessInfo.processInfo.arguments
        let preparer = SyntheticClipboardPreparer(fail: args.contains("--export-error"), delay: args.contains("--export-delay"))
        let settings: SettingsPersisting?
        if let index = args.firstIndex(of: "--synthetic-save-directory") {
            guard args.indices.contains(index + 1) else {
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            guard let fixture = SyntheticCaptureSettings(directoryPath: args[index + 1]) else {
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            settings = fixture
        } else {
            settings = nil
        }
        let consumer = CaptureOverlaySessionConsumer(
            settingsStore: settings,
            exportCoordinator: ExportCoordinator(settingsStore: settings, clipboardPreparer: preparer)
        )
        consumer.onExportFailure = { error in NSAlert(error: error).runModal() }
        syntheticConsumer = consumer
        let descriptor = ScreenDescriptor(id: DisplayID(1), frame: GlobalScreenRect(frame), pointPixelScale: 2, pixelSize: PixelSize(width: width, height: height))
        consumer.consume(CaptureSession(command: .fullScreen, displays: [DisplaySnapshot(descriptor: descriptor, image: image)]), eventHandler: { _ in })
    }
    #endif
}

#if DEBUG
private struct SyntheticClipboardPreparer: ClipboardRepresentationPreparing {
    let fail: Bool
    let delay: Bool
    func prepareRepresentations(for input: ExportInput) throws -> ClipboardRepresentations {
        if delay {
            for _ in 0..<100 {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if fail { throw ExportError.clipboardFailed("Synthetic test failure") }
        return try NativeClipboardRepresentationPreparer().prepareRepresentations(for: input)
    }
}

final class SyntheticCaptureSettings: SettingsPersisting {
    private(set) var settings: AppSettings
    let loadError: SettingsStoreError? = nil

    init?(directoryPath: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        var settings = AppSettings()
        settings.saveDestination = .recentFolder
        settings.outputFormat = .png
        settings.recentFolderPath = directoryPath
        self.settings = settings
    }

    func update(_ mutation: (inout AppSettings) -> Void) throws {
        mutation(&settings)
        settings.validate()
    }
}
#endif
