import Foundation
import AndroCallCore

/// The local contact store.
///
/// Contacts live only in the Mac's application container. They are never sent
/// anywhere, and the user can wipe them from Settings.
public final class ContactStore {

    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("androcall", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("contacts.json")
    }

    /// Load the stored contacts.
    public func load() -> [Contact] {
        guard let data = try? Data(contentsOf: fileURL),
              let array = try? CanonicalJSON.parse(data),
              let values = array.arrayValue
        else { return [] }
        return values.compactMap(Contact.parse)
    }

    /// Store the contacts.
    public func save(_ contacts: [Contact]) {
        let value = JSONValue.array(contacts.map(\.jsonValue))
        do {
            try CanonicalJSON.data(value).write(to: fileURL, options: .atomic)
        } catch {
            DiagnosticsLog.shared.log("Could not save contacts: \(error.localizedDescription)", level: .warning)
        }
    }

    /// Delete every stored contact.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Whether any contact data is stored.
    public var hasStoredContacts: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}
