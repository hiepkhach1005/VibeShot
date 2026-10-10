import AppKit
import Carbon
import Foundation
import ServiceManagement

enum OutputFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg, heic, bmp
    var displayName: String { rawValue.uppercased() }
    var supportsQuality: Bool { self == .jpeg || self == .heic }
}

enum SaveDestination: String, Codable, CaseIterable, Sendable {
    case askEveryTime, recentFolder
    var displayName: String { self == .askEveryTime ? "Ask Every Time" : "Most Recent Folder" }
}

/// A versioned security-scoped folder bookmark. The bookmark is optional because the current
/// development build is intentionally not sandboxed, but retaining the versioned envelope keeps
/// a future sandboxed build from interpreting an old payload as a different bookmark format.
struct FolderBookmark: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let data: Data

    init(version: Int = currentVersion, data: Data) {
        self.version = version
        self.data = data
    }

    var isCurrent: Bool { version == Self.currentVersion && !data.isEmpty }
}

typealias SecurityScopedFolderBookmark = FolderBookmark

struct ShortcutDefinition: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var isEnabled: Bool
    static let defaultRegion = ShortcutDefinition(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | shiftKey), isEnabled: true)
    static let disabledFullScreen = ShortcutDefinition(keyCode: UInt32(kVK_ANSI_0), modifiers: 0, isEnabled: false)
    var displayName: String {
        guard isEnabled else { return "Disabled" }
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        let digits: [UInt32: String] = [UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9"]
        value += digits[keyCode] ?? "Key \(keyCode)"
        return value
    }
    var isValid: Bool { !isEnabled || modifiers != 0 }
}

struct AppSettings: Codable, Equatable, Sendable {
    static let currentVersion = 4
    static let fixedImageQuality = 100
    var version = currentVersion
    var regionShortcut = ShortcutDefinition.defaultRegion
    var fullScreenShortcut = ShortcutDefinition.disabledFullScreen
    var outputFormat = OutputFormat.png
    var imageQuality = fixedImageQuality
    var saveDestination = SaveDestination.askEveryTime
    var recentFolderPath: String?
    var recentFolderBookmark: FolderBookmark?
    var rememberLastRegion = false
    var rememberedRegions: [String: RememberedRegion] = [:]

    /// M4 style preferences. Missing keys decode to these defaults so version-1 settings remain
    /// readable without a destructive reset.
    var lastColor = AnnotationColor.defaultColor
    var lastStrokeWidth = Double(AnnotationStyle.default.width)

    private enum CodingKeys: String, CodingKey {
        case version, regionShortcut, fullScreenShortcut, outputFormat, imageQuality, saveDestination,
             recentFolderPath, recentFolderBookmark, recentFolderBookmarkData, lastColor, lastStrokeWidth,
             rememberLastRegion, rememberedRegions
    }

    init() {}

