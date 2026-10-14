import Foundation

public struct ProtocolVersionRange:
    Codable,
    Equatable,
    Sendable
{
    public static let current = ProtocolVersionRange(
        minimum: ReLandConstants.minimumSupportedProtocolVersion,
        maximum: ReLandConstants.maximumSupportedProtocolVersion
    )

    public let minimum: UInt16
    public let maximum: UInt16

    public init(minimum: UInt16, maximum: UInt16) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func contains(_ version: UInt16) -> Bool {
        minimum <= maximum
            && (minimum...maximum).contains(version)
    }

    public func highestCommonVersion(
        with other: ProtocolVersionRange
    ) -> UInt16? {
        let lowerBound = max(minimum, other.minimum)
        let upperBound = min(maximum, other.maximum)
        return lowerBound <= upperBound ? upperBound : nil
    }
}

public enum RemoteHostPlatform: String, Codable, Sendable {
    case macOS
    case windows

    public var displayName: String {
        switch self {
        case .macOS:
            "Mac"
        case .windows:
            "Windows PC"
        }
    }
}

public enum RemoteCapability:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case screen
    case input
    case terminal
    case artifacts
    case files
    case captureTargets
    case hostStatus
}

public struct AuthenticationChallenge: Codable, Equatable, Sendable {
    public let nonce: Data
    public let supportedVersions: ProtocolVersionRange
    public let capabilities: Set<RemoteCapability>

    public init(
        nonce: Data,
        supportedVersions: ProtocolVersionRange = .current,
        capabilities: Set<RemoteCapability> = Set(
            RemoteCapability.allCases
        )
    ) {
        self.nonce = nonce
        self.supportedVersions = supportedVersions
        self.capabilities = capabilities
    }
}

public struct AuthenticationResponse: Codable, Equatable, Sendable {
    public let credentialID: String
    public let authenticationCode: Data
    public let protocolVersion: UInt16
    public let capabilities: Set<RemoteCapability>
    public let requestsControllerTakeover: Bool

    public init(
        credentialID: String,
        authenticationCode: Data,
        protocolVersion: UInt16,
        capabilities: Set<RemoteCapability>,
        requestsControllerTakeover: Bool = false
    ) {
        self.credentialID = credentialID
        self.authenticationCode = authenticationCode
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.requestsControllerTakeover =
            requestsControllerTakeover
    }
}

public struct PairDeviceRequest: Codable, Equatable, Sendable {
    public let deviceCredential: PSKCredential

    public init(deviceCredential: PSKCredential) {
        self.deviceCredential = deviceCredential
    }
}

public struct PairDeviceAccepted: Codable, Equatable, Sendable {
    public let hostID: String
    public let hostName: String
    public let hostPlatform: RemoteHostPlatform
    public let capabilities: Set<RemoteCapability>?

    public init(
        hostID: String,
        hostName: String,
        hostPlatform: RemoteHostPlatform = .macOS,
        capabilities: Set<RemoteCapability>? = nil
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.hostPlatform = hostPlatform
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case hostID, hostName, hostPlatform, capabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(String.self, forKey: .hostID)
        hostName = try container.decode(String.self, forKey: .hostName)
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

public struct SessionReady: Codable, Equatable, Sendable {
    public let sessionID: String
    public let protocolVersion: UInt16
    public let capabilities: Set<RemoteCapability>
    public let hostPermissions: HostPermissionState
    public let hostPlatform: RemoteHostPlatform

    public init(
        sessionID: String,
        protocolVersion: UInt16,
        capabilities: Set<RemoteCapability>,
        hostPermissions: HostPermissionState = .granted,
        hostPlatform: RemoteHostPlatform = .macOS
    ) {
        self.sessionID = sessionID
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.hostPermissions = hostPermissions
        self.hostPlatform = hostPlatform
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, protocolVersion, capabilities
        case hostPermissions, hostPlatform
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        protocolVersion = try container.decode(UInt16.self, forKey: .protocolVersion)
        capabilities = try container.decode(Set<RemoteCapability>.self, forKey: .capabilities)
        hostPermissions = try container.decode(HostPermissionState.self, forKey: .hostPermissions)
        hostPlatform = try container.decodeIfPresent(
            RemoteHostPlatform.self,
            forKey: .hostPlatform
        ) ?? .macOS
    }
}

public struct HostPermissionState:
    Codable,
    Equatable,
    Sendable
{
    public static let granted = HostPermissionState(
        screenRecordingGranted: true,
        accessibilityGranted: true,
        sessionUnlocked: true
    )

    public let screenRecordingGranted: Bool
    public let accessibilityGranted: Bool
    public let sessionUnlocked: Bool

    public init(
        screenRecordingGranted: Bool,
        accessibilityGranted: Bool,
        sessionUnlocked: Bool
    ) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
        self.sessionUnlocked = sessionUnlocked
    }
}

public struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let hostID: String
    public var name: String
    public var address: String
    public var port: UInt16
    public let credentialID: String
    public var hostPlatform: RemoteHostPlatform
    public var capabilities: Set<RemoteCapability>?

