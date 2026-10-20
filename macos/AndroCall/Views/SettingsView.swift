import AndroCallCore
import SwiftUI

/// The settings screen.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var showForgetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.xLarge) {
                deviceSection
                behaviourSection
                appearanceSection
                privacySection
                aboutSection
            }
            .padding(Design.Spacing.xLarge)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Settings")
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("Device")
            DetailRow("Paired phone", settings.pairedDeviceName.isEmpty ? "None" : settings.pairedDeviceName)
            Toggle("Reconnect automatically", isOn: $settings.autoReconnect)
                .toggleStyle(.checkbox)
            Toggle("Synchronise contacts", isOn: $settings.contactSyncEnabled)
                .toggleStyle(.checkbox)
            if let date = model.lastSyncDate {
                DetailRow("Last sync", date.formatted(date: .abbreviated, time: .shortened))
            }
            HStack(spacing: Design.Spacing.small) {
                Button("Sync now") {
                    Task { await model.syncContacts() }
                }
                .disabled(!model.connectionState.isConnected)

                Button("Forget device") {
                    showForgetConfirmation = true
                }
            }
            .padding(.top, Design.Spacing.xSmall)
        }
    }

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("Notifications and startup")
            Toggle("Show notifications for incoming calls", isOn: $settings.notificationsEnabled)
                .toggleStyle(.checkbox)
            Toggle("Launch androcall at login", isOn: $settings.launchAtLogin)
                .toggleStyle(.checkbox)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("Appearance")
            Picker("Theme", selection: $settings.theme) {
                ForEach(SettingsStore.Theme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("Privacy")
            Text("androcall collects no analytics and has no telemetry. Your contacts and call data "
                 + "stay on your Mac and your phone, and are never uploaded.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete local contact data") {
                model.clearLocalContacts()
            }
            .disabled(model.contacts.isEmpty)
            Text("This removes the copy of your contacts stored by androcall on this Mac. "
                 + "Your phone's contacts are not affected.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("About")
            DetailRow("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
            DetailRow("Protocol", "androcall v1")
            DetailRow("Transport", "Bluetooth Low Energy (GATT)")
        }
    }
}
