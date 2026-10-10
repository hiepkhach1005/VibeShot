import AppKit
import Testing
@testable import VibeShot

struct VibeShotTests {
    #if DEBUG
    @Test
    func syntheticSaveDirectoryRejectsMissingPathAndFile() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("VibeShot-missing-\(UUID().uuidString)")
        #expect(SyntheticCaptureSettings(directoryPath: missing.path) == nil)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("VibeShot-file-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(SyntheticCaptureSettings(directoryPath: file.path) == nil)

        let valid = try #require(SyntheticCaptureSettings(directoryPath: FileManager.default.temporaryDirectory.path))
        #expect(valid.settings.saveDestination == .recentFolder)
        #expect(valid.settings.outputFormat == .png)
    }
    #endif

    @Test
    func syntheticFixtureIsDeterministicAndHasExpectedSize() {
        let first = SyntheticFixture.colorGrid(width: 4, height: 3)
        let second = SyntheticFixture.colorGrid(width: 4, height: 3)

        #expect(first == second)
        #expect(first.count == 4 * 3 * 3)
    }

    @Test
    func capturedDisplayStoresOnlySuppliedFixtureData() {
        let fixture = SyntheticFixture.colorGrid(width: 2, height: 2)
        let display = CapturedDisplay(
            displayID: 7,
            pixelWidth: 2,
            pixelHeight: 2,
            imageData: fixture
        )

        #expect(display.imageData == fixture)
        #expect(display.pixelWidth == 2)
        #expect(display.pixelHeight == 2)
    }
}

private final class MemorySettingsStore: SettingsPersisting {
    var settings: AppSettings
    var loadError: SettingsStoreError?
    var updateError: Error?
    init(_ settings: AppSettings = AppSettings()) { self.settings = settings }
    func update(_ mutation: (inout AppSettings) -> Void) throws {
        if let updateError { throw updateError }
        var candidate = settings; mutation(&candidate); candidate.validate(); settings = candidate
    }
}

private final class DataBackingSpy: SettingsDataBacking {
    var values: [String: Data] = [:]
    var failWrites = false
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data, forKey key: String) throws {
        if failWrites { throw NSError(domain: "test", code: 1) }
        values[key] = data
    }
}

@MainActor private final class CaptureSpy: CaptureCommandHandling {
    var commands: [CaptureCommand] = []
    func requestCapture(_ command: CaptureCommand) { commands.append(command) }
}

@MainActor private final class LoginSpy: LoginItemServicing {
    var state: LoginItemState = .disabled
    var requested: [Bool] = []
    var failure: Error?
    func setEnabled(_ enabled: Bool) throws { if let failure { throw failure }; requested.append(enabled); state = enabled ? .enabled : .disabled }
}

@MainActor private final class HotKeySpy: HotKeyRegistering {
    var registrations: [(ShortcutKind, ShortcutDefinition)] = []
    var unregistrations: [ShortcutKind] = []
    var failure: Error?
    var failureOnRegistrationCall: Int?
    private(set) var registrationAttempts = 0
    func register(kind: ShortcutKind, shortcut: ShortcutDefinition) throws {
        registrationAttempts += 1
        if failureOnRegistrationCall == registrationAttempts { throw ShortcutRegistrationError.system(-999) }
        if let failure { throw failure }
        registrations.append((kind, shortcut))
    }
    func unregister(kind: ShortcutKind) { unregistrations.append(kind) }
}

@MainActor private final class FolderPickerSpy: FolderPicking {
    var result: URL?
    func pickFolder() -> URL? { result }
}