    public init(
        id: String = UUID().uuidString.lowercased(),
        hostID: String,
        name: String,
        address: String,
        port: UInt16,
        credentialID: String,
        hostPlatform: RemoteHostPlatform = .macOS,
        capabilities: Set<RemoteCapability>? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.address = address
        self.port = port
        self.credentialID = credentialID
        self.hostPlatform = hostPlatform
        self.capabilities = capabilities
    }

    public func supports(_ capability: RemoteCapability) -> Bool {
        if let capabilities {
            return capabilities.contains(capability)
        }
        if hostPlatform == .windows {
            let desktopCapabilities: Set<RemoteCapability> = [
                .screen, .input, .hostStatus,
            ]
            return desktopCapabilities.contains(capability)
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, hostID, name, address, port, credentialID
        case hostPlatform, capabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        hostID = try container.decode(String.self, forKey: .hostID)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(UInt16.self, forKey: .port)
        credentialID = try container.decode(String.self, forKey: .credentialID)
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

public struct DisplayInformation: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let encoding: String

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        encoding: String = "jpeg"
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.encoding = encoding
    }
}

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
}

public enum RemoteInputEvent: Codable, Equatable, Sendable {
    case pointerDelta(x: Double, y: Double)
    case pointerAbsolute(x: Double, y: Double)
    case button(button: MouseButton, isDown: Bool, clickCount: Int)
    case scroll(x: Double, y: Double)
    case text(String)
    case key(code: UInt16, isDown: Bool, modifiers: UInt64)
}

public struct InputAcknowledgement: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let summary: String

    public init(sequence: UInt64, summary: String) {
        self.sequence = sequence
        self.summary = summary
    }
}

public enum RemoteErrorCode: String, Codable, Sendable {
    case authenticationRequired
    case authenticationFailed
    case pairingRequestRequired
    case invalidPairingRequest
    case pairingCredentialConsumed
    case invalidConfiguration
    case protocolMismatch
    case terminalUnavailable
    case terminalInputTooLarge
    case fileServiceUnavailable
    case captureTargetsUnavailable
    case hostBusy
    case sessionExpired
    case sessionTakenOver
    case internalError
}

public struct RemoteErrorMessage: Codable, Equatable, Sendable {
    public let code: RemoteErrorCode
    public let message: String
    public let isRecoverable: Bool
    public let requestKind: WireMessageKind?
    public let requestID: UUID?

    public init(
        code: RemoteErrorCode,
        message: String,
        isRecoverable: Bool = false,
        requestKind: WireMessageKind? = nil,
        requestID: UUID? = nil
    ) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
        self.requestKind = requestKind
        self.requestID = requestID
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case isRecoverable
        case requestKind
        case requestID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(RemoteErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        isRecoverable =
            try container.decodeIfPresent(
                Bool.self,
                forKey: .isRecoverable
            ) ?? false
        requestKind = try container.decodeIfPresent(
            WireMessageKind.self,
            forKey: .requestKind
        )
        requestID = try container.decodeIfPresent(
            UUID.self,
            forKey: .requestID
        )
    }
}

public struct TerminalSessionInfo:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let name: String
    public let windowCount: Int
    public let attachedClientCount: Int
    public let createdAt: Date?

    public init(
        id: String,
        name: String,
        windowCount: Int,
        attachedClientCount: Int,
        createdAt: Date?
    ) {
        self.id = id
        self.name = name
        self.windowCount = windowCount
        self.attachedClientCount = attachedClientCount
        self.createdAt = createdAt
    }
}

public struct TerminalSessionList: Codable, Equatable, Sendable {
    public let sessions: [TerminalSessionInfo]
    public let createdSessionID: String?
    public let createdRequestID: UUID?

    public init(
        sessions: [TerminalSessionInfo],
        createdSessionID: String? = nil,
        createdRequestID: UUID? = nil
    ) {
        self.sessions = sessions
        self.createdSessionID = createdSessionID
        self.createdRequestID = createdRequestID
    }
}

