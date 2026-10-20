import Combine
import Foundation
import AndroCallCore

/// The application state that the SwiftUI views observe.
@MainActor
public final class AppModel: ObservableObject {

    // MARK: - Connection

    @Published public private(set) var connectionState: ConnectionState = .idle
    @Published public private(set) var deviceInfo: DeviceInfo?
    @Published public private(set) var callCapabilities = CallCapabilities()
    @Published public private(set) var peerCapabilities: Capabilities = []

    /// The PIN the user typed for the current pairing attempt.
    @Published public var pinEntry: String = ""
    /// The verification code the user compares on both screens.
    @Published public private(set) var verificationCode: String?
    /// Whether the user has confirmed that both codes match.
    @Published public var verificationConfirmed = false

    @Published public private(set) var lastError: String?

    // MARK: - Data

    @Published public private(set) var contacts: [Contact] = []
    @Published public private(set) var recentCalls: [RecentCall] = []
    /// Whether the phone refused to share the call log.
    @Published public private(set) var recentPermissionDenied = false
    @Published public private(set) var contactSyncProgress: Double?
    @Published public private(set) var contactSyncMessage: String = ""
    @Published public private(set) var lastSyncDate: Date?

    // MARK: - Calls

    @Published public private(set) var incomingCall: IncomingCall?
    @Published public private(set) var activeCall: ActiveCall?

    // MARK: - Dependencies

    public let bluetooth: BluetoothManager
    public let settings: SettingsStore
    public let notifications: NotificationService
    public let store: ContactStore
    private var session: Session?
    private var cancellables = Set<AnyCancellable>()

    public enum ConnectionState: Equatable {
        case idle
        case scanning
        case connecting
        case authenticating
        case verifying
        case connected
        case disconnected(String?)
        case failed(String)

        public var isConnected: Bool { self == .connected }

        public var title: String {
            switch self {
            case .idle: return "Not connected"
            case .scanning: return "Looking for your phone…"
            case .connecting: return "Connecting…"
            case .authenticating: return "Authorising…"
            case .verifying: return "Check the code on your phone"
            case .connected: return "Connected"
            case .disconnected: return "Disconnected"
            case .failed: return "Connection problem"
            }
        }
    }

    /// An incoming call awaiting an answer.
    public struct IncomingCall: Identifiable, Equatable {
        public let id: String
        public let number: String?
        public let displayName: String?
        public let receivedAt: Date

        public var callerLabel: String {
            if let name = displayName, !name.isEmpty { return name }
            if let number = number, !number.isEmpty { return number }
            return "Unknown caller"
        }
    }

    /// The call that is currently in progress.
    public struct ActiveCall: Identifiable, Equatable {
        public let id: String
        public let number: String?
        public let displayName: String?
        public var state: CallState
        public var startedAt: Date?
        public var isMuted: Bool = false
        public var durationMilliseconds: Int64 = 0

        public var callerLabel: String {
            if let name = displayName, !name.isEmpty { return name }
            if let number = number, !number.isEmpty { return number }
            return "Unknown caller"
        }

        public var durationText: String {
            DurationFormatter.string(milliseconds: durationMilliseconds)
        }
    }