struct M1SettingsTests {
    @Test func legacyQualityAndRegionSettingsMigrateSafely() throws {
        let data = Data("{\"version\":3,\"imageQuality\":37,\"rememberLastRegion\":true,\"rememberedRegions\":{\"good\":{\"x\":0.1,\"y\":0.2,\"width\":0.3,\"height\":0.4},\"bad\":{\"x\":0.1,\"y\":0.2,\"width\":\"oops\",\"height\":0.4}}}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.version == 4)
        #expect(settings.imageQuality == 100)
        #expect(settings.rememberLastRegion)
        #expect(settings.rememberedRegions.count == 1)
        #expect(settings.rememberedRegions["good"] != nil)
    }

    @Test func disablingRememberedRegionsClearsThemAtomically() throws {
        let backing = DataBackingSpy()
        let store = SettingsStore(backing: backing)
        try store.update { $0.rememberLastRegion = true; $0.rememberedRegions["display"] = RememberedRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4) }
        backing.failWrites = true
        #expect(throws: SettingsStoreError.self) { try store.update { $0.rememberLastRegion = false } }
        #expect(store.settings.rememberLastRegion)
        #expect(store.settings.rememberedRegions.count == 1)
        backing.failWrites = false
        try store.update { $0.rememberLastRegion = false }
        #expect(store.settings.rememberedRegions.isEmpty)
    }
    @Test func defaultsAndValidation() {
        var settings = AppSettings(imageQuality: 500)
        settings.regionShortcut = ShortcutDefinition(keyCode: 12, modifiers: 0, isEnabled: true)
        settings.saveDestination = .recentFolder
        settings.validate()
        #expect(settings.imageQuality == 100)
        #expect(settings.regionShortcut == .defaultRegion)
        #expect(settings.saveDestination == .askEveryTime)
        #expect(OutputFormat.png.supportsQuality == false)
        #expect(OutputFormat.bmp.supportsQuality == false)
        #expect(OutputFormat.jpeg.supportsQuality)
        #expect(OutputFormat.heic.supportsQuality)
    }

    @Test func persistsIntoFreshStore() throws {
        let name = "VibeShotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = SettingsStore(defaults: defaults)
        try first.update { $0.outputFormat = .jpeg; $0.imageQuality = 37; $0.recentFolderPath = "/tmp"; $0.saveDestination = .recentFolder }
        let second = SettingsStore(defaults: defaults)
        #expect(second.settings.outputFormat == .jpeg)
        #expect(second.settings.imageQuality == 100)
        #expect(second.settings.saveDestination == .recentFolder)
    }

    @Test func qualityAlwaysNormalizesToFull() throws {
        let store = MemorySettingsStore()
        try store.update { $0.imageQuality = 0 }; #expect(store.settings.imageQuality == 100)
        try store.update { $0.imageQuality = 101 }; #expect(store.settings.imageQuality == 100)
    }

    @Test func corruptPayloadIsBackedUpWithoutOverwrite() {
        let backing = DataBackingSpy(); let corrupt = Data("not-json".utf8); backing.values["settings.v1"] = corrupt
        let store = SettingsStore(backing: backing)
        #expect(store.settings == AppSettings())
        #expect(store.loadError == .corruptPayload)
        #expect(backing.values["settings.v1"] == corrupt)
        #expect(backing.values["settings.v1.recovery-backup"] == corrupt)
    }

    @Test func futurePayloadIsPreservedAndReported() {
        let backing = DataBackingSpy(); let future = Data("{\"version\":99}".utf8); backing.values["settings.v1"] = future
        let store = SettingsStore(backing: backing)
        #expect(store.loadError == .futureVersion(99))
        #expect(backing.values["settings.v1"] == future)
        #expect(backing.values["settings.v1.recovery-backup"] == future)
    }

    @Test func failedPersistDoesNotMutateMemory() {
        let backing = DataBackingSpy(); let store = SettingsStore(backing: backing); backing.failWrites = true
        #expect(throws: SettingsStoreError.self) { try store.update { $0.imageQuality = 12 } }
        #expect(store.settings.imageQuality == 100)
    }
}

@MainActor
struct M1InteractionTests {
    private func makeController(settings: MemorySettingsStore = MemorySettingsStore(), capture: CaptureSpy = CaptureSpy(), login: LoginSpy = LoginSpy(), hotkeys: HotKeySpy = HotKeySpy(), picker: FolderPickerSpy = FolderPickerSpy(), errors: @escaping (Error) -> Void = { _ in }) -> StatusItemController {
        _ = NSApplication.shared
        return StatusItemController(settingsStore: settings, captureHandler: capture, loginService: login, shortcutService: hotkeys, folderPicker: picker, errorHandler: errors)
    }

    @Test func leftClickRequestsRegionExactlyOnce() {
        let capture = CaptureSpy(); let controller = makeController(capture: capture)
        controller.handleStatusItemClick(eventType: .leftMouseUp)
        #expect(capture.commands == [.region])
    }

