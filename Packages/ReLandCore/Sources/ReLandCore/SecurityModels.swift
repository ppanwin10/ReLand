import CryptoKit
import Foundation

public enum ReLandSecurityError: Error, Equatable {
    case invalidCredential
    case invalidPairingPayload
    case expiredPairingCode
    case untrustedNetworkAddress
    case randomGenerationFailed(OSStatus)
    case keychain(OSStatus)
}

extension ReLandSecurityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "The security credential is invalid."
        case .invalidPairingPayload:
            "This is not a valid ReLand pairing code."
        case .expiredPairingCode:
            "This ReLand pairing code has expired. Create a new one on your computer."
        case .untrustedNetworkAddress:
            "ReLand pairing is limited to private LAN or Tailscale addresses."
        case .randomGenerationFailed:
            "ReLand could not generate secure random data."
        case .keychain:
            "ReLand could not access the system Keychain."
        }
    }
}

public struct PSKCredential: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let key: Data
    public let name: String
    public let isPairingCredential: Bool

    public init(
        id: String,
        key: Data,
        name: String,
        isPairingCredential: Bool = false
    ) throws {
        guard !id.isEmpty, key.count >= 32 else {
            throw ReLandSecurityError.invalidCredential
        }
        self.id = id
        self.key = key
        self.name = name
        self.isPairingCredential = isPairingCredential
    }

    public static func generate(
        name: String,
        isPairingCredential: Bool = false
    ) throws -> PSKCredential {
        try PSKCredential(
            id: UUID().uuidString.lowercased(),
            key: Data.secureRandom(count: 32),
            name: name,
            isPairingCredential: isPairingCredential
        )
    }

    public func authenticationCode(for challenge: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: challenge,
            using: SymmetricKey(data: key)
        )
        return Data(code)
    }

    public func validates(code: Data, challenge: Data) -> Bool {
        let expected = authenticationCode(for: challenge)
        guard expected.count == code.count else {
            return false
        }

        var difference: UInt8 = 0
        for (expectedByte, suppliedByte) in zip(expected, code) {
            difference |= expectedByte ^ suppliedByte
        }
        return difference == 0
    }
}

public struct PairingDescriptor: Codable, Equatable, Sendable {
    private static let payloadPrefix = "reland-pair:v2:"
    private static let payloadVersion = 2
    private static let maximumPayloadLength = 4_096

    public let hostID: String
    public let hostName: String
    public let address: String
    public let port: UInt16
    public let credential: PSKCredential
    public let expiresAt: Date
    public let hostPlatform: RemoteHostPlatform
    public let capabilities: Set<RemoteCapability>?

    public init(
        hostID: String,
        hostName: String,
        address: String,
        port: UInt16,
        credential: PSKCredential,
        expiresAt: Date,
        hostPlatform: RemoteHostPlatform = .macOS,
        capabilities: Set<RemoteCapability>? = nil
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.address = address
        self.port = port
        self.credential = credential
        self.expiresAt = expiresAt
        self.hostPlatform = hostPlatform
        self.capabilities = capabilities
    }

    public func encodedPayload() throws -> String {
        let payload = PairingPayload(
            version: Self.payloadVersion,
            hostID: hostID,
            hostName: hostName,
            address: address,
            port: port,
            credential: credential,
            expiresAt: expiresAt,
            hostPlatform: hostPlatform,
            capabilities: capabilities
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return Self.payloadPrefix + data.base64URLEncodedString
    }

    public init(
        payload: String,
        now: Date = Date()
    ) throws {
        guard
            payload.count <= Self.maximumPayloadLength,
            payload.hasPrefix(Self.payloadPrefix),
            let data = Data(
                base64URLString: String(
                    payload.dropFirst(Self.payloadPrefix.count)
                )
            )
        else {
            throw ReLandSecurityError.invalidPairingPayload
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded: PairingPayload
        do {
            decoded = try decoder.decode(PairingPayload.self, from: data)
        } catch {
            throw ReLandSecurityError.invalidPairingPayload
        }

        guard
            decoded.version == Self.payloadVersion,
            !decoded.hostID.isEmpty,
            !decoded.hostName.isEmpty,
            decoded.port > 0,
            decoded.credential.isPairingCredential
        else {
            throw ReLandSecurityError.invalidPairingPayload
        }
        guard now < decoded.expiresAt else {
            throw ReLandSecurityError.expiredPairingCode
        }
        guard PrivateNetworkPolicy.allows(decoded.address) else {
            throw ReLandSecurityError.untrustedNetworkAddress
        }

        self.init(
            hostID: decoded.hostID,
            hostName: decoded.hostName,
            address: decoded.address,
            port: decoded.port,
            credential: decoded.credential,
            expiresAt: decoded.expiresAt,
            hostPlatform: decoded.hostPlatform,
            capabilities: decoded.capabilities
        )
    }
}

private struct PairingPayload: Codable {
    let version: Int
    let hostID: String
    let hostName: String
    let address: String
    let port: UInt16
    let credential: PSKCredential
    let expiresAt: Date
    let hostPlatform: RemoteHostPlatform
    let capabilities: Set<RemoteCapability>?

    init(
        version: Int,
        hostID: String,
        hostName: String,
        address: String,
        port: UInt16,
        credential: PSKCredential,
        expiresAt: Date,
        hostPlatform: RemoteHostPlatform,
        capabilities: Set<RemoteCapability>?
    ) {
        self.version = version
        self.hostID = hostID
        self.hostName = hostName
        self.address = address
        self.port = port
        self.credential = credential
        self.expiresAt = expiresAt
        self.hostPlatform = hostPlatform
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case version, hostID, hostName, address, port
        case credential, expiresAt, hostPlatform, capabilities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        hostID = try container.decode(String.self, forKey: .hostID)
        hostName = try container.decode(String.self, forKey: .hostName)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(UInt16.self, forKey: .port)
        credential = try container.decode(PSKCredential.self, forKey: .credential)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        hostPlatform = try container.decodeIfPresent(
            RemoteHostPlatform.self,
            forKey: .hostPlatform
        ) ?? .macOS
        capabilities = try container.decodeIfPresent(
            Set<RemoteCapability>.self,
            forKey: .capabilities
        )
    }
}
