import AppKit
import SwiftUI
import AndroCallCore

/// The androcall application.
@main
struct AndroCallApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    NotificationRouter.shared.handler = { action, callId in
                        Task { @MainActor in
                            switch action {
                            case "ANDROCALL_ANSWER":
                                model.answerIncomingCall()
                            case "ANDROCALL_DECLINE":
                                model.declineIncomingCall()
                            default:
                                break
                            }
                        }
                    }
                }
        }
        .commands {
            CommandMenu("Phone") {
                Button("Dial") {
                    NotificationCenter.default.post(name: .androcallSelectContacts, object: nil)
                }
                .keyboardShortcut("d")
                Button("Sync contacts") {
                    Task { @MainActor in await model.syncContacts() }
                }
                .keyboardShortcut("r")
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension Notification.Name {
    static let androcallSelectContacts = Notification.Name("dev.androcall.selectContacts")
}

/// The root view: a sidebar with the main destinations.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem? = .dashboard
    @State private var showingIncomingCall = false

    enum SidebarItem: Hashable {
        case dashboard
        case contacts
        case recent
        case dial
        case settings
        case diagnostics
    }

    var body: some View {
        NavigationView {
            List(selection: $selection) {
                Section {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                        .tag(SidebarItem.dashboard)
                    Label("Contacts", systemImage: "person.2")
                        .tag(SidebarItem.contacts)
                    Label("Recent calls", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.recent)
                    Label("Dial", systemImage: "circle.grid.cross")
                        .tag(SidebarItem.dial)
                }
                Section {
                    Label("Settings", systemImage: "gearshape")
                        .tag(SidebarItem.settings)
                    Label("Diagnostics", systemImage: "stethoscope")
                        .tag(SidebarItem.diagnostics)
                }
            }
            .navigationTitle("androcall")
            .frame(minWidth: 190)

            detail
        }
        .frame(minWidth: 860, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: .androcallSelectContacts)) { _ in
            selection = .contacts
        }
        .onChange(of: model.incomingCall) { call in
            showingIncomingCall = call != nil
        }
        .sheet(isPresented: $showingIncomingCall) {
            if let call = model.incomingCall {
                IncomingCallView(model: model, call: call)
                    .frame(width: 420, height: 460)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let error = model.lastError {
                ErrorBanner(message: error) {
                    model.clearError()
                }
                .padding(Design.Spacing.medium)
            }
            switch selection ?? .dashboard {
            case .dashboard:
                DashboardView(model: model, settings: model.settings)
            case .contacts:
                ContactsView(model: model)
            case .recent:
                RecentCallsView(model: model)
            case .dial:
                DialPadView(model: model)
            case .settings:
                SettingsView(model: model, settings: model.settings)
            case .diagnostics:
                DiagnosticsView(model: model, settings: model.settings)
            }
        }
        .overlay(alignment: .bottom) {
            if let call = model.activeCall {
                ActiveCallBar(call: call) {
                    model.endActiveCall()
                }
                .padding(Design.Spacing.medium)
            }
        }
    }
}

/// A compact bar shown while a call is in progress.
struct ActiveCallBar: View {
    let call: AppModel.ActiveCall
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: Design.Spacing.medium) {
            Image(systemName: "phone.fill")
                .foregroundColor(Design.success)
            Text(call.callerLabel)
                .font(.system(size: 13, weight: .medium))
            Text(call.durationText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            Button("End", action: onEnd)
                .buttonStyle(.borderedProminent)
        }
        .padding(Design.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .frame(maxWidth: 460)
    }
}