    @Test func menuCommandsRequestEachIntentExactlyOnce() throws {
        let capture = CaptureSpy(); let controller = makeController(capture: capture)
        controller.rebuildMenu()
        let region = try #require(controller.menu.item(withTitle: "Capture Region"))
        let full = try #require(controller.menu.item(withTitle: "Capture Full Screen"))
        NSApp.sendAction(region.action!, to: region.target, from: region)
        NSApp.sendAction(full.action!, to: full.target, from: full)
        #expect(capture.commands == [.region, .fullScreen])
    }

    @Test func dynamicMenuReflectsLosslessQualityAndLoginApproval() throws {
        var value = AppSettings(); value.outputFormat = .png
        let login = LoginSpy(); login.state = .requiresApproval
        let controller = makeController(settings: MemorySettingsStore(value), login: login)
        controller.rebuildMenu()
        let quality = try #require(controller.menu.items.first { $0.title.hasPrefix("Image Quality") })
        let launch = try #require(controller.menu.item(withTitle: "Launch at Login"))
        #expect(quality.isEnabled)
        #expect(quality.title == "Image Quality: 100%")
        #expect(quality.view == nil)
        #expect(launch.state == .mixed)
    }

    @Test func loginMenuRequestsEnable() throws {
        let login = LoginSpy(); let controller = makeController(login: login); controller.rebuildMenu()
        let launch = try #require(controller.menu.item(withTitle: "Launch at Login"))
        NSApp.sendAction(launch.action!, to: launch.target, from: launch)
        #expect(login.requested == [true])
    }

    @Test func rightClickDoesNotCaptureAndRebuildsFreshMenu() throws {
        let capture = CaptureSpy(); let settings = MemorySettingsStore(); let controller = makeController(settings: settings, capture: capture)
        try settings.update { $0.outputFormat = .jpeg }
        controller.handleStatusItemClick(eventType: .rightMouseUp, presentMenu: false)
        #expect(capture.commands.isEmpty)
        let output = try #require(controller.menu.item(withTitle: "Output Format")?.submenu)
        #expect(output.item(withTitle: "JPEG")?.state == .on)
    }

    @Test func unavailableLoginIsDisabledAndErrorsAreSurfaced() throws {
        let login = LoginSpy(); login.state = .unavailable("Unavailable")
        var errors = 0
        let controller = makeController(login: login, errors: { _ in errors += 1 }); controller.rebuildMenu()
        #expect(controller.menu.item(withTitle: "Launch at Login")?.isEnabled == false)
        login.state = .disabled; login.failure = NSError(domain: "login", code: 1); controller.rebuildMenu()
        let launch = try #require(controller.menu.item(withTitle: "Launch at Login"))
        NSApp.sendAction(launch.action!, to: launch.target, from: launch)
        #expect(errors == 1)
    }

    @Test func imageQualityIsStaticForLosslessFormats() throws {
        var value = AppSettings(); value.outputFormat = .bmp; value.imageQuality = 42
        let controller = makeController(settings: MemorySettingsStore(value)); controller.rebuildMenu()
        let quality = try #require(controller.menu.items.first { $0.title.hasPrefix("Image Quality") })
        #expect(quality.title == "Image Quality: 100%")
        #expect(quality.view == nil)
        #expect(quality.isEnabled)
    }

    @Test func rememberRegionMenuReflectsPersistedToggleAndFailure() throws {
        let settings = MemorySettingsStore()
        let controller = makeController(settings: settings)
        controller.rebuildMenu()
        let option = try #require(controller.menu.item(withTitle: "Remember Last Region"))
        #expect(option.state == .off)
        NSApp.sendAction(option.action!, to: option.target, from: option)
        #expect(settings.settings.rememberLastRegion)
        #expect(option.state == .on)
        settings.updateError = SettingsStoreError.persistFailed("test")
        NSApp.sendAction(option.action!, to: option.target, from: option)
        #expect(settings.settings.rememberLastRegion)
        #expect(option.state == .on)
    }