    init(
        version: Int = currentVersion,
        regionShortcut: ShortcutDefinition = .defaultRegion,
        fullScreenShortcut: ShortcutDefinition = .disabledFullScreen,
        outputFormat: OutputFormat = .png,
        imageQuality: Int = fixedImageQuality,
        saveDestination: SaveDestination = .askEveryTime,
        recentFolderPath: String? = nil,
        recentFolderBookmark: FolderBookmark? = nil,
        lastColor: AnnotationColor = .defaultColor,
        lastStrokeWidth: Double = Double(AnnotationStyle.default.width),
        rememberLastRegion: Bool = false,
        rememberedRegions: [String: RememberedRegion] = [:]
    ) {
        self.version = version
        self.regionShortcut = regionShortcut
        self.fullScreenShortcut = fullScreenShortcut
        self.outputFormat = outputFormat
        self.imageQuality = imageQuality
        self.saveDestination = saveDestination
        self.recentFolderPath = recentFolderPath
        self.recentFolderBookmark = recentFolderBookmark
        self.lastColor = lastColor
        self.lastStrokeWidth = lastStrokeWidth
        self.rememberLastRegion = rememberLastRegion
        self.rememberedRegions = rememberedRegions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        regionShortcut = try values.decodeIfPresent(ShortcutDefinition.self, forKey: .regionShortcut) ?? .defaultRegion
        fullScreenShortcut = try values.decodeIfPresent(ShortcutDefinition.self, forKey: .fullScreenShortcut) ?? .disabledFullScreen
        outputFormat = try values.decodeIfPresent(OutputFormat.self, forKey: .outputFormat) ?? .png
        imageQuality = try values.decodeIfPresent(Int.self, forKey: .imageQuality) ?? Self.fixedImageQuality
        saveDestination = try values.decodeIfPresent(SaveDestination.self, forKey: .saveDestination) ?? .askEveryTime
        recentFolderPath = try values.decodeIfPresent(String.self, forKey: .recentFolderPath)
        recentFolderBookmark = try values.decodeIfPresent(FolderBookmark.self, forKey: .recentFolderBookmark)
            ?? values.decodeIfPresent(Data.self, forKey: .recentFolderBookmarkData).map { FolderBookmark(data: $0) }
        lastColor = try values.decodeIfPresent(AnnotationColor.self, forKey: .lastColor) ?? .defaultColor
        lastStrokeWidth = try values.decodeIfPresent(Double.self, forKey: .lastStrokeWidth) ?? Double(AnnotationStyle.default.width)
        rememberLastRegion = (try? values.decode(Bool.self, forKey: .rememberLastRegion)) ?? false
        rememberedRegions = [:]
        if values.contains(.rememberedRegions),
           let entries = try? values.nestedContainer(keyedBy: RegionCodingKey.self, forKey: .rememberedRegions) {
            for key in entries.allKeys {
                if let region = try? entries.decode(RememberedRegion.self, forKey: key), region.isValid {
                    rememberedRegions[key.stringValue] = region
                }
            }
        }
        validate()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(regionShortcut, forKey: .regionShortcut)
        try values.encode(fullScreenShortcut, forKey: .fullScreenShortcut)
        try values.encode(outputFormat, forKey: .outputFormat)
        try values.encode(imageQuality, forKey: .imageQuality)
        try values.encode(saveDestination, forKey: .saveDestination)
        try values.encodeIfPresent(recentFolderPath, forKey: .recentFolderPath)
        try values.encodeIfPresent(recentFolderBookmark, forKey: .recentFolderBookmark)
        try values.encode(lastColor, forKey: .lastColor)
        try values.encode(lastStrokeWidth, forKey: .lastStrokeWidth)
        try values.encode(rememberLastRegion, forKey: .rememberLastRegion)
        try values.encode(rememberedRegions, forKey: .rememberedRegions)
    }

    /// Compatibility aliases for callers that use the shorter style vocabulary.
    var strokeWidth: Double {
        get { lastStrokeWidth }
        set { lastStrokeWidth = newValue }
    }

    /// Compatibility access for callers that persist only the bookmark bytes. New writes use the
    /// versioned `FolderBookmark` envelope above.
    var recentFolderBookmarkData: Data? {
        get { recentFolderBookmark?.data }
        set { recentFolderBookmark = newValue.map { FolderBookmark(data: $0) } }
    }

    mutating func validate() {
        version = Self.currentVersion
        imageQuality = Self.fixedImageQuality
        rememberedRegions = rememberLastRegion ? rememberedRegions.filter { $0.value.isValid } : [:]
        if !regionShortcut.isValid { regionShortcut = .defaultRegion }
        if !fullScreenShortcut.isValid { fullScreenShortcut = .disabledFullScreen }
        if let bookmark = recentFolderBookmark, !bookmark.isCurrent { recentFolderBookmark = nil }
        if saveDestination == .recentFolder, recentFolderPath == nil, recentFolderBookmark == nil { saveDestination = .askEveryTime }
        lastStrokeWidth = lastStrokeWidth.isFinite ? min(max(lastStrokeWidth, 0.5), 128) : Double(AnnotationStyle.default.width)
        lastColor = AnnotationColor(red: lastColor.red, green: lastColor.green, blue: lastColor.blue, alpha: lastColor.alpha)
    }

