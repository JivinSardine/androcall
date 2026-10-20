import AndroCallCore
import SwiftUI

/// The recent-calls list.
///
/// The call log lives on the phone, so this view is only useful once the phone
/// has granted the call-log permission. When it has not, the screen says so
/// rather than showing an empty list.
struct RecentCallsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.recentCalls.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "No recent calls",
                    message: model.recentPermissionDenied
                        ? "Your phone has not allowed androcall to read the call log, so recent calls are unavailable."
                        : "Recent calls from your phone will appear here.",
                    actionTitle: model.recentPermissionDenied ? nil : "Refresh",
                    action: model.recentPermissionDenied ? nil : {
                        model.loadRecentCalls()
                    }
                )
            } else {
                list
            }
        }
        .navigationTitle("Recent calls")
        .onAppear { model.loadRecentCalls() }
    }

    private var toolbar: some View {
        HStack {
            Text("On your phone")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Button {
                model.loadRecentCalls()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(!model.connectionState.isConnected)
            .help("Refresh the list")
        }
        .padding(Design.Spacing.medium)
    }

    private var list: some View {
        List(model.recentCalls) { call in
            HStack(spacing: Design.Spacing.medium) {
                Image(systemName: symbol(for: call.kind))
                    .foregroundColor(color(for: call.kind))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.displayName?.isEmpty == false ? call.displayName! : call.number)
                        .font(.system(size: 13, weight: .medium))
                    HStack(spacing: Design.Spacing.small) {
                        Text(call.number)
                        Text(callDate(call).formatted(date: .abbreviated, time: .shortened))
                            .foregroundColor(.secondary)
                        if let duration = call.durationMilliseconds, duration > 0 {
                            Text(DurationFormatter.string(milliseconds: duration))
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                }
                Spacer()
                Button("Call") {
                    model.placeCall(number: call.number)
                }
                .buttonStyle(.bordered)
                .disabled(!model.connectionState.isConnected)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    /// The call's timestamp is Unix epoch milliseconds.
    private func callDate(_ call: RecentCall) -> Date {
        Date(timeIntervalSince1970: Double(call.timestamp) / 1000)
    }

    private func symbol(for kind: RecentCall.Kind) -> String {
        switch kind {
        case .incoming: return "phone.arrow.down.left"
        case .outgoing: return "phone.arrow.up.right"
        case .missed: return "phone.arrow.down.left"
        case .rejected: return "phone.slash"
        case .unknown: return "phone"
        }
    }

    private func color(for kind: RecentCall.Kind) -> Color {
        switch kind {
        case .missed, .rejected: return Design.danger
        case .incoming: return Design.success
        case .outgoing: return Design.accent
        case .unknown: return .secondary
        }
    }
}
