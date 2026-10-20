import Foundation
import Combine
import AndroCallCore

/// User-facing settings, persisted in `UserDefaults`.
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    private enum Key {
        static let pairedDeviceIdentifier = "dev.androcall.pairedDeviceIdentifier"
        static let pairedDeviceName = "dev.androcall.pairedDeviceName"
        static let autoReconnect = "dev.androcall.autoReconnect"
        static let contactSync = "dev.androcall.contactSync"
        static let notifications = "dev.androcall.notifications"
        static let launchAtLogin = "dev.androcall.launchAtLogin"
        static let theme = "dev.androcall.theme"
        static let lastSyncWatermark = "dev.androcall.lastSyncWatermark"
    }

    /// The appearance the user selected.
    public enum Theme: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    @Published public var pairedDeviceIdentifier: UUID? {
        didSet { store.set(pairedDeviceIdentifier?.uuidString, forKey: Key.pairedDeviceIdentifier) }
    }

    @Published public var pairedDeviceName: String {
        didSet { store.set(pairedDeviceName, forKey: Key.pairedDeviceName) }
    }

    @Published public var autoReconnect: Bool {
        didSet { store.set(autoReconnect, forKey: Key.autoReconnect) }
    }

    @Published public var contactSyncEnabled: Bool {
        didSet { store.set(contactSyncEnabled, forKey: Key.contactSync) }
    }

    @Published public var notificationsEnabled: Bool {
        didSet { store.set(notificationsEnabled, forKey: Key.notifications) }
    }

    @Published public var launchAtLogin: Bool {
        didSet { store.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    @Published public var theme: Theme {
        didSet { store.set(theme.rawValue, forKey: Key.theme) }
    }

    /// The watermark of the last successful contact synchronisation.
    public var lastSyncWatermark: Int64? {
        get {
            guard let value = store.object(forKey: Key.lastSyncWatermark) as? NSNumber else { return nil }
            return value.int64Value
        }
        set {
            store.set(newValue, forKey: Key.lastSyncWatermark)
        }
    }

    private let store: UserDefaults

    public init(store: UserDefaults = .standard) {
        self.store = store
        pairedDeviceIdentifier = (store.string(forKey: Key.pairedDeviceIdentifier)).flatMap(UUID.init(uuidString:))
        pairedDeviceName = store.string(forKey: Key.pairedDeviceName) ?? ""
        autoReconnect = store.object(forKey: Key.autoReconnect) as? Bool ?? true
        contactSyncEnabled = store.object(forKey: Key.contactSync) as? Bool ?? true
        notificationsEnabled = store.object(forKey: Key.notifications) as? Bool ?? true
        launchAtLogin = store.object(forKey: Key.launchAtLogin) as? Bool ?? false
        theme = Theme(rawValue: store.string(forKey: Key.theme) ?? "system") ?? .system
    }

    /// Forget the paired device.
    public func forgetDevice() {
        pairedDeviceIdentifier = nil
        pairedDeviceName = ""
        lastSyncWatermark = nil
    }
}
