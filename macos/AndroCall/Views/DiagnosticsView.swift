import AndroCallCore
import SwiftUI

/// The diagnostics and troubleshooting screen.
struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var log = DiagnosticsLog.shared
    @State private var exportedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.xLarge) {
                    status
                    capabilities
                    troubleshooting
                    logSection
                }
                .padding(Design.Spacing.xLarge)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Diagnostics")
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("Status")
            DetailRow("Connection", model.connectionState.title)
            DetailRow("Bluetooth", bluetoothStateText)
            DetailRow("MAC address", macAddressText)
            if let info = model.deviceInfo {
                DetailRow("Phone", info.deviceName)
                DetailRow("Android", "\(info.androidVersion) (API \(info.sdkInt))")
                DetailRow("Battery", info.batteryLevel.map { "\($0)%" } ?? "Unknown")
                DetailRow("Signal", info.signalStrength.map { "\($0) dBm" } ?? "Unknown")
            }
            DetailRow("Contacts stored", "\(model.contacts.count)")
            DetailRow("Recent calls", "\(model.recentCalls.count)")
        }
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("Phone capabilities", subtitle: "What the phone can actually do right now")
            DetailRow("Answer calls", capabilityText(model.callCapabilities.canAnswer))
            DetailRow("Decline calls", capabilityText(model.callCapabilities.canDecline))
            DetailRow("End calls", capabilityText(model.callCapabilities.canEnd))
            DetailRow("Mute microphone", capabilityText(model.callCapabilities.canMute))
            DetailRow("Audio route", model.callCapabilities.audioRoute ?? "Phone earpiece")
            DetailRow("Default dialer", model.callCapabilities.isDefaultDialer ? "Yes" : "No")
            if let reason = model.callCapabilities.reason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func capabilityText(_ value: Bool) -> String {
        value ? "Supported" : "Not supported"
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            SectionHeader("Common problems")
            trouble(
                "The phone is not listed",
                "Make sure the companion app is running on the phone and that Bluetooth is on. "
                + "The phone must be paired with this Mac in System Settings › Bluetooth first."
            )
            trouble(
                "Incoming calls do not arrive",
                "Android puts background apps to sleep. Exempt androcall from battery optimisation in "
                + "Settings › Apps › androcall, and keep the companion's notification enabled."
            )
            trouble(
                "Answer and end are greyed out",
                "Android only lets a third-party app answer and end calls when it is the phone's "
                + "default dialer app. Set androcall as the default dialer on the phone to enable them."
            )
            trouble(
                "The verification codes differ",
                "Stop the pairing. The codes must be identical on both screens; if they are not, "
                + "something is intercepting the Bluetooth link."
            )
        }
    }

    private func trouble(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Design.Spacing.small)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack {
                SectionHeader("Diagnostic log")
                Spacer()
                Button("Copy log") {
                    exportedText = model.exportLog()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exportedText, forType: .string)
                }
                Button("Clear") {
                    log.clear()
                }
            }
            if log.entries.isEmpty {
                Text("The log is empty.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(log.entries.suffix(60).reversed()) { entry in
                        HStack(alignment: .top, spacing: Design.Spacing.small) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(entry.message)
                                .font(.system(size: 11, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Design.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
        }
    }

    private var bluetoothStateText: String {
        switch model.bluetooth.bluetoothState {
        case .poweredOn: return "On"
        case .poweredOff: return "Off"
        case .unauthorized: return "Not permitted"
        case .unsupported: return "Unsupported"
        case .resetting: return "Restarting"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    private var macAddressText: String {
        settings.pairedDeviceIdentifier.map { $0.uuidString } ?? "Not paired"
    }
}
