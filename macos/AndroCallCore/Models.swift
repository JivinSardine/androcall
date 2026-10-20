import Foundation

/// A phone contact synchronised from the Android device.
public struct Contact: Identifiable, Equatable, Hashable {
    public var id: String
    public var lookupKey: String
    public var displayName: String
    public var givenName: String?
    public var familyName: String?
    public var organization: String?
    public var phoneNumbers: [PhoneNumber]
    public var emails: [EmailAddress]
    public var photo: Data?
    public var photoMimeType: String?
    public var starred: Bool
    public var sortKey: String

    public init(
        id: String,
        lookupKey: String = "",
        displayName: String,
        givenName: String? = nil,
        familyName: String? = nil,
        organization: String? = nil,
        phoneNumbers: [PhoneNumber] = [],
        emails: [EmailAddress] = [],
        photo: Data? = nil,
        photoMimeType: String? = nil,
        starred: Bool = false,
        sortKey: String = ""
    ) {
        self.id = id
        self.lookupKey = lookupKey
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.phoneNumbers = phoneNumbers
        self.emails = emails
        self.photo = photo
        self.photoMimeType = photoMimeType
        self.starred = starred
        self.sortKey = sortKey.isEmpty ? displayName : sortKey
    }

    /// The number to dial when the user picks this contact without choosing one.
    public var preferredPhoneNumber: PhoneNumber? {
        if let mobile = phoneNumbers.first(where: { $0.type == "mobile" }) {
            return mobile
        }
        return phoneNumbers.first
    }

    /// Parse a contact from the wire representation.
    public static func parse(_ value: JSONValue) -> Contact? {
        guard let object = value.objectValue else { return nil }
        guard let id = object["id"]?.stringValue else { return nil }
        let displayName = object["displayName"]?.stringValue ?? ""
        let numbers = (object["phoneNumbers"]?.arrayValue ?? []).compactMap { element -> PhoneNumber? in
            guard let entry = element.objectValue else { return nil }
            guard let number = entry["number"]?.stringValue else { return nil }
            return PhoneNumber(
                label: entry["label"]?.stringValue ?? "",
                number: number,
                normalized: entry["normalized"]?.stringValue ?? number,
                type: entry["type"]?.stringValue ?? ""
            )
        }
        let emails = (object["emails"]?.arrayValue ?? []).compactMap { element -> EmailAddress? in
            guard let entry = element.objectValue else { return nil }
            guard let address = entry["address"]?.stringValue else { return nil }
            return EmailAddress(label: entry["label"]?.stringValue ?? "", address: address)
        }
        var photo: Data?
        if let base64 = object["photo"]?.stringValue, let decoded = Data(base64Encoded: base64) {
            photo = decoded
        }
        return Contact(
            id: id,
            lookupKey: object["lookupKey"]?.stringValue ?? "",
            displayName: displayName,
            givenName: object["givenName"]?.stringValue,
            familyName: object["familyName"]?.stringValue,
            organization: object["organization"]?.stringValue,
            phoneNumbers: numbers,
            emails: emails,
            photo: photo,
            photoMimeType: object["photoMimeType"]?.stringValue,
            starred: object["starred"]?.boolValue ?? false,
            sortKey: object["sortKey"]?.stringValue ?? displayName
        )
    }

    /// The wire representation.
    public var jsonValue: JSONValue {
        .object([
            "id": .string(id),
            "lookupKey": .string(lookupKey),
            "displayName": .string(displayName),
            "givenName": givenName.map { JSONValue.string($0) } ?? .null,
            "familyName": familyName.map { JSONValue.string($0) } ?? .null,
            "organization": organization.map { JSONValue.string($0) } ?? .null,
            "phoneNumbers": .array(phoneNumbers.map(\.jsonValue)),
            "emails": .array(emails.map(\.jsonValue)),
            "photo": photo.map { JSONValue.string($0.base64EncodedString()) } ?? .null,
            "photoMimeType": photoMimeType.map { JSONValue.string($0) } ?? .null,
            "starred": .bool(starred),
            "sortKey": .string(sortKey),
        ])
    }
}

/// One phone number of a contact.
public struct PhoneNumber: Identifiable, Equatable, Hashable {
    public var label: String
    public var number: String
    public var normalized: String
    public var type: String

    public var id: String { normalized + "|" + type }

    public init(label: String, number: String, normalized: String, type: String) {
        self.label = label
        self.number = number
        self.normalized = normalized
        self.type = type
    }

    public var jsonValue: JSONValue {
        .object([
            "label": .string(label),
            "number": .string(number),
            "normalized": .string(normalized),
            "type": .string(type),
        ])
    }
}

/// One email address of a contact.
public struct EmailAddress: Identifiable, Equatable, Hashable {
    public var label: String
    public var address: String

    public var id: String { address + "|" + label }

    public init(label: String, address: String) {
        self.label = label
        self.address = address
    }

    public var jsonValue: JSONValue {
        .object([
            "label": .string(label),
            "address": .string(address),
        ])
    }
}

/// The state of a call as reported by the phone.
public enum CallState: String, Equatable, CaseIterable {
    case dialing
    case ringingOutgoing = "ringing_outgoing"
    case ringingIncoming = "ringing_incoming"
    case active
    case ending
    case ended
    case failed
    case rejected
    case missed
    case unknown

