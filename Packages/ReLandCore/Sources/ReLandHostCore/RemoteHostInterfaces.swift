import CoreGraphics
import Foundation
import ReLandCore

public protocol RemoteFrameSource: Sendable {
    var displayInformation: DisplayInformation { get }

    func start(
        frameHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: @escaping @Sendable (Error) -> Void
    )

    func stop()
}

public protocol RemoteInputSink: Sendable {
    func handle(_ event: RemoteInputEvent) -> String
}

public enum RemoteCaptureTargetSourceError:
    LocalizedError,
    Equatable,
    Sendable
{
    case message(String)

    public var errorDescription: String? {
        switch self {
        case let .message(message):
            message
        }
    }
}

public protocol RemoteCaptureTargetSource:
    RemoteFrameSource,
    Sendable
{
    func listCaptureTargets(
        completion: @escaping @Sendable (
            Result<
                RemoteCaptureTargetListResponse,
                RemoteCaptureTargetSourceError
            >
        ) -> Void
    )
    func selectCaptureTarget(
        id: String,
        completion: @escaping @Sendable (
            Result<
                RemoteCaptureTargetSelected,
                RemoteCaptureTargetSourceError
            >
        ) -> Void
    )
    func currentInputBounds() -> CGRect?
    func focusSelectedTarget()
}

public struct RemoteHostConfiguration: Sendable {
    public let hostID: String
    public let hostName: String
    public let port: UInt16
    public let credentials: [PSKCredential]
    public let hostPlatform: RemoteHostPlatform

    public init(
        hostID: String,
        hostName: String,
        port: UInt16 = ReLandConstants.defaultPort,
        credentials: [PSKCredential],
        hostPlatform: RemoteHostPlatform = .macOS
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.port = port
        self.credentials = credentials
        self.hostPlatform = hostPlatform
    }
}