    private struct RegionCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

protocol SettingsPersisting: AnyObject {
    var settings: AppSettings { get }
    var loadError: SettingsStoreError? { get }
    func update(_ mutation: (inout AppSettings) -> Void) throws
}

enum SettingsStoreError: LocalizedError, Equatable {
    case corruptPayload
    case futureVersion(Int)
    case encodeFailed(String)
    case persistFailed(String)
    var errorDescription: String? {
        switch self {
        case .corruptPayload: "Saved settings were unreadable. A backup was preserved and safe defaults are in use."
        case let .futureVersion(version): "These settings were created by a newer VibeShot version (\(version)). A backup was preserved."
        case let .encodeFailed(message): "Settings could not be encoded: \(message)"
        case let .persistFailed(message): "Settings could not be saved: \(message)"
        }
    }
}

protocol SettingsDataBacking: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String) throws
}

final class UserDefaultsSettingsBacking: SettingsDataBacking {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data, forKey key: String) throws { defaults.set(data, forKey: key) }
}

final class SettingsStore: SettingsPersisting {
    private static let key = "settings.v1"
    private static let backupKey = "settings.v1.recovery-backup"
    private let backing: SettingsDataBacking
    private(set) var settings: AppSettings
    private(set) var loadError: SettingsStoreError?
    convenience init(defaults: UserDefaults = .standard) { self.init(backing: UserDefaultsSettingsBacking(defaults)) }
    init(backing: SettingsDataBacking) {
        self.backing = backing
        guard let data = backing.data(forKey: Self.key) else { settings = AppSettings(); return }
        do {
            let version = try JSONDecoder().decode(VersionEnvelope.self, from: data).version
            guard version <= AppSettings.currentVersion else {
                settings = AppSettings(); loadError = .futureVersion(version); preserveBackup(data); return
            }
            var value = try JSONDecoder().decode(AppSettings.self, from: data)
            value.validate(); settings = value
        } catch {
            settings = AppSettings(); loadError = .corruptPayload; preserveBackup(data)
        }
    }
    func update(_ mutation: (inout AppSettings) -> Void) throws {
        var candidate = settings
        mutation(&candidate); candidate.validate()
        let data: Data
        do { data = try JSONEncoder().encode(candidate) }
        catch { throw SettingsStoreError.encodeFailed(error.localizedDescription) }
        do { try backing.set(data, forKey: Self.key) }
        catch { throw SettingsStoreError.persistFailed(error.localizedDescription) }
        settings = candidate
    }
    private func preserveBackup(_ data: Data) {
        guard backing.data(forKey: Self.backupKey) == nil else { return }
        try? backing.set(data, forKey: Self.backupKey)
    }
    private struct VersionEnvelope: Decodable {
        let version: Int

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }

        private enum CodingKeys: String, CodingKey { case version }
    }
}

enum LoginItemState: Equatable { case enabled, disabled, requiresApproval, unavailable(String) }
@MainActor protocol LoginItemServicing: AnyObject {
    var state: LoginItemState { get }
    func setEnabled(_ enabled: Bool) throws
}

final class LoginItemService: LoginItemServicing {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable("Install VibeShot in Applications before changing Launch at Login.")
        @unknown default: .unavailable("Unknown Launch at Login state.")
        }
    }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

enum ShortcutKind: UInt32, CaseIterable { case region = 1, fullScreen = 2 }
enum ShortcutRegistrationError: LocalizedError, Equatable {
    case conflict, invalid, system(OSStatus)
    var errorDescription: String? {
        switch self {
        case .conflict: "That shortcut is already used by another application."
        case .invalid: "Choose a key with at least one modifier."
        case let .system(code): "Shortcut registration failed (error \(code))."
        }
    }
}

enum ShortcutUpdateError: LocalizedError, Equatable {
    case rollbackFailed(persistence: String, restoration: String)
    var errorDescription: String? {
        switch self {
        case let .rollbackFailed(persistence, restoration):
            "The shortcut setting could not be saved, and the previous shortcut could not be restored. The shortcut was disabled to keep runtime state deterministic. Save error: \(persistence). Restore error: \(restoration)."
        }
    }
}
@MainActor protocol HotKeyRegistering: AnyObject {
    func register(kind: ShortcutKind, shortcut: ShortcutDefinition) throws
    func unregister(kind: ShortcutKind)
}

