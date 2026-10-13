import Foundation
import Network

public final class RemoteClientSession: @unchecked Sendable {
    public enum Mode: Sendable {
        case connect
        case pair(newDeviceCredential: PSKCredential)
    }

    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case authenticating
        case pairing
        case connected
        case waiting(String)
        case failed(String)
        case disconnected
    }

    public enum RequestError: LocalizedError, Equatable, Sendable {
        case notConnected
        case encodingFailed
        case transportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                "Reconnect to the Mac before creating a terminal."
            case .encodingFailed:
                "The terminal request could not be prepared."
            case let .transportFailed(message):
                message.isEmpty
                    ? "The terminal request could not be sent."
                    : message
            }
        }
    }

    public var onStateChange: (@Sendable (State) -> Void)?
    public var onDisplayInformation: (@Sendable (DisplayInformation) -> Void)?
    public var onFrame: (@Sendable (Data) -> Void)?
    public var onInputAcknowledgement:
        (@Sendable (InputAcknowledgement) -> Void)?
    public var onPaired:
        (@Sendable (PairDeviceAccepted, PSKCredential) -> Void)?
    public var onTerminalSessions:
        (@Sendable ([TerminalSessionInfo]) -> Void)?
    public var onTerminalSessionList:
        (@Sendable (TerminalSessionList) -> Void)?
    public var onTerminalAttached:
        (@Sendable (TerminalAttached) -> Void)?
    public var onTerminalOutput: (@Sendable (Data) -> Void)?
    public var onTerminalDetached: (@Sendable () -> Void)?
    public var onTerminalArtifacts:
        (@Sendable (TerminalArtifactListResponse) -> Void)?
    public var onTerminalArtifactChunk:
        (@Sendable (TerminalArtifactChunk) -> Void)?
    public var onFiles:
        (@Sendable (RemoteFileListResponse) -> Void)?
    public var onFileChunk:
        (@Sendable (RemoteFileChunk) -> Void)?
    public var onCaptureTargets:
        (@Sendable (RemoteCaptureTargetListResponse) -> Void)?
    public var onCaptureTargetSelected:
        (@Sendable (RemoteCaptureTargetSelected) -> Void)?
    public var onSessionReady: (@Sendable (SessionReady) -> Void)?
    public var onRemoteError:
        (@Sendable (RemoteErrorMessage) -> Void)?
    public var onHostPermissionState:
        (@Sendable (HostPermissionState) -> Void)?

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let credential: PSKCredential
    private let mode: Mode
    private let requestsControllerTakeover: Bool
    private let queue = DispatchQueue(
        label: "com.landai.reland.client-session"
    )
    private var connection: FramedConnection?
    private var state: State = .idle
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastPongAt = Date()
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var activeTerminalAttachmentID: UUID?
    private var activeTerminalSessionID: String?
    private var negotiatedProtocolVersion: UInt16?
    private var negotiatedCapabilities: Set<RemoteCapability> = []

    public init(
        address: String,
        port: UInt16,
        credential: PSKCredential,
        mode: Mode = .connect,
        requestsControllerTakeover: Bool = false
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw POSIXError(.EINVAL)
        }
        host = NWEndpoint.Host(address)
        self.port = endpointPort
        self.credential = credential
        self.mode = mode
        self.requestsControllerTakeover =
            requestsControllerTakeover
    }

    deinit {
        connectionTimeoutWorkItem?.cancel()
        heartbeatTimer?.cancel()
        connection?.cancel()
    }

    public func connect() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            connection?.cancel()
            stopHeartbeat()
            startConnectionTimeout()
            negotiatedProtocolVersion = nil
            negotiatedCapabilities = []
            transition(to: .connecting)

            let networkConnection = NWConnection(
                host: host,
                port: port,
                using: TLSPSK.clientParameters(credential: credential)
            )
            let framed = FramedConnection(
                connection: networkConnection,
                queue: queue
            )
            connection = framed
            framed.onStateChange = { [weak self] networkState in
                self?.handle(networkState)
            }
            framed.onPacket = { [weak self] packet in
                self?.handle(packet)
            }
            framed.start()
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.activeTerminalAttachmentID = nil
            self?.activeTerminalSessionID = nil
            self?.negotiatedProtocolVersion = nil
            self?.negotiatedCapabilities = []
            self?.stopHeartbeat()
            self?.stopConnectionTimeout()
            self?.transition(to: .disconnected)
        }
    }

    public func send(input: RemoteInputEvent) {
        queue.async { [weak self] in
            guard
                let self,
                state == .connected,
                let payload = try? WireJSON.encode(input)
            else {
                return
            }
            connection?.send(WirePacket(kind: .input, payload: payload))
        }
    }

    public func requestTerminalSessions() {
        sendConnected(WirePacket(kind: .terminalListRequest))
    }

    public func createTerminalSession(
        requestID: UUID = UUID(),
        preferredName: String? = nil,
        launchProfile: TerminalLaunchProfile = .shell,
        launchArguments: [String] = [],
        workingDirectoryPath: String? = nil,
        completion:
            @escaping @Sendable (Result<Void, RequestError>) -> Void = {
                _ in
            }
    ) {
        sendJSON(
            TerminalCreateRequest(
                requestID: requestID,
                preferredName: preferredName,
                launchProfile: launchProfile,
                launchArguments: launchArguments,
                workingDirectoryPath: workingDirectoryPath
            ),
            kind: .terminalCreateRequest,
            completion: completion
        )
    }

    public func requestTerminalArtifacts(sessionID: String) {
        sendJSON(
            TerminalArtifactListRequest(sessionID: sessionID),
            kind: .terminalArtifactListRequest
        )
    }

    public func requestTerminalArtifactChunk(
        sessionID: String,
        artifactID: String,
        offset: Int64,
        length: Int = ReLandConstants.artifactChunkSize
    ) {
        sendJSON(
            TerminalArtifactReadRequest(
                sessionID: sessionID,
                artifactID: artifactID,
                offset: offset,
                length: length
            ),
            kind: .terminalArtifactReadRequest
        )
    }

    public func requestFiles(path: String = "") {
        sendJSON(
            RemoteFileListRequest(path: path),
            kind: .fileListRequest
        )
    }

    public func requestFileChunk(
        path: String,
        offset: Int64,
        length: Int = ReLandConstants.artifactChunkSize
    ) {
        sendJSON(
            RemoteFileReadRequest(
                path: path,
                offset: offset,
                length: length
            ),
            kind: .fileReadRequest
        )
    }

    public func requestCaptureTargets() {
        sendConnected(
            WirePacket(kind: .captureTargetListRequest)
        )
    }

    public func requestHostStatus() {
        sendConnected(
            WirePacket(kind: .hostStatusRequest)
        )
    }

    public func selectCaptureTarget(id: String) {
        sendJSON(
            RemoteCaptureTargetSelectRequest(targetID: id),
            kind: .captureTargetSelectRequest
        )
    }

    public func attachTerminal(
        sessionID: String,
        columns: Int,
        rows: Int
    ) {
        queue.async { [weak self] in
            guard
                let self,
                state == .connected,
                let payload = try? WireJSON.encode(
                    TerminalAttachRequest(
                        sessionID: sessionID,
                        columns: columns,
                        rows: rows
                    )
                )
            else {
                return
            }
            activeTerminalAttachmentID = nil
            activeTerminalSessionID = nil
            connection?.send(
                WirePacket(
                    kind: .terminalAttachRequest,
                    payload: payload
                )
            )
        }
    }

    public func sendTerminalInput(_ data: Data) {
        sendConnected(
            WirePacket(kind: .terminalInput, payload: data)
        )
    }

    public func resizeTerminal(columns: Int, rows: Int) {
        sendJSON(
            TerminalResizeRequest(columns: columns, rows: rows),
            kind: .terminalResize
        )
    }

    public func detachTerminal() {
        queue.async { [weak self] in
            guard let self, state == .connected else {
                return
            }
            activeTerminalAttachmentID = nil
            activeTerminalSessionID = nil
            connection?.send(WirePacket(kind: .terminalDetach))
        }
    }

    public func openTerminalOnMac(sessionID: String) {
        sendJSON(
            TerminalSessionRequest(sessionID: sessionID),
            kind: .terminalOpenOnMac
        )
    }

    public func renameTerminalSession(
        sessionID: String,
        name: String
    ) {
        sendJSON(
            TerminalRenameRequest(
                sessionID: sessionID,
                name: name
            ),
            kind: .terminalRename
        )
    }

    public func killTerminalSession(sessionID: String) {
        sendJSON(
            TerminalSessionRequest(sessionID: sessionID),
            kind: .terminalKill
        )
    }

    private func handle(_ networkState: FramedConnection.State) {
        switch networkState {
        case .ready:
            transition(to: .authenticating)
        case let .waiting(message):
            transition(to: .waiting(message))
        case let .failed(message):
            stopConnectionTimeout()
            transition(to: .failed(message))
        case .cancelled:
            stopHeartbeat()
            stopConnectionTimeout()
            if case .failed = state {
                break
            } else {
                transition(to: .disconnected)
            }
        case .setup, .preparing:
            break
        }
    }

    private func handle(_ packet: WirePacket) {
        do {
            switch packet.kind {
            case .challenge:
                let challenge = try WireJSON.decode(
                    AuthenticationChallenge.self,
                    from: packet.payload
                )
                guard
                    let protocolVersion =
                        ProtocolVersionRange.current
                            .highestCommonVersion(
                                with: challenge.supportedVersions
                            )
                else {
                    transition(to: .failed("Protocol version mismatch"))
                    disconnect()
                    return
                }
                let capabilities = challenge.capabilities.intersection(
                    Set(RemoteCapability.allCases)
                )
                negotiatedProtocolVersion = protocolVersion
                negotiatedCapabilities = capabilities
                let response = AuthenticationResponse(
                    credentialID: credential.id,
                    authenticationCode: credential.authenticationCode(
                        for: challenge.nonce
                    ),
                    protocolVersion: protocolVersion,
                    capabilities: capabilities,
                    requestsControllerTakeover:
                        requestsControllerTakeover
                )
                connection?.send(
                    WirePacket(
                        kind: .authenticate,
                        payload: try WireJSON.encode(response)
                    )
                )

                if case let .pair(newDeviceCredential) = mode {
                    transition(to: .pairing)
                    let request = PairDeviceRequest(
                        deviceCredential: newDeviceCredential
                    )
                    connection?.send(
                        WirePacket(
                            kind: .pairRequest,
                            payload: try WireJSON.encode(request)
                        )
                    )
                }

            case .pairAccepted:
                guard case let .pair(newDeviceCredential) = mode else {
                    return
                }
                let accepted = try WireJSON.decode(
                    PairDeviceAccepted.self,
                    from: packet.payload
                )
                stopConnectionTimeout()
                onPaired?(accepted, newDeviceCredential)
                disconnect()

            case .sessionReady:
                let ready = try WireJSON.decode(
                    SessionReady.self,
                    from: packet.payload
                )
                guard
                    ready.protocolVersion
                        == negotiatedProtocolVersion,
                    ready.capabilities == negotiatedCapabilities
                else {
                    transition(to: .failed("Protocol negotiation mismatch"))
                    disconnect()
                    return
                }
                stopConnectionTimeout()
                startHeartbeat()
                onHostPermissionState?(ready.hostPermissions)
                onSessionReady?(ready)
                transition(to: .connected)

            case .displayInfo:
                let information = try WireJSON.decode(
                    DisplayInformation.self,
                    from: packet.payload
                )
                onDisplayInformation?(information)

            case .videoFrame:
                onFrame?(packet.payload)

            case .inputAcknowledgement:
                let acknowledgement = try WireJSON.decode(
                    InputAcknowledgement.self,
                    from: packet.payload
                )
                onInputAcknowledgement?(acknowledgement)

            case .terminalListResponse:
                let list = try WireJSON.decode(
                    TerminalSessionList.self,
                    from: packet.payload
                )
                onTerminalSessionList?(list)
                onTerminalSessions?(list.sessions)

            case .terminalAttached:
                let attached = try WireJSON.decode(
                    TerminalAttached.self,
                    from: packet.payload
                )
                activeTerminalAttachmentID = attached.attachmentID
                activeTerminalSessionID = attached.sessionID
                onTerminalAttached?(attached)

            case .terminalOutput:
                let chunk = try WireJSON.decode(
                    TerminalOutputChunk.self,
                    from: packet.payload
                )
                guard
                    chunk.attachmentID == activeTerminalAttachmentID,
                    chunk.sessionID == activeTerminalSessionID
                else {
                    return
                }
                onTerminalOutput?(chunk.data)

            case .terminalDetached:
                activeTerminalAttachmentID = nil
                activeTerminalSessionID = nil
                onTerminalDetached?()

            case .terminalArtifactListResponse:
                let response = try WireJSON.decode(
                    TerminalArtifactListResponse.self,
                    from: packet.payload
                )
                onTerminalArtifacts?(response)

            case .terminalArtifactChunk:
                let chunk = try WireJSON.decode(
                    TerminalArtifactChunk.self,
                    from: packet.payload
                )
                onTerminalArtifactChunk?(chunk)

            case .fileListResponse:
                let response = try WireJSON.decode(
                    RemoteFileListResponse.self,
                    from: packet.payload
                )
                onFiles?(response)

            case .fileChunk:
                let chunk = try WireJSON.decode(
                    RemoteFileChunk.self,
                    from: packet.payload
                )
                onFileChunk?(chunk)

            case .captureTargetListResponse:
                let response = try WireJSON.decode(
                    RemoteCaptureTargetListResponse.self,
                    from: packet.payload
                )
                onCaptureTargets?(response)

            case .captureTargetSelected:
                let selected = try WireJSON.decode(
                    RemoteCaptureTargetSelected.self,
                    from: packet.payload
                )
                onCaptureTargetSelected?(selected)

            case .hostStatusResponse:
                let status = try WireJSON.decode(
                    HostPermissionState.self,
                    from: packet.payload
                )
                onHostPermissionState?(status)

            case .ping:
                connection?.send(WirePacket(kind: .pong))

            case .pong:
                lastPongAt = Date()

            case .error:
                let error = try WireJSON.decode(
                    RemoteErrorMessage.self,
                    from: packet.payload
                )
                onRemoteError?(error)
                if !error.isRecoverable {
                    transition(to: .failed(error.message))
                }

            case .authenticate,
                 .pairRequest,
                 .input,
                 .terminalListRequest,
                 .terminalCreateRequest,
                 .terminalAttachRequest,
                 .terminalInput,
                 .terminalResize,
                 .terminalDetach,
                 .terminalOpenOnMac,
                 .terminalRename,
                 .terminalKill,
                 .terminalArtifactListRequest,
                 .terminalArtifactReadRequest,
                 .fileListRequest,
                 .fileReadRequest,
                 .captureTargetListRequest,
                 .captureTargetSelectRequest,
                 .hostStatusRequest:
                break
            }
        } catch {
            transition(to: .failed(error.localizedDescription))
            disconnect()
        }
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
    }

    private func sendJSON<T: Encodable & Sendable>(
        _ value: T,
        kind: WireMessageKind,
        completion:
            (@Sendable (Result<Void, RequestError>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self, state == .connected, let connection else {
                completion?(.failure(.notConnected))
                return
            }
            let payload: Data
            do {
                payload = try WireJSON.encode(value)
            } catch {
                completion?(.failure(.encodingFailed))
                return
            }
            connection.send(
                WirePacket(kind: kind, payload: payload)
            ) { error in
                if let error {
                    completion?(
                        .failure(
                            .transportFailed(error.localizedDescription)
                        )
                    )
                } else {
                    completion?(.success(()))
                }
            }
        }
    }

    private func sendConnected(_ packet: WirePacket) {
        queue.async { [weak self] in
            guard let self, state == .connected else {
                return
            }
            connection?.send(packet)
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        lastPongAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + 5,
            repeating: 5,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            if Date().timeIntervalSince(lastPongAt) > 15 {
                transition(to: .failed("The computer stopped responding"))
                connection?.cancel()
                return
            }
            connection?.send(WirePacket(kind: .ping))
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func startConnectionTimeout() {
        stopConnectionTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            transition(to: .failed("Connection timed out"))
            connection?.cancel()
        }
        connectionTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 15, execute: workItem)
    }

    private func stopConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
    }
}
