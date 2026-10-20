import AndroCallCore
import SwiftUI

/// The incoming-call screen.
struct IncomingCallView: View {
    @ObservedObject var model: AppModel
    let call: AppModel.IncomingCall

    var body: some View {
        VStack(spacing: Design.Spacing.xLarge) {
            Spacer()
            Image(systemName: "phone.down.fill")
                .font(.system(size: 30))
                .foregroundColor(Design.danger)
                .frame(width: 68, height: 68)
                .background(Circle().fill(Design.tinted(Design.danger)))

            VStack(spacing: Design.Spacing.small) {
                Text(call.callerLabel)
                    .font(.system(size: 24, weight: .semibold))
                if let number = call.number, number != call.callerLabel {
                    Text(number)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Text("Incoming call")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: Design.Spacing.xLarge) {
                Button {
                    model.declineIncomingCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 62, height: 62)
                        .background(Circle().fill(Design.danger))
                }
                .buttonStyle(.plain)
                .help("Decline")

                Button {
                    model.answerIncomingCall()
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 62, height: 62)
                        .background(Circle().fill(Design.success))
                }
                .buttonStyle(.plain)
                .disabled(!model.callCapabilities.canAnswer)
                .opacity(model.callCapabilities.canAnswer ? 1 : 0.4)
                .help(model.callCapabilities.canAnswer
                      ? "Answer"
                      : "Answering needs androcall to be your phone's default dialer app.")
            }

            if !model.callCapabilities.canAnswer {
                Text(model.callCapabilities.reason
                     ?? "Your phone cannot answer calls remotely yet. Make androcall your default dialer on the phone to enable this.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .padding(Design.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The active-call screen.
struct ActiveCallView: View {
    @ObservedObject var model: AppModel
    let call: AppModel.ActiveCall

    var body: some View {
        VStack(spacing: Design.Spacing.xLarge) {
            Spacer()
            ContactPlaceholder(call: call)
            VStack(spacing: Design.Spacing.small) {
                Text(call.callerLabel)
                    .font(.system(size: 24, weight: .semibold))
                if let number = call.number, number != call.callerLabel {
                    Text(number)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Text(call.durationText)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
                StatusPill(call.state.displayName, color: Design.success, filled: true)
            }
            Spacer()

            HStack(spacing: Design.Spacing.xLarge) {
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 20))
                        .foregroundColor(call.isMuted ? .white : .primary)
                        .frame(width: 56, height: 56)
                        .background(
                            Circle().fill(call.isMuted ? Design.warning : Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!model.callCapabilities.canMute)
                .opacity(model.callCapabilities.canMute ? 1 : 0.4)
                .help(model.callCapabilities.canMute
                      ? "Mute the microphone"
                      : "Muting is only available when androcall is the phone's default dialer app.")

                Button {
                    model.endActiveCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Design.danger))
                }
                .buttonStyle(.plain)
                .help("End the call")
            }

            if !model.callCapabilities.canEnd {
                Text("Ending the call from the Mac needs androcall to be your phone's default dialer app.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .padding(Design.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A generic avatar for a caller that is not in the contact list.
private struct ContactPlaceholder: View {
    let call: AppModel.ActiveCall

    var body: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 78, weight: .thin))
            .foregroundColor(.secondary)
    }
}