    @Test func shortcutCoordinatorNoOpDuplicateDisableAndRollback() throws {
        let settings = MemorySettingsStore(); let hotkeys = HotKeySpy(); let coordinator = ShortcutSettingsCoordinator(settingsStore: settings, registrar: hotkeys)
        #expect(try coordinator.replace(kind: .region, with: .defaultRegion) == false)
        #expect(hotkeys.registrations.isEmpty)
        let duplicate = ShortcutDefinition.defaultRegion
        try settings.update { $0.fullScreenShortcut = duplicate; $0.regionShortcut = .disabledFullScreen }
        #expect(throws: ShortcutRegistrationError.self) { try coordinator.replace(kind: .region, with: duplicate) }
        let disabled = ShortcutDefinition(keyCode: 0, modifiers: 0, isEnabled: false)
        _ = try coordinator.replace(kind: .fullScreen, with: disabled)
        #expect(hotkeys.unregistrations == [.fullScreen])

        let rollbackSettings = MemorySettingsStore(); rollbackSettings.updateError = SettingsStoreError.persistFailed("test")
        let rollbackKeys = HotKeySpy(); let rollback = ShortcutSettingsCoordinator(settingsStore: rollbackSettings, registrar: rollbackKeys)
        let replacement = ShortcutDefinition(keyCode: 8, modifiers: 256, isEnabled: true)
        #expect(throws: SettingsStoreError.self) { try rollback.replace(kind: .region, with: replacement) }
        #expect(rollbackSettings.settings.regionShortcut == .defaultRegion)
        #expect(rollbackKeys.registrations.map(\.1) == [replacement, .defaultRegion])
    }

    @Test func failedRollbackSurfacesCombinedErrorAndDisablesRuntimeShortcut() {
        let settings = MemorySettingsStore(); settings.updateError = SettingsStoreError.persistFailed("disk unavailable")
        let hotkeys = HotKeySpy(); hotkeys.failureOnRegistrationCall = 2
        let coordinator = ShortcutSettingsCoordinator(settingsStore: settings, registrar: hotkeys)
        let replacement = ShortcutDefinition(keyCode: 8, modifiers: 256, isEnabled: true)
        do {
            _ = try coordinator.replace(kind: .region, with: replacement)
            Issue.record("Expected rollback failure")
        } catch let error as ShortcutUpdateError {
            guard case let .rollbackFailed(persistence, restoration) = error else { Issue.record("Unexpected shortcut update error"); return }
            #expect(persistence.contains("disk unavailable"))
            #expect(restoration.contains("-999"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(settings.settings.regionShortcut == .defaultRegion)
        #expect(hotkeys.registrations.map(\.1) == [replacement])
        #expect(hotkeys.unregistrations == [.region])
    }

    @Test func startupRegistersRegionAndDisabledFullScreen() {
        let hotkeys = HotKeySpy(); _ = makeController(hotkeys: hotkeys)
        #expect(hotkeys.registrations.count == 2)
        #expect(hotkeys.registrations[0].0 == .region)
        #expect(hotkeys.registrations[1].1.isEnabled == false)
    }

    @Test func failedShortcutReplacementIsAtomic() {
        let settings = MemorySettingsStore(); let hotkeys = HotKeySpy(); let controller = makeController(settings: settings, hotkeys: hotkeys)
        hotkeys.failure = ShortcutRegistrationError.conflict
        let candidate = ShortcutDefinition(keyCode: 8, modifiers: 256, isEnabled: true)
        #expect(controller.replaceShortcut(kind: .region, with: candidate) == false)
        #expect(settings.settings.regionShortcut == .defaultRegion)
    }

    @Test func cancelledFolderPickerDoesNotChangeSettings() throws {
        let settings = MemorySettingsStore(); let picker = FolderPickerSpy(); picker.result = nil
        let controller = makeController(settings: settings, picker: picker); controller.rebuildMenu()
        let parent = try #require(controller.menu.item(withTitle: "Save Destination")?.submenu)
        let choose = try #require(parent.items.last)
        NSApp.sendAction(choose.action!, to: choose.target, from: choose)
        #expect(settings.settings.saveDestination == .askEveryTime)
        #expect(settings.settings.recentFolderPath == nil)
    }

    @Test func successfulShortcutReplacementPersists() {
        let settings = MemorySettingsStore(); let hotkeys = HotKeySpy(); let controller = makeController(settings: settings, hotkeys: hotkeys)
        let candidate = ShortcutDefinition(keyCode: 8, modifiers: 256, isEnabled: true)
        controller.replaceShortcut(kind: .region, with: candidate)
        #expect(settings.settings.regionShortcut == candidate)
    }

    @Test func captureCoordinatorProbeRecordsOnce() {
        let coordinator = CaptureCoordinator(); coordinator.requestCapture(.region)
        #expect(coordinator.requestedCommands == [.region])
    }
}
