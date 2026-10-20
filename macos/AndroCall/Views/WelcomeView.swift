import AndroCallCore
import SwiftUI

/// The welcome and onboarding screen.
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.xLarge) {
                header

                SectionHeader("What you need")
                VStack(alignment: .leading, spacing: Design.Spacing.small) {
                    step(1, "Install the androcall companion on your Android phone.",
                         "It is a small app that shares your contacts and reports your calls — and nothing else.")
                    step(2, "Pair the phone with this Mac in System Settings › Bluetooth.",
                         "macOS only lets you pair a device from its own settings, so androcall cannot do this for you.")
                    step(3, "Enter the pairing code shown by the companion.",
                         "The code authorises this Mac to use your phone. It is never sent anywhere but your phone.")
                    step(4, "Compare the verification code on both screens.",
                         "If the two codes differ, stop — something is intercepting the connection.")
                }

                SectionHeader("Privacy")
                Text("androcall works entirely between your Mac and your phone over Bluetooth. "
                     + "Your contacts, call history and phone numbers never leave your devices: there is no "
                     + "account, no server and no analytics.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Get started") {
                        model.startScanning()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    if settings.pairedDeviceIdentifier != nil {
                        Button("Reconnect to \(settings.pairedDeviceName)") {
                            model.startScanning()
                        }
                    }
                }
                .padding(.top, Design.Spacing.small)
            }
            .padding(Design.Spacing.xLarge)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack(spacing: Design.Spacing.medium) {
                Image(systemName: "phone.and.waveform.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Design.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("androcall")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Make and answer calls from your Mac")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            Text("Use your Android phone's contacts and calls from your Mac over Bluetooth.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Design.Spacing.medium) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Design.tinted(Design.accent)))
                .foregroundColor(Design.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The pairing screen: pick a phone, enter the PIN, verify the code.
struct PairDeviceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.large) {
            SectionHeader("Your Android phones")

            if model.bluetooth.discoveredDevices.isEmpty {
                HStack(spacing: Design.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for the androcall companion app…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Design.Spacing.small)
            } else {
                VStack(spacing: Design.Spacing.small) {
                    ForEach(model.bluetooth.discoveredDevices) { device in
                        Button {
                            model.pair(with: device)
                        } label: {
                            HStack(spacing: Design.Spacing.medium) {
                                Image(systemName: "iphone.gen3")
                                    .font(.system(size: 18))
                                    .foregroundColor(Design.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.displayName)
                                        .font(.system(size: 13, weight: .medium))
                                    Text("Signal \(device.rssi) dBm")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding(Design.Spacing.medium)
                            .background(
                                RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if model.connectionState == .connecting {
                Divider()
                SectionHeader("Authorising")
                pinEntry
            }

            if model.connectionState == .verifying || model.verificationCode != nil {
                Divider()
                SectionHeader("Verify the code")
                verification
            }

            Spacer()
        }
        .padding(Design.Spacing.xLarge)
    }

    private var pinEntry: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            Text("Enter the 6-digit code shown in the companion app on your phone.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Spacing.medium) {
                TextField("000000", text: $model.pinEntry)
                    .font(.system(size: 22, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 150)
                    .onChange(of: model.pinEntry) { value in
                        let digits = value.filter { $0.isNumber }
                        model.pinEntry = String(digits.prefix(6))
                    }
                Button("Connect") {
                    model.authenticate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.pinEntry.count != 6)
            }
        }
    }

    private var verification: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.medium) {
            HStack(spacing: Design.Spacing.medium) {
                Text(model.verificationCode ?? "····")
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                VStack(alignment: .leading, spacing: 2) {
                    Text("This code must match the one on your phone.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            Button("The codes match — continue") {
                model.confirmVerification()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
