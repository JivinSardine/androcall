import AndroCallCore
import SwiftUI

/// The dashboard: device, connection health, and shortcuts.
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.xLarge) {
                deviceCard
                shortcuts
                if model.contacts.isEmpty {
                    emptyContacts
                } else {
                    recentContacts
                }
            }
            .padding(Design.Spacing.xLarge)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Device")
                Spacer()
                StatusPill(
                    model.connectionState.title,
                    color: model.connectionState.isConnected ? Design.success : Design.warning,
                    filled: model.connectionState.isConnected
                )
            }

            if let info = model.deviceInfo {
                DetailRow("Phone", info.deviceName)
                if !info.model.isEmpty {
                    DetailRow("Model", "\(info.manufacturer) \(info.model)".trimmingCharacters(in: .whitespaces))
                }
                if !info.androidVersion.isEmpty {
                    DetailRow("Android", "\(info.androidVersion) (API \(info.sdkInt))")
                }
                if let battery = info.batteryLevel {
                    DetailRow("Battery", batteryChargingText(info))
                }
                DetailRow("Audio route", model.callCapabilities.audioRoute ?? "Phone earpiece")
            } else {
                Text(settings.pairedDeviceName.isEmpty
                     ? "No phone connected yet."
                     : "\(settings.pairedDeviceName) is not connected right now.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Button("Connect") { model.startScanning() }
            }
        }
        .padding(Design.Spacing.large)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func batteryChargingText(_ info: DeviceInfo) -> String {
        guard let charging = info.batteryCharging else { return "\(info.batteryLevel)%" }
        return charging ? "\(info.batteryLevel)% (charging)" : "\(info.batteryLevel)%"
    }

    private var shortcuts: some View {
        HStack(spacing: Design.Spacing.medium) {
            shortcut("Contacts", "person.2", contactsCount)
            shortcut("Dial", "circle.grid.cross", nil)
        }
    }

    private var contactsCount: String? {
        model.contacts.isEmpty ? nil : "\(model.contacts.count)"
    }

    private func shortcut(_ title: String, _ symbol: String, _ badge: String?) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundColor(Design.accent)
                Spacer()
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(Design.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var emptyContacts: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("Contacts")
            Text(model.contacts.isEmpty && model.connectionState.isConnected
                 ? "No contacts have been synchronised yet."
                 : "Connect your phone to browse your contacts.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            if model.connectionState.isConnected && settings.contactSyncEnabled {
                Button("Sync now") {
                    Task { await model.syncContacts() }
                }
            }
        }
    }

    private var recentContacts: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("Contacts", subtitle: "The first few, alphabetically")
            ForEach(model.contacts.prefix(6)) { contact in
                HStack(spacing: Design.Spacing.medium) {
                    ContactAvatar(contact: contact, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contact.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if let number = contact.preferredPhoneNumber?.number {
                            Text(number)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if contact.starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Design.warning)
                    }
                }
            }
        }
    }
}

/// A contact avatar that falls back to initials.
struct ContactAvatar: View {
    let contact: Contact
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let photo = contact.photo, let image = NSImage(data: photo) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(Design.tinted(Design.accent))
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.38, weight: .semibold))
                            .foregroundColor(Design.accent)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let parts = contact.displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