    public init(
        bluetooth: BluetoothManager = BluetoothManager(),
        settings: SettingsStore = .shared,
        notifications: NotificationService = NotificationService(),
        store: ContactStore = ContactStore()
    ) {
        self.bluetooth = bluetooth
        self.settings = settings
        self.notifications = notifications
        self.store = store

        bluetooth.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleTransportState(state) }
        }
    }

    // MARK: - Pairing

    /// Start looking for a phone.
    public func startScanning() {
        connectionState = .scanning
        bluetooth.start()
    }

    /// Connect to a discovered phone and begin the handshake.
    public func pair(with device: BluetoothManager.DiscoveredDevice) {
        connectionState = .connecting
        lastError = nil
        verificationConfirmed = false
        verificationCode = nil
        settings.pairedDeviceIdentifier = device.id
        settings.pairedDeviceName = device.displayName
        bluetooth.connect(to: device)
    }

    /// Begin the protocol handshake with the PIN the user entered.
    public func authenticate() {
        guard let session = session else { return }
        connectionState = .authenticating
        do {
            try session.start(pin: pinEntry)
        } catch {
            report(error)
        }
    }

    /// The user confirmed that both verification codes match.
    public func confirmVerification() {
        verificationConfirmed = true
        connectionState = .connected
        settings.pairedDeviceName = bluetooth.peerName ?? settings.pairedDeviceName
        if settings.contactSyncEnabled {
            Task { await syncContacts() }
        }
    }

    // MARK: - Contacts

    public func syncContacts() async {
        guard let session = session, session.state.isReady else { return }
        contactSyncProgress = 0
        contactSyncMessage = "Requesting contacts…"
        let requestId = Message.newIdentifier()
        do {
            let reply = try await session.request("contacts.request", body: [
                "requestId": .string(requestId),
                "since": settings.lastSyncWatermark.map { JSONValue.int($0) } ?? .null,
            ])
            if reply.string("requestId") != nil { /* the batches arrive as events */ }
            contactSyncMessage = "Waiting for contacts…"
        } catch {
            contactSyncProgress = nil
            contactSyncMessage = ""
            report(error)
        }
    }

    /// Ask the phone for its recent calls.
    public func loadRecentCalls() {
        guard let session = session, session.state.isReady else { return }
        let requestId = Message.newIdentifier()
        Task {
            do {
                _ = try await session.request("recents.request", body: [
                    "requestId": .string(requestId),
                    "limit": .int(50),
                ])
                recentPermissionDenied = false
            } catch {
                report(error)
            }
        }
    }

    public func search(_ text: String) -> [Contact] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return contacts }
        return contacts.filter { contact in
            if contact.displayName.lowercased().contains(needle) { return true }
            if contact.phoneNumbers.contains(where: { $0.number.lowercased().contains(needle) }) {
                return true
            }
            return false
        }
    }

    public var starredContacts: [Contact] {
        contacts.filter(\.starred)
    }

    /// Toggle the favourite flag of a contact.
    public func toggleFavorite(_ contact: Contact) {
        guard let session = session, session.state.isReady else { return }
        let requestId = Message.newIdentifier()
        Task {
            do {
                _ = try await session.request("contact.favorite.set", body: [
                    "requestId": .string(requestId),
                    "contactId": .string(contact.id),
                    "favorite": .bool(!contact.starred),
                ])
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Calls

    /// Place a call. This is only ever called from an explicit user action.
    public func placeCall(number: String, contact: Contact? = nil) {
        guard let session = session, session.state.isReady else {
            report(ProtocolError(code: "not_ready", message: "The phone is not connected."))
            return
        }
        let sanitized = PhoneNumberSanitizer.sanitize(number)
        guard PhoneNumberSanitizer.isDialable(sanitized) else {
            report(ProtocolError(code: "invalid_number", message: "That number cannot be dialled."))
            return
        }
        guard !activeCallCallsInProgress else {
            report(ProtocolError(code: "busy", message: "A call is already in progress."))
            return
        }
        let requestId = Message.newIdentifier()
        Task {
            do {
                let reply = try await session.request("call.place", body: [
                    "requestId": .string(requestId),
                    "number": .string(sanitized),
                    "contactId": contact.map { JSONValue.string($0.id) } ?? .null,
                    "displayName": contact.map { JSONValue.string($0.displayName) } ?? .null,
                ])
                if reply.bool("accepted") == false {
                    report(ProtocolError(
                        code: reply.string("code") ?? "rejected",
                        message: reply.string("message") ?? "The phone refused the call."
                    ))
                }
            } catch {
                report(error)
            }
        }
    }

    private var activeCallCallsInProgress: Bool {
        if activeCall != nil { return true }
        if let incoming = incomingCall { return incoming.id.isEmpty == false }
        return false
    }

    public func answerIncomingCall() {
        guard let incoming = incomingCall, let session = session else { return }
        let requestId = Message.newIdentifier()
        Task {
            do {
                _ = try await session.request("call.answer", body: [
                    "requestId": .string(requestId),
                    "callId": .string(incoming.id),
                ])
                self.incomingCall = nil
            } catch {
                report(error)
            }
        }
    }

    public func declineIncomingCall() {
        guard let incoming = incomingCall, let session = session else { return }
        let requestId = Message.newIdentifier()
        Task {
            do {
                _ = try await session.request("call.decline", body: [
                    "requestId": .string(requestId),
                    "callId": .string(incoming.id),
                ])
            } catch {
                report(error)
            }
            self.incomingCall = nil
        }
    }

    public func endActiveCall() {
        guard let call = activeCall, let session = session else { return }
        let requestId = Message.newIdentifier()
        Task {
            do {
                _ = try await session.request("call.end", body: [
                    "requestId": .string(requestId),
                    "callId": .string(call.id),
                ])
            } catch {
                report(error)
            }
        }
    }

    public func toggleMute() {
        guard var call = activeCall, let session = session else { return }
        call.isMuted.toggle()
        activeCall = call
        let requestId = Message.newIdentifier()
        Task {
            do {
                _ = try await session.request("call.mute", body: [
                    "requestId": .string(requestId),
                    "callId": .string(call.id),
                    "muted": .bool(call.isMuted),
                ])
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Internals

    private func handleTransportState(_ state: TransportState) {
        switch state {
        case .discovering:
            connectionState = .scanning
        case .connected:
            createSession()
        case .disconnected(let reason):
            connectionState = .disconnected(reason)
            session = nil
            deviceInfo = nil
            callCapabilities = CallCapabilities()
        case .failed(let reason):
            connectionState = .failed(reason)
        case .idle, .connecting, .disconnecting:
            break
        }
    }

    private func createSession() {
        let session = Session(transport: bluetooth)
        session.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleSessionState(state) }
        }
        session.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.session = session
        connectionState = .authenticating
        // The PIN is supplied by the user; the handshake starts once it is entered.
    }

    private func handleSessionState(_ state: SessionState) {
        switch state {
        case .authenticating:
            connectionState = .authenticating
        case .ready:
            verificationCode = session?.verificationCode
            peerCapabilities = session?.peerCapabilities ?? Capabilities()
            connectionState = .verifying
            // Ask the phone what it can actually do, so the Mac only enables
            // the controls the phone supports.
            requestCallCapabilities()
        case .failed(let reason):
            connectionState = .failed(reason)
            lastError = reason
        case .disconnected(let reason):
            connectionState = .disconnected(reason)
        default:
            break
        }
    }

    /// Ask the phone which call controls it supports.
    private func requestCallCapabilities() {
        guard let session = session, session.state.isReady else { return }
        Task {
            do {
                _ = try await session.request("call.capabilities")
            } catch {
                DiagnosticsLog.shared.log(
                    "could not read the phone's capabilities: \(error.localizedDescription)",
                    level: .warning
                )
            }
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .deviceInfo(let info):
            deviceInfo = info
            settings.pairedDeviceName = info.deviceName
        case .callCapabilities(let capabilities):
            callCapabilities = capabilities
            peerCapabilities = Capabilities.parse(capabilities.capabilityNames)
        case .callState(let callId, let state, let number, let displayName, let startedAt, let durationMs):
            handleCallState(callId: callId, state: state, number: number, displayName: displayName, startedAt: startedAt, durationMs: durationMs)
        case .callEnded(let callId, let reason, let durationMs):
            if activeCall?.id == callId {
                activeCall = nil
            }
            notifications.postCallEnded(reason: reason)
        case .contactsBatch(_, let index, let total, let contacts, let hasMore):
            let merged = index == 0 ? contacts : self.contacts + contacts
            self.contacts = merged.sorted { $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending }
            contactSyncProgress = total > 0 ? Double(index + 1) / Double(total) : 0
            contactSyncMessage = "Received \(index + 1) of \(total) batches"
            store.save(self.contacts)
            if !hasMore {
                finishSync()
            }
        case .contactsComplete(_, let total):
            contactSyncMessage = "Synced \(self.contacts.count) contacts"
            finishSync()
        case .contactsError(_, let code, let message):
            contactSyncProgress = nil
            contactSyncMessage = ""
            lastError = message
            if code == "permission_denied" {
                settings.contactSyncEnabled = false
            }
        case .recentsBatch(_, let index, let total, let calls):
            let merged = index == 0 ? calls : self.recentCalls + calls
            self.recentCalls = merged.sorted { $0.timestamp > $1.timestamp }
            contactSyncProgress = total > 0 ? Double(index + 1) / Double(total) : 0
        case .recentsComplete:
            contactSyncProgress = nil
        case .recentsError(_, let code, let message):
            contactSyncProgress = nil
            if code == "permission_denied" {
                lastError = "The phone has not granted the call-log permission, so recent calls are unavailable."
            } else {
                lastError = message
            }
        case .favoriteResult(let contactId, let favorite, _, _):
            if let index = contacts.firstIndex(where: { $0.id == contactId }) {
                contacts[index].starred = favorite
                store.save(contacts)
            }
        case .sessionError(_, let message):
            lastError = message
        case .error(_, let message, _):
            lastError = message
        case .logBatch:
            break
        }
    }

    private func finishSync() {
        contactSyncProgress = nil
        lastSyncDate = Date()
        settings.lastSyncWatermark = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        store.save(contacts)
    }

    private func handleCallState(
        callId: String,
        state: CallState,
        number: String?,
        displayName: String?,
        startedAt: Int64?,
        durationMs: Int64?
    ) {
        switch state {
        case .ringingIncoming:
            incomingCall = IncomingCall(
                id: callId,
                number: number,
                displayName: displayName,
                receivedAt: Date()
            )
            notifications.postIncomingCall(
                caller: displayName ?? number ?? "Unknown caller",
                number: number,
                callId: callId
            )
        case .active:
            if incomingCall?.id == callId {
                incomingCall = nil
            }
            activeCall = ActiveCall(
                id: callId,
                number: number,
                displayName: displayName,
                state: state,
                startedAt: startedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                durationMilliseconds: durationMs ?? 0
            )
        case .dialing, .ringingOutgoing, .ending:
            if activeCall == nil {
                activeCall = ActiveCall(
                    id: callId,
                    number: number,
                    displayName: displayName,
                    state: state,
                    startedAt: nil,
                    durationMilliseconds: durationMs ?? 0
                )
            } else {
                activeCall?.state = state
                activeCall?.durationMilliseconds = durationMs ?? activeCall?.durationMilliseconds ?? 0
            }
        case .ended, .failed, .rejected, .missed:
            if activeCall?.id == callId { activeCall = nil }
            if incomingCall?.id == callId { incomingCall = nil }
        case .unknown:
            break
        }
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        DiagnosticsLog.shared.log(message, level: .error)
    }

    /// Delete the local copy of the contacts.
    public func clearLocalContacts() {
        contacts = []
        store.clear()
        DiagnosticsLog.shared.log("Local contact data deleted")
    }

    /// Clear the last error banner.
    public func clearError() {
        lastError = nil
    }

    /// The exportable diagnostic log.
    public func exportLog() -> String {
        var text = DiagnosticsLog.shared.export()
        if let session = session {
            text += "\n\n--- session log ---\n" + session.exportLog()
        }
        return text
    }
}
