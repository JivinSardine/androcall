import AndroCallCore
import SwiftUI

/// The numeric dial pad.
struct DialPadView: View {
    @ObservedObject var model: AppModel
    @State private var digits: String = ""

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"],
    ]

    var body: some View {
        VStack(spacing: Design.Spacing.xLarge) {
            display
            keypad
            actions
        }
        .padding(Design.Spacing.xLarge)
        .frame(maxWidth: 420)
        .navigationTitle("Dial")
    }

    private var display: some View {
        VStack(spacing: Design.Spacing.small) {
            Text(digits.isEmpty ? "Enter a number" : digits)
                .font(.system(size: 30, weight: .medium, design: .monospaced))
                .foregroundColor(digits.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
            if !digits.isEmpty {
                Text(PhoneNumberSanitizer.sanitize(digits))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var keypad: some View {
        VStack(spacing: Design.Spacing.small) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: Design.Spacing.small) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            press(key)
                        } label: {
                            Text(key)
                                .font(.system(size: 22, weight: .regular))
                                .frame(width: 66, height: 50)
                                .background(
                                    RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                                        .fill(Color.secondary.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Design.Spacing.small) {
            HStack(spacing: Design.Spacing.small) {
                Button {
                    if !digits.isEmpty { digits.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .frame(width: 60, height: 34)
                }
                .buttonStyle(.bordered)
                .disabled(digits.isEmpty)

                Button {
                    model.placeCall(number: digits)
                } label: {
                    Label("Call", systemImage: "phone.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!PhoneNumberSanitizer.isDialable(digits) || !model.connectionState.isConnected)
            }
            if !model.connectionState.isConnected {
                Text("Connect your phone to place a call.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func press(_ key: String) {
        guard digits.count < 20 else { return }
        digits.append(key)
    }
}
