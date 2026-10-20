import Foundation
import Combine

/// A small, file-backed diagnostic log.
///
/// The log never contains contact data, call content or keys: it records
/// connection lifecycle events and protocol-level metadata only.
public final class DiagnosticsLog: ObservableObject {
    public static let shared = DiagnosticsLog()

    @Published public private(set) var entries: [Entry] = []

    public struct Entry: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let level: Level
        public let message: String

        public enum Level: String {
            case info
            case warning
            case error
        }
    }

    private let queue = DispatchQueue(label: "dev.androcall.log")
    private let store = UserDefaults.standard
    private let maximumEntries = 500
    private static let storageKey = "dev.androcall.diagnostics.entries"

    private init() {
        load()
    }

    public func log(_ message: String, level: Entry.Level = .info) {
        let entry = Entry(timestamp: Date(), level: level, message: message)
        queue.async {
            self.entries.append(entry)
            if self.entries.count > self.maximumEntries {
                self.entries.removeFirst(self.entries.count - self.maximumEntries)
            }
            self.save()
        }
    }

    public func clear() {
        queue.async {
            self.entries.removeAll()
            self.save()
        }
    }

    /// Export the log as plain text.
    public func export() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries
            .map { "[\(formatter.string(from: $0.timestamp))] \( $0.level.rawValue.uppercased()): \($0.message)" }
            .joined(separator: "\n")
    }

    private func save() {
        let payload = entries.map {
            ["t": $0.timestamp.timeIntervalSince1970, "l": $0.level.rawValue, "m": $0.message]
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            store.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        guard let data = store.data(forKey: Self.storageKey),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        entries = payload.compactMap { item in
            guard let timestamp = item["t"] as? Double,
                  let levelRaw = item["l"] as? String,
                  let message = item["m"] as? String,
                  let level = Entry.Level(rawValue: levelRaw)
            else { return nil }
            return Entry(timestamp: Date(timeIntervalSince1970: timestamp), level: level, message: message)
        }
    }
}