    public var isTerminal: Bool {
        switch self {
        case .ended, .failed, .rejected, .missed: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .dialing: return "Calling"
        case .ringingOutgoing: return "Ringing"
        case .ringingIncoming: return "Incoming call"
        case .active: return "Connected"
        case .ending: return "Ending"
        case .ended: return "Ended"
        case .failed: return "Failed"
        case .rejected: return "Declined"
        case .missed: return "Missed"
        case .unknown: return "Unknown"
        }
    }

    public static func parse(_ raw: String) -> CallState {
        CallState(rawValue: raw) ?? .unknown
    }
}

/// A recent call entry.
public struct RecentCall: Identifiable, Equatable, Hashable {
    public enum Kind: String, Equatable {
        case incoming
        case outgoing
        case missed
        case rejected
        case unknown
    }

    public var id: String
    public var number: String
    public var displayName: String?
    public var kind: Kind
    public var timestamp: Int64
    public var durationMilliseconds: Int64?

    public init(
        id: String,
        number: String,
        displayName: String?,
        kind: Kind,
        timestamp: Int64,
        durationMilliseconds: Int64?
    ) {
        self.id = id
        self.number = number
        self.displayName = displayName
        self.kind = kind
        self.timestamp = timestamp
        self.durationMilliseconds = durationMilliseconds
    }

    public static func parse(_ value: JSONValue) -> RecentCall? {
        guard let object = value.objectValue else { return nil }
        guard let id = object["id"]?.stringValue else { return nil }
        return RecentCall(
            id: id,
            number: object["number"]?.stringValue ?? "",
            displayName: object["displayName"]?.stringValue,
            kind: Kind(rawValue: object["type"]?.stringValue ?? "unknown") ?? .unknown,
            timestamp: object["timestamp"]?.intValue ?? 0,
            durationMilliseconds: object["durationMs"]?.intValue
        )
    }

    public var jsonValue: JSONValue {
        .object([
            "id": .string(id),
            "number": .string(number),
            "displayName": displayName.map { JSONValue.string($0) } ?? .null,
            "type": .string(kind.rawValue),
            "timestamp": .int(timestamp),
            "durationMs": durationMilliseconds.map { JSONValue.int($0) } ?? .null,
        ])
    }
}

/// Information about the connected phone.
public struct DeviceInfo: Equatable {
    public var deviceName: String
    public var manufacturer: String
    public var model: String
    public var androidVersion: String
    public var sdkInt: Int
    public var batteryLevel: Int?
    public var batteryCharging: Bool?
    public var signalStrength: Int?
    public var telephonyCapable: Bool

    public init(
        deviceName: String,
        manufacturer: String = "",
        model: String = "",
        androidVersion: String = "",
        sdkInt: Int = 0,
        batteryLevel: Int? = nil,
        batteryCharging: Bool? = nil,
        signalStrength: Int? = nil,
        telephonyCapable: Bool = true
    ) {
        self.deviceName = deviceName
        self.manufacturer = manufacturer
        self.model = model
        self.androidVersion = androidVersion
        self.sdkInt = sdkInt
        self.batteryLevel = batteryLevel
        self.batteryCharging = batteryCharging
        self.signalStrength = signalStrength
        self.telephonyCapable = telephonyCapable
    }

    public static func parse(_ body: [String: JSONValue]) -> DeviceInfo {
        DeviceInfo(
            deviceName: body["deviceName"]?.stringValue ?? "Android phone",
            manufacturer: body["manufacturer"]?.stringValue ?? "",
            model: body["model"]?.stringValue ?? "",
            androidVersion: body["androidVersion"]?.stringValue ?? "",
            sdkInt: Int(body["sdkInt"]?.intValue ?? 0),
            batteryLevel: body["batteryLevel"]?.intValue.map { Int($0) },
            batteryCharging: body["batteryCharging"]?.boolValue,
            signalStrength: body["signalStrength"]?.intValue.map { Int($0) },
            telephonyCapable: body["telephonyCapable"]?.boolValue ?? true
        )
    }
}

/// The call-control capabilities the phone reports.
public struct CallCapabilities: Equatable {
    public var canAnswer: Bool
    public var canDecline: Bool
    public var canEnd: Bool
    public var canMute: Bool
    public var canSelectAudioDevice: Bool
    public var audioRoute: String?
    public var isDefaultDialer: Bool
    public var reason: String?

    public init(
        canAnswer: Bool = false,
        canDecline: Bool = false,
        canEnd: Bool = false,
        canMute: Bool = false,
        canSelectAudioDevice: Bool = false,
        audioRoute: String? = nil,
        isDefaultDialer: Bool = false,
        reason: String? = nil
    ) {
        self.canAnswer = canAnswer
        self.canDecline = canDecline
        self.canEnd = canEnd
        self.canMute = canMute
        self.canSelectAudioDevice = canSelectAudioDevice
        self.audioRoute = audioRoute
        self.isDefaultDialer = isDefaultDialer
        self.reason = reason
    }

    public static func parse(_ body: [String: JSONValue]) -> CallCapabilities {
        CallCapabilities(
            canAnswer: body["canAnswer"]?.boolValue ?? false,
            canDecline: body["canDecline"]?.boolValue ?? false,
            canEnd: body["canEnd"]?.boolValue ?? false,
            canMute: body["canMute"]?.boolValue ?? false,
            canSelectAudioDevice: body["canSelectAudioDevice"]?.boolValue ?? false,
            audioRoute: body["audioRoute"]?.stringValue,
            isDefaultDialer: body["defaultDialer"]?.boolValue ?? false,
            reason: body["reason"]?.stringValue
        )
    }
}