public enum TerminalCreationMatch: Equatable, Sendable {
    case pending
    case created(TerminalSessionInfo)
    case ambiguous
    case invalidResponse
}

public extension TerminalSessionList {
    func creationMatch(
        requestID: UUID,
        existingSessionIDs: Set<String>,
        allowsLegacyFallback: Bool = true
    ) -> TerminalCreationMatch {
        if let createdRequestID {
            guard createdRequestID == requestID else {
                return .pending
            }
            guard
                let createdSessionID,
                let session = sessions.first(where: {
                    $0.id == createdSessionID
                })
            else {
                return .invalidResponse
            }
            return .created(session)
        }

        guard createdSessionID == nil else {
            return .invalidResponse
        }
        guard allowsLegacyFallback else {
            return .pending
        }
        let additions = sessions.filter {
            !existingSessionIDs.contains($0.id)
        }
        switch additions.count {
        case 0:
            return .pending
        case 1:
            return .created(additions[0])
        default:
            return .ambiguous
        }
    }
}

public enum TerminalLaunchProfile:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Sendable
{
    case shell
    case copilot
    case claude
    case codex
    case gemini
}

public struct AILaunchProfile:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: UUID
    public var name: String
    public let tool: TerminalLaunchProfile
    public var additionalArguments: String
    public var bypassPermissions: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        tool: TerminalLaunchProfile,
        additionalArguments: String,
        bypassPermissions: Bool
    ) {
        self.id = id
        self.name = name
        self.tool = tool
        self.additionalArguments = additionalArguments
        self.bypassPermissions = bypassPermissions
    }

    public var isRisky: Bool {
        bypassPermissions
    }
}

public struct TerminalCreateRequest: Codable, Equatable, Sendable {
    public let requestID: UUID?
    public let preferredName: String?
    public let launchProfile: TerminalLaunchProfile
    public let launchArguments: [String]
    public let workingDirectoryPath: String?

    public init(
        requestID: UUID? = nil,
        preferredName: String? = nil,
        launchProfile: TerminalLaunchProfile = .shell,
        launchArguments: [String] = [],
        workingDirectoryPath: String? = nil
    ) {
        self.requestID = requestID
        self.preferredName = preferredName
        self.launchProfile = launchProfile
        self.launchArguments = launchArguments
        self.workingDirectoryPath = workingDirectoryPath
    }
}

public struct TerminalAttachRequest: Codable, Equatable, Sendable {
    public let sessionID: String
    public let columns: Int
    public let rows: Int

    public init(sessionID: String, columns: Int, rows: Int) {
        self.sessionID = sessionID
        self.columns = columns
        self.rows = rows
    }
}

public struct TerminalAttached: Codable, Equatable, Sendable {
    public let sessionID: String
    public let attachmentID: UUID

    public init(sessionID: String, attachmentID: UUID) {
        self.sessionID = sessionID
        self.attachmentID = attachmentID
    }
}

public struct TerminalOutputChunk: Codable, Equatable, Sendable {
    public let sessionID: String
    public let attachmentID: UUID
    public let data: Data

    public init(
        sessionID: String,
        attachmentID: UUID,
        data: Data
    ) {
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.data = data
    }
}

public struct TerminalResizeRequest: Codable, Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public struct TerminalSessionRequest: Codable, Equatable, Sendable {
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

public struct TerminalRenameRequest: Codable, Equatable, Sendable {
    public let sessionID: String
    public let name: String

    public init(sessionID: String, name: String) {
        self.sessionID = sessionID
        self.name = name
    }
}

public enum TerminalArtifactKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case image
    case video
    case text
    case other
}