@MainActor final class UnavailableHotKeyService: HotKeyRegistering {
    private let error: Error
    init(error: Error) { self.error = error }
    func register(kind: ShortcutKind, shortcut: ShortcutDefinition) throws { throw error }
    func unregister(kind: ShortcutKind) {}
}

@MainActor
final class GlobalShortcutService: HotKeyRegistering {
    private static let signature: OSType = 0x56425348
    private var references: [ShortcutKind: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    var onTrigger: ((ShortcutKind) -> Void)?
    init() throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout.size(ofValue: id), nil, &id)
            guard result == noErr, id.signature == GlobalShortcutService.signature, let kind = ShortcutKind(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcutService>.fromOpaque(userData).takeUnretainedValue().onTrigger?(kind)
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr, handler != nil else { throw ShortcutRegistrationError.system(result) }
    }
    isolated deinit {
        references.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
    func register(kind: ShortcutKind, shortcut: ShortcutDefinition) throws {
        guard shortcut.isValid else { throw ShortcutRegistrationError.invalid }
        guard shortcut.isEnabled else { unregister(kind: kind); return }
        var candidate: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: kind.rawValue)
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &candidate)
        guard result == noErr, let candidate else {
            if result == eventHotKeyExistsErr { throw ShortcutRegistrationError.conflict }
            throw ShortcutRegistrationError.system(result)
        }
        let previous = references.updateValue(candidate, forKey: kind)
        if let previous { UnregisterEventHotKey(previous) }
    }
    func unregister(kind: ShortcutKind) {
        if let reference = references.removeValue(forKey: kind) { UnregisterEventHotKey(reference) }
    }
}

@MainActor
final class ShortcutSettingsCoordinator {
    private let settingsStore: SettingsPersisting
    private let registrar: HotKeyRegistering
    init(settingsStore: SettingsPersisting, registrar: HotKeyRegistering) {
        self.settingsStore = settingsStore; self.registrar = registrar
    }
    func installPersisted() throws {
        try registrar.register(kind: .region, shortcut: settingsStore.settings.regionShortcut)
        do { try registrar.register(kind: .fullScreen, shortcut: settingsStore.settings.fullScreenShortcut) }
        catch { registrar.unregister(kind: .region); throw error }
    }
    func replace(kind: ShortcutKind, with candidate: ShortcutDefinition) throws -> Bool {
        guard candidate.isValid else { throw ShortcutRegistrationError.invalid }
        let current = shortcut(for: kind)
        guard candidate != current else { return false }
        let other = shortcut(for: kind == .region ? .fullScreen : .region)
        if candidate.isEnabled, other.isEnabled, candidate.keyCode == other.keyCode, candidate.modifiers == other.modifiers {
            throw ShortcutRegistrationError.conflict
        }
        if candidate.isEnabled { try registrar.register(kind: kind, shortcut: candidate) }
        else { registrar.unregister(kind: kind) }
        do {
            try settingsStore.update { settings in
                if kind == .region { settings.regionShortcut = candidate } else { settings.fullScreenShortcut = candidate }
            }
            return true
        } catch {
            if current.isEnabled {
                do {
                    try registrar.register(kind: kind, shortcut: current)
                } catch let restorationError {
                    registrar.unregister(kind: kind)
                    throw ShortcutUpdateError.rollbackFailed(
                        persistence: error.localizedDescription,
                        restoration: restorationError.localizedDescription
                    )
                }
            } else {
                registrar.unregister(kind: kind)
            }
            throw error
        }
    }
    private func shortcut(for kind: ShortcutKind) -> ShortcutDefinition {
        kind == .region ? settingsStore.settings.regionShortcut : settingsStore.settings.fullScreenShortcut
    }
}

@MainActor
final class ShortcutRecorderView: NSView {
    var onRecord: ((ShortcutDefinition) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onCancel?(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        let value = ShortcutDefinition(keyCode: UInt32(event.keyCode), modifiers: modifiers, isEnabled: true)
        if value.isValid { onRecord?(value) } else { NSSound.beep() }
    }
}