public struct TerminalArtifactInfo:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let sessionID: String
    public let name: String
    public let contentType: String
    public let kind: TerminalArtifactKind
    public let byteCount: Int64
    public let modifiedAt: Date

    public init(
        id: String,
        sessionID: String,
        name: String,
        contentType: String,
        kind: TerminalArtifactKind,
        byteCount: Int64,
        modifiedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.contentType = contentType
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct TerminalArtifactListRequest:
    Codable,
    Equatable,
    Sendable
{
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

public struct TerminalArtifactListResponse:
    Codable,
    Equatable,
    Sendable
{
    public let sessionID: String
    public let artifacts: [TerminalArtifactInfo]

    public init(
        sessionID: String,
        artifacts: [TerminalArtifactInfo]
    ) {
        self.sessionID = sessionID
        self.artifacts = artifacts
    }
}

public struct TerminalArtifactReadRequest:
    Codable,
    Equatable,
    Sendable
{
    public let sessionID: String
    public let artifactID: String
    public let offset: Int64
    public let length: Int

    public init(
        sessionID: String,
        artifactID: String,
        offset: Int64,
        length: Int = ReLandConstants.artifactChunkSize
    ) {
        self.sessionID = sessionID
        self.artifactID = artifactID
        self.offset = offset
        self.length = length
    }
}

public struct TerminalArtifactChunk:
    Codable,
    Equatable,
    Sendable
{
    public let sessionID: String
    public let artifactID: String
    public let offset: Int64
    public let totalByteCount: Int64
    public let data: Data
    public let isComplete: Bool

    public init(
        sessionID: String,
        artifactID: String,
        offset: Int64,
        totalByteCount: Int64,
        data: Data,
        isComplete: Bool
    ) {
        self.sessionID = sessionID
        self.artifactID = artifactID
        self.offset = offset
        self.totalByteCount = totalByteCount
        self.data = data
        self.isComplete = isComplete
    }
}

public enum RemoteFileKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case directory
    case image
    case video
    case text
    case other
}

public struct RemoteFileEntry:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let path: String
    public let name: String
    public let contentType: String
    public let kind: RemoteFileKind
    public let byteCount: Int64?
    public let modifiedAt: Date

    public init(
        path: String,
        name: String,
        contentType: String,
        kind: RemoteFileKind,
        byteCount: Int64?,
        modifiedAt: Date
    ) {
        id = path
        self.path = path
        self.name = name
        self.contentType = contentType
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct RemoteFileListRequest:
    Codable,
    Equatable,
    Sendable
{
    public let path: String

    public init(path: String = "") {
        self.path = path
    }
}

public struct RemoteFileListResponse:
    Codable,
    Equatable,
    Sendable
{
    public let path: String
    public let parentPath: String?
    public let entries: [RemoteFileEntry]

    public init(
        path: String,
        parentPath: String?,
        entries: [RemoteFileEntry]
    ) {
        self.path = path
        self.parentPath = parentPath
        self.entries = entries
    }
}

public struct RemoteFileReadRequest:
    Codable,
    Equatable,
    Sendable
{
    public let path: String
    public let offset: Int64
    public let length: Int

    public init(
        path: String,
        offset: Int64,
        length: Int = ReLandConstants.artifactChunkSize
    ) {
        self.path = path
        self.offset = offset
        self.length = length
    }
}

public struct RemoteFileChunk:
    Codable,
    Equatable,
    Sendable
{
    public let path: String
    public let offset: Int64
    public let totalByteCount: Int64
    public let data: Data
    public let isComplete: Bool

    public init(
        path: String,
        offset: Int64,
        totalByteCount: Int64,
        data: Data,
        isComplete: Bool
    ) {
        self.path = path
        self.offset = offset
        self.totalByteCount = totalByteCount
        self.data = data
        self.isComplete = isComplete
    }
}

public enum RemoteCaptureTargetKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case display
    case window
}

public struct RemoteCaptureTargetInfo:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let kind: RemoteCaptureTargetKind
    public let applicationName: String
    public let title: String
    public let width: Int
    public let height: Int

    public init(
        id: String,
        kind: RemoteCaptureTargetKind,
        applicationName: String,
        title: String,
        width: Int,
        height: Int
    ) {
        self.id = id
        self.kind = kind
        self.applicationName = applicationName
        self.title = title
        self.width = width
        self.height = height
    }
}

public struct RemoteCaptureTargetListResponse:
    Codable,
    Equatable,
    Sendable
{
    public let targets: [RemoteCaptureTargetInfo]
    public let selectedTargetID: String

    public init(
        targets: [RemoteCaptureTargetInfo],
        selectedTargetID: String
    ) {
        self.targets = targets
        self.selectedTargetID = selectedTargetID
    }
}

public struct RemoteCaptureTargetSelectRequest:
    Codable,
    Equatable,
    Sendable
{
    public let targetID: String

    public init(targetID: String) {
        self.targetID = targetID
    }
}

public struct RemoteCaptureTargetSelected:
    Codable,
    Equatable,
    Sendable
{
    public let target: RemoteCaptureTargetInfo
    public let displayInformation: DisplayInformation

    public init(
        target: RemoteCaptureTargetInfo,
        displayInformation: DisplayInformation
    ) {
        self.target = target
        self.displayInformation = displayInformation
    }
}
