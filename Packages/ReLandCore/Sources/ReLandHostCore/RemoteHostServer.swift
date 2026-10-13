import CryptoKit
import Foundation
import ReLandCore
import Network

public final class RemoteHostServer: @unchecked Sendable {
    private enum ListenerTransitionResult: Sendable {
        case success
        case failure(String)
    }

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    public var onStateChange: (@Sendable (State) -> Void)?
    public var onPairingAccepted: (@Sendable (PSKCredential) -> Void)?
    public var onClientCountChange: (@Sendable (Int) -> Void)?
    public var onUserActivity: (@Sendable () -> Void)?

    private final class ClientContext: @unchecked Sendable {
        enum AuthenticationState {
            case waitingForAuthentication(
                challenge: AuthenticationChallenge
            )
            case waitingForPairRequest(credential: PSKCredential)
            case active(credential: PSKCredential)
            case revoked
        }

        let id = UUID()
        let connection: FramedConnection
        var authenticationState: AuthenticationState
        var isSendingFrame = false
        var inputSequence: UInt64 = 0
        var terminalAttachment: (any RemoteTerminalAttachment)?
        var terminalAttachmentID: UUID?
        var negotiatedProtocolVersion: UInt16?
        var negotiatedCapabilities: Set<RemoteCapability> = []
        var lastActivityAt = Date()

        init(
            connection: FramedConnection,
            challenge: AuthenticationChallenge
        ) {
            self.connection = connection
            authenticationState = .waitingForAuthentication(
                challenge: challenge
            )
        }
    }

    private let frameSource: any RemoteFrameSource
    private let inputSink: any RemoteInputSink
    private let terminalService: (any RemoteTerminalService)?
    private let fileService: (any RemoteFileService)?
    private let permissionStateProvider:
        @Sendable () -> HostPermissionState
    private let queue = DispatchQueue(
        label: "com.landai.reland.host-server"
    )
    private var configuration: RemoteHostConfiguration?
    private var credentialsByID: [String: PSKCredential] = [:]
    private var listener: NWListener?
    private var clients: [UUID: ClientContext] = [:]
    private var frameSourceIsRunning = false
    private var listenerGeneration = 0
    private var listenerTransitionInProgress = false
    private var pendingListenerConfiguration: RemoteHostConfiguration?
    private var pendingListenerReadyActions: [
        @Sendable (ListenerTransitionResult) -> Void
    ] = []
    private var consumedPairingCredentialIDs: Set<String> = []
    private var livenessTimer: DispatchSourceTimer?
    private let controllerLeaseDuration: TimeInterval
    private let livenessCheckInterval: TimeInterval

    public init(
        frameSource: any RemoteFrameSource,
        inputSink: any RemoteInputSink,
        terminalService: (any RemoteTerminalService)? = nil,
        fileService: (any RemoteFileService)? = nil,
        controllerLeaseDuration: TimeInterval = 20,
        livenessCheckInterval: TimeInterval = 5,
        permissionStateProvider:
            @escaping @Sendable () -> HostPermissionState = {
                .granted
            }
    ) {
        self.frameSource = frameSource
        self.inputSink = inputSink
        self.terminalService = terminalService
        self.fileService = fileService
        self.permissionStateProvider =
            permissionStateProvider
        self.controllerLeaseDuration = max(
            controllerLeaseDuration,
            0.05
        )
        self.livenessCheckInterval = max(
            livenessCheckInterval,
            0.05
        )
    }

    private var availableCapabilities: Set<RemoteCapability> {
        var capabilities: Set<RemoteCapability> = [
            .screen,
            .input,
        ]
        if terminalService != nil {
            capabilities.formUnion([.terminal, .artifacts])
        }
        if fileService != nil {
            capabilities.insert(.files)
        }
        if frameSource is any RemoteCaptureTargetSource {
            capabilities.insert(.captureTargets)
        }
        capabilities.insert(.hostStatus)
        return capabilities
    }

    public func start(configuration: RemoteHostConfiguration) {
        queue.async { [weak self] in
            self?.startOnQueue(configuration: configuration)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            listenerGeneration += 1
            listenerTransitionInProgress = false
            pendingListenerConfiguration = nil
            pendingListenerReadyActions.removeAll()
            listener?.cancel()
            listener = nil
            stopLivenessTimer()
            for client in clients.values {
                let attachment = client.terminalAttachment
                client.terminalAttachment = nil
                client.terminalAttachmentID = nil
                attachment?.close()
                client.connection.cancel()
            }
            clients.removeAll()
            stopFrameSourceIfNeeded()
            onClientCountChange?(0)
            onStateChange?(.stopped)
        }
    }

    public func disconnectClients() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            for client in clients.values {
                let attachment = client.terminalAttachment
                client.terminalAttachment = nil
                client.terminalAttachmentID = nil
                attachment?.close()
                client.connection.cancel()
            }
        }
    }

    public func replaceCredentials(_ credentials: [PSKCredential]) {
        queue.async { [weak self] in
            guard let self, var configuration else {
                return
            }
            configuration = RemoteHostConfiguration(
                hostID: configuration.hostID,
                hostName: configuration.hostName,
                port: configuration.port,
                credentials: credentials,
                hostPlatform: configuration.hostPlatform
            )
            startOnQueue(configuration: configuration)
        }
    }

    private func startOnQueue(
        configuration: RemoteHostConfiguration,
        completion:
            (@Sendable (ListenerTransitionResult) -> Void)? = nil
    ) {
        credentialsByID = Dictionary(
            uniqueKeysWithValues: configuration.credentials.map {
                ($0.id, $0)
            }
        )
        self.configuration = configuration
        pendingListenerConfiguration = configuration
        if let completion {
            pendingListenerReadyActions.append(completion)
        }

        guard !configuration.credentials.isEmpty else {
            pendingListenerConfiguration = nil
            pendingListenerReadyActions.removeAll()
            onStateChange?(.failed("No host credentials are configured"))
            return
        }

        startLivenessTimer()
        beginListenerTransitionIfNeeded()
    }

    private func beginListenerTransitionIfNeeded() {
        guard
            !listenerTransitionInProgress,
            pendingListenerConfiguration != nil
        else {
            return
        }
        listenerTransitionInProgress = true

        if let activeListener = listener {
            listener = nil
            listenerGeneration += 1
            activeListener.stateUpdateHandler = { [weak self] state in
                guard case .cancelled = state else {
                    return
                }
                self?.createPendingListener()
            }
            activeListener.cancel()
            return
        }

        createPendingListener()
    }

    private func createPendingListener() {
        guard let configuration = pendingListenerConfiguration else {
            listenerTransitionInProgress = false
            return
        }
        pendingListenerConfiguration = nil
        listenerGeneration += 1
        let generation = listenerGeneration

        do {
            onStateChange?(.starting)
            let parameters = try TLSPSK.serverParameters(
                credentials: configuration.credentials
            )
            guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
                throw POSIXError(.EINVAL)
            }
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(
                name: configuration.hostName,
                type: ReLandConstants.serviceType
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(
                    state,
                    generation: generation
                )
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listenerTransitionInProgress = false
            pendingListenerConfiguration = nil
            failPendingListenerActions(with: error.localizedDescription)
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    private func handleListenerState(
        _ state: NWListener.State,
        generation: Int
    ) {
        guard generation == listenerGeneration else {
            return
        }
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                onStateChange?(.ready(port: port))
            }
            if pendingListenerConfiguration != nil {
                listenerTransitionInProgress = false
                beginListenerTransitionIfNeeded()
                return
            }
            listenerTransitionInProgress = false
            let actions = pendingListenerReadyActions
            pendingListenerReadyActions.removeAll()
            for action in actions {
                action(.success)
            }
        case let .failed(error):
            listenerTransitionInProgress = false
            pendingListenerConfiguration = nil
            failPendingListenerActions(with: error.localizedDescription)
            onStateChange?(.failed(error.localizedDescription))
        case .cancelled:
            break
        case .setup, .waiting:
            break
        @unknown default:
            onStateChange?(.failed("Unknown listener state"))
        }
    }

    private func accept(_ networkConnection: NWConnection) {
        guard
            case let .hostPort(host, _) = networkConnection.endpoint,
            PrivateNetworkPolicy.allows(String(describing: host))
        else {
            networkConnection.cancel()
            return
        }

        let challenge: AuthenticationChallenge
        do {
            challenge = AuthenticationChallenge(
                nonce: try Data.secureRandom(count: 32),
                supportedVersions: .current,
                capabilities: availableCapabilities
            )
        } catch {
            networkConnection.cancel()
            return
        }

        let framed = FramedConnection(
            connection: networkConnection,
            queue: queue
        )
        let context = ClientContext(
            connection: framed,
            challenge: challenge
        )
        clients[context.id] = context
        onClientCountChange?(clients.count)

        framed.onStateChange = { [weak self, weak context] state in
            guard let self, let context else {
                return
            }
            switch state {
            case .ready:
                do {
                    let payload = try WireJSON.encode(
                        challenge
                    )
                    framed.send(
                        WirePacket(kind: .challenge, payload: payload)
                    )
                } catch {
                    remove(context)
                }
            case .cancelled, .failed:
                remove(context)
            case .setup, .preparing, .waiting:
                break
            }
        }
        framed.onPacket = { [weak self, weak context] packet in
            guard let self, let context else {
                return
            }
            handle(packet, from: context)
        }
        framed.start()
    }

    private func handle(_ packet: WirePacket, from context: ClientContext) {
        do {
            switch context.authenticationState {
            case let .waitingForAuthentication(challenge):
                guard packet.kind == .authenticate else {
                    throw HostServerError.authenticationRequired
                }
                let response = try WireJSON.decode(
                    AuthenticationResponse.self,
                    from: packet.payload
                )
                guard
                    challenge.supportedVersions.contains(
                        response.protocolVersion
                    ),
                    ProtocolVersionRange.current.contains(
                        response.protocolVersion
                    ),
                    response.capabilities.isSubset(
                        of: challenge.capabilities
                    )
                else {
                    throw HostServerError.protocolMismatch
                }
                guard
                    let credential = credentialsByID[response.credentialID],
                    credential.validates(
                        code: response.authenticationCode,
                        challenge: challenge.nonce
                    )
                else {
                    throw HostServerError.authenticationFailed
                }
                context.negotiatedProtocolVersion =
                    response.protocolVersion
                context.negotiatedCapabilities =
                    response.capabilities

                if credential.isPairingCredential {
                    context.authenticationState = .waitingForPairRequest(
                        credential: credential
                    )
                } else {
                    if
                        let activeCredentialID =
                            activeControllerCredentialID(
                                excluding: context
                            )
                    {
                        let isSameDevice =
                            activeCredentialID == credential.id
                        guard
                            isSameDevice
                                || response
                                    .requestsControllerTakeover
                        else {
                            throw HostServerError.hostBusy
                        }
                        revokeActiveControllers(
                            excluding: context
                        )
                    }
                    context.authenticationState = .active(
                        credential: credential
                    )
                    context.lastActivityAt = Date()
                    activate(context)
                }

            case let .waitingForPairRequest(pairingCredential):
                guard packet.kind == .pairRequest else {
                    throw HostServerError.pairingRequestRequired
                }
                let request = try WireJSON.decode(
                    PairDeviceRequest.self,
                    from: packet.payload
                )
                guard !request.deviceCredential.isPairingCredential else {
                    throw HostServerError.invalidPairingRequest
                }
                guard consumedPairingCredentialIDs.insert(
                    pairingCredential.id
                ).inserted else {
                    throw HostServerError.pairingCredentialConsumed
                }

                credentialsByID[request.deviceCredential.id] =
                    request.deviceCredential
                credentialsByID.removeValue(
                    forKey: pairingCredential.id
                )

                guard let configuration else {
                    throw HostServerError.invalidConfiguration
                }
                let accepted = PairDeviceAccepted(
                    hostID: configuration.hostID,
                    hostName: configuration.hostName,
                    hostPlatform: configuration.hostPlatform,
                    capabilities: availableCapabilities
                )
                let acceptedPayload = try WireJSON.encode(accepted)
                let updatedConfiguration = RemoteHostConfiguration(
                    hostID: configuration.hostID,
                    hostName: configuration.hostName,
                    port: configuration.port,
                    credentials: Array(credentialsByID.values),
                    hostPlatform: configuration.hostPlatform
                )
                startOnQueue(
                    configuration: updatedConfiguration
                ) { [weak self, weak context] result in
                    guard let self, let context else {
                        return
                    }
                    guard case .success = result else {
                        if case let .failure(message) = result {
                            send(
                                message: message,
                                code: .internalError,
                                to: context
                            )
                        }
                        context.connection.cancel()
                        return
                    }
                    guard
                        credentialsByID[
                            request.deviceCredential.id
                        ] != nil
                    else {
                        context.connection.cancel()
                        return
                    }
                    context.connection.send(
                        WirePacket(
                            kind: .pairAccepted,
                            payload: acceptedPayload
                        )
                    ) { [weak self, weak context] error in
                        guard let self, let context else {
                            return
                        }
                        if error == nil {
                            onPairingAccepted?(
                                request.deviceCredential
                            )
                        }
                        queue.asyncAfter(deadline: .now() + 0.2) {
                            context.connection.cancel()
                        }
                    }
                }

            case .active:
                try handleActive(packet, from: context)
            case .revoked:
                throw HostServerError.authenticationRequired
            }
        } catch {
            let isRecoverable =
                packet.kind.isRecoverableServiceMessage
            send(
                error: error,
                isRecoverable: isRecoverable,
                requestKind: packet.kind,
                requestID: requestID(for: packet),
                to: context
            ) {
                if !isRecoverable {
                    context.connection.cancel()
                }
            }
        }
    }

    private func activate(_ context: ClientContext) {
        do {
            guard let configuration else {
                throw HostServerError.invalidConfiguration
            }
            guard
                let protocolVersion =
                    context.negotiatedProtocolVersion
            else {
                throw HostServerError.protocolMismatch
            }
            onUserActivity?()
            ensureFrameSourceIsRunning()
            context.connection.send(
                WirePacket(
                    kind: .sessionReady,
                    payload: try WireJSON.encode(
                        SessionReady(
                            sessionID: UUID().uuidString,
                            protocolVersion: protocolVersion,
                            capabilities:
                                context.negotiatedCapabilities,
                            hostPermissions:
                                permissionStateProvider(),
                            hostPlatform:
                                configuration.hostPlatform
                        )
                    )
                )
            )
            context.connection.send(
                WirePacket(
                    kind: .displayInfo,
                    payload: try WireJSON.encode(
                        frameSource.displayInformation
                    )
                )
            )
        } catch {
            send(error: error, to: context)
        }
    }

    private func handleActive(
        _ packet: WirePacket,
        from context: ClientContext
    ) throws {
        context.lastActivityAt = Date()
        switch packet.kind {
        case .input:
            let input = try WireJSON.decode(
                RemoteInputEvent.self,
                from: packet.payload
            )
            onUserActivity?()
            context.inputSequence += 1
            let acknowledgement = InputAcknowledgement(
                sequence: context.inputSequence,
                summary: inputSink.handle(input)
            )
            context.connection.send(
                WirePacket(
                    kind: .inputAcknowledgement,
                    payload: try WireJSON.encode(acknowledgement)
                )
            )
        case .ping:
            context.connection.send(WirePacket(kind: .pong))
        case .terminalListRequest:
            try sendTerminalSessions(to: context)
        case .terminalCreateRequest:
            let request = try WireJSON.decode(
                TerminalCreateRequest.self,
                from: packet.payload
            )
            let workingDirectory: URL?
            if let path = request.workingDirectoryPath {
                guard let fileService else {
                    throw HostServerError.fileServiceUnavailable
                }
                workingDirectory =
                    try fileService.resolveDirectory(path: path)
            } else {
                workingDirectory = nil
            }
            let created = try requiredTerminalService().createSession(
                preferredName: request.preferredName,
                launchProfile: request.launchProfile,
                launchArguments: request.launchArguments,
                workingDirectory: workingDirectory
            )
            try sendTerminalSessions(
                to: context,
                createdSessionID: created.id,
                createdRequestID: request.requestID
            )
        case .terminalAttachRequest:
            let request = try WireJSON.decode(
                TerminalAttachRequest.self,
                from: packet.payload
            )
            try attachTerminal(request, to: context)
        case .terminalInput:
            guard packet.payload.count <= 64 * 1_024 else {
                throw HostServerError.terminalInputTooLarge
            }
            context.terminalAttachment?.send(packet.payload)
        case .terminalResize:
            let request = try WireJSON.decode(
                TerminalResizeRequest.self,
                from: packet.payload
            )
            context.terminalAttachment?.resize(
                columns: request.columns,
                rows: request.rows
            )
        case .terminalDetach:
            detachTerminal(from: context, notify: true)
        case .terminalOpenOnMac:
            let request = try WireJSON.decode(
                TerminalSessionRequest.self,
                from: packet.payload
            )
            try requiredTerminalService().openOnMac(
                sessionID: request.sessionID
            )
        case .terminalRename:
            guard
                let protocolVersion =
                    context.negotiatedProtocolVersion,
                protocolVersion
                    >= ReLandConstants
                        .minimumTerminalRenameProtocolVersion
            else {
                throw HostServerError.protocolMismatch
            }
            let request = try WireJSON.decode(
                TerminalRenameRequest.self,
                from: packet.payload
            )
            try requiredTerminalService().renameSession(
                sessionID: request.sessionID,
                name: request.name
            )
            try sendTerminalSessions(to: context)
        case .terminalKill:
            let request = try WireJSON.decode(
                TerminalSessionRequest.self,
                from: packet.payload
            )
            if context.terminalAttachment?.sessionID
                == request.sessionID
            {
                detachTerminal(from: context, notify: true)
            }
            try requiredTerminalService().killSession(
                sessionID: request.sessionID
            )
            try sendTerminalSessions(to: context)
        case .terminalArtifactListRequest:
            let request = try WireJSON.decode(
                TerminalArtifactListRequest.self,
                from: packet.payload
            )
            let artifacts = try requiredTerminalService()
                .listArtifacts(sessionID: request.sessionID)
            context.connection.send(
                WirePacket(
                    kind: .terminalArtifactListResponse,
                    payload: try WireJSON.encode(
                        TerminalArtifactListResponse(
                            sessionID: request.sessionID,
                            artifacts: artifacts
                        )
                    )
                )
            )
        case .terminalArtifactReadRequest:
            let request = try WireJSON.decode(
                TerminalArtifactReadRequest.self,
                from: packet.payload
            )
            let chunk = try requiredTerminalService()
                .readArtifact(request: request)
            context.connection.send(
                WirePacket(
                    kind: .terminalArtifactChunk,
                    payload: try WireJSON.encode(chunk)
                )
            )
        case .fileListRequest:
            let request = try WireJSON.decode(
                RemoteFileListRequest.self,
                from: packet.payload
            )
            guard let fileService else {
                throw HostServerError.fileServiceUnavailable
            }
            context.connection.send(
                WirePacket(
                    kind: .fileListResponse,
                    payload: try WireJSON.encode(
                        fileService.list(request: request)
                    )
                )
            )
        case .fileReadRequest:
            let request = try WireJSON.decode(
                RemoteFileReadRequest.self,
                from: packet.payload
            )
            guard let fileService else {
                throw HostServerError.fileServiceUnavailable
            }
            context.connection.send(
                WirePacket(
                    kind: .fileChunk,
                    payload: try WireJSON.encode(
                        fileService.read(request: request)
                    )
                )
            )
        case .captureTargetListRequest:
            guard
                let source =
                    frameSource as? any RemoteCaptureTargetSource
            else {
                throw HostServerError.captureTargetsUnavailable
            }
            source.listCaptureTargets {
                [weak self, weak context] result in
                guard let self, let context else {
                    return
                }
                queue.async {
                    switch result {
                    case let .success(response):
                        if let payload = try? WireJSON.encode(response) {
                            context.connection.send(
                                WirePacket(
                                    kind: .captureTargetListResponse,
                                    payload: payload
                                )
                            )
                        }
                    case let .failure(error):
                        self.send(
                            error: error,
                            isRecoverable: true,
                            requestKind: .captureTargetListRequest,
                            to: context
                        )
                    }
                }
            }
        case .captureTargetSelectRequest:
            let request = try WireJSON.decode(
                RemoteCaptureTargetSelectRequest.self,
                from: packet.payload
            )
            guard
                let source =
                    frameSource as? any RemoteCaptureTargetSource
            else {
                throw HostServerError.captureTargetsUnavailable
            }
            source.selectCaptureTarget(id: request.targetID) {
                [weak self, weak context] result in
                guard let self, let context else {
                    return
                }
                queue.async {
                    switch result {
                    case let .success(selected):
                        if let payload = try? WireJSON.encode(selected) {
                            context.connection.send(
                                WirePacket(
                                    kind: .captureTargetSelected,
                                    payload: payload
                                )
                            )
                        }
                        self.broadcastDisplayInformation(
                            selected.displayInformation
                        )
                    case let .failure(error):
                        self.send(
                            error: error,
                            isRecoverable: true,
                            requestKind: .captureTargetSelectRequest,
                            to: context
                        )
                    }
                }
            }
        case .hostStatusRequest:
            context.connection.send(
                WirePacket(
                    kind: .hostStatusResponse,
                    payload: try WireJSON.encode(
                        permissionStateProvider()
                    )
                )
            )
        default:
            break
        }
    }

    private func ensureFrameSourceIsRunning() {
        guard !frameSourceIsRunning else {
            return
        }
        frameSourceIsRunning = true
        frameSource.start(
            frameHandler: { [weak self] data in
                guard let self else {
                    return
                }
                queue.async { [self] in
                    self.broadcast(frame: data)
                }
            },
            errorHandler: { [weak self] error in
                guard let self else {
                    return
                }
                queue.async { [self] in
                    broadcast(error: error)
                }
            }
        )
    }

    private func stopFrameSourceIfNeeded() {
        guard frameSourceIsRunning else {
            return
        }
        frameSource.stop()
        frameSourceIsRunning = false
    }

    private func activeControllerCredentialID(
        excluding excludedContext: ClientContext
    ) -> String? {
        clients.values.compactMap { context -> String? in
            guard context.id != excludedContext.id else {
                return nil
            }
            if
                case let .active(credential) =
                    context.authenticationState
            {
                return credential.id
            }
            return nil
        }.first
    }

    private func revokeActiveControllers(
        excluding excludedContext: ClientContext
    ) {
        for context in clients.values {
            guard
                context.id != excludedContext.id,
                case .active = context.authenticationState
            else {
                continue
            }
            context.authenticationState = .revoked
            context.terminalAttachment?.close()
            context.terminalAttachment = nil
            context.terminalAttachmentID = nil
            send(
                message: "Another device took over this ReLand session",
                code: .sessionTakenOver,
                to: context
            ) {
                context.connection.cancel()
            }
        }
    }

    private func startLivenessTimer() {
        guard livenessTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + livenessCheckInterval,
            repeating: livenessCheckInterval,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.expireInactiveControllers()
        }
        livenessTimer = timer
        timer.resume()
    }

    private func stopLivenessTimer() {
        livenessTimer?.cancel()
        livenessTimer = nil
    }

    private func expireInactiveControllers() {
        let now = Date()
        for context in clients.values {
            guard
                case .active = context.authenticationState,
                now.timeIntervalSince(context.lastActivityAt)
                    > controllerLeaseDuration
            else {
                continue
            }
            send(
                message: "The remote-control lease expired",
                code: .sessionExpired,
                to: context
            ) {
                context.connection.cancel()
            }
        }
    }

    private func broadcast(frame: Data) {
        for context in clients.values {
            guard
                case .active = context.authenticationState,
                !context.isSendingFrame
            else {
                continue
            }
            context.isSendingFrame = true
            context.connection.send(
                WirePacket(kind: .videoFrame, payload: frame)
            ) { [weak self, weak context] _ in
                guard let self, let context else {
                    return
                }
                queue.async {
                    context.isSendingFrame = false
                }
            }
        }
    }

    private func broadcast(error: Error) {
        for context in clients.values {
            guard case .active = context.authenticationState else {
                continue
            }
            send(
                error: error,
                isRecoverable: true,
                to: context
            )
        }
    }

    private func broadcastDisplayInformation(
        _ information: DisplayInformation
    ) {
        guard let payload = try? WireJSON.encode(information) else {
            return
        }
        for context in clients.values {
            guard case .active = context.authenticationState else {
                continue
            }
            context.connection.send(
                WirePacket(kind: .displayInfo, payload: payload)
            )
        }
    }

    private func send(
        error: Error,
        isRecoverable: Bool = false,
        requestKind: WireMessageKind? = nil,
        requestID: UUID? = nil,
        to context: ClientContext,
        completion: (@Sendable () -> Void)? = nil
    ) {
        if let hostError = error as? HostServerError {
            send(
                message: hostError.localizedDescription,
                code: hostError.remoteCode,
                isRecoverable: isRecoverable,
                requestKind: requestKind,
                requestID: requestID,
                to: context,
                completion: completion
            )
        } else {
            send(
                message: error.localizedDescription,
                code: .internalError,
                isRecoverable: isRecoverable,
                requestKind: requestKind,
                requestID: requestID,
                to: context,
                completion: completion
            )
        }
    }

    private func send(
        message: String,
        code: RemoteErrorCode,
        isRecoverable: Bool = false,
        requestKind: WireMessageKind? = nil,
        requestID: UUID? = nil,
        to context: ClientContext,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard let payload = try? WireJSON.encode(
            RemoteErrorMessage(
                code: code,
                message: message,
                isRecoverable: isRecoverable,
                requestKind: requestKind,
                requestID: requestID
            )
        ) else {
            completion?()
            return
        }
        context.connection.send(
            WirePacket(kind: .error, payload: payload)
        ) { _ in
            completion?()
        }
    }

    private func remove(_ context: ClientContext) {
        guard clients.removeValue(forKey: context.id) != nil else {
            return
        }
        context.terminalAttachment?.close()
        context.terminalAttachment = nil
        context.terminalAttachmentID = nil
        onClientCountChange?(clients.count)
        if clients.values.allSatisfy({
            if case .active = $0.authenticationState {
                return false
            }
            return true
        }) {
            stopFrameSourceIfNeeded()
        }
    }

    private func failPendingListenerActions(with message: String) {
        let actions = pendingListenerReadyActions
        pendingListenerReadyActions.removeAll()
        for action in actions {
            action(.failure(message))
        }
    }

        private func requiredTerminalService()
            throws -> any RemoteTerminalService
        {
            guard let terminalService else {
                throw HostServerError.terminalUnavailable
            }
            return terminalService
        }

        private func sendTerminalSessions(
            to context: ClientContext,
            createdSessionID: String? = nil,
            createdRequestID: UUID? = nil
        ) throws {
            let sessions = try requiredTerminalService().listSessions()
            let supportsCreationCorrelation =
                context.negotiatedProtocolVersion.map {
                    $0 >= ReLandConstants
                        .minimumTerminalCreationCorrelationProtocolVersion
                } ?? false
            context.connection.send(
                WirePacket(
                    kind: .terminalListResponse,
                    payload: try WireJSON.encode(
                        TerminalSessionList(
                            sessions: sessions,
                            createdSessionID:
                                supportsCreationCorrelation
                                ? createdSessionID
                                : nil,
                            createdRequestID:
                                supportsCreationCorrelation
                                ? createdRequestID
                                : nil
                        )
                    )
                )
            )
        }

        private func requestID(for packet: WirePacket) -> UUID? {
            guard packet.kind == .terminalCreateRequest else {
                return nil
            }
            return try? WireJSON.decode(
                TerminalCreateRequest.self,
                from: packet.payload
            ).requestID
        }

        private func attachTerminal(
            _ request: TerminalAttachRequest,
            to context: ClientContext
        ) throws {
            detachTerminal(from: context, notify: false)
            let service = try requiredTerminalService()
            let attachmentID = UUID()
            context.terminalAttachmentID = attachmentID
            let attachment: any RemoteTerminalAttachment
            do {
                attachment = try service.attach(
                    attachmentID: attachmentID,
                    sessionID: request.sessionID,
                    columns: request.columns,
                    rows: request.rows,
                    outputHandler: { [weak self, weak context] data in
                        guard let self, let context else {
                            return
                        }
                        queue.async { [self] in
                            guard
                                clients[context.id] != nil,
                                context.terminalAttachmentID
                                    == attachmentID
                            else {
                                return
                            }
                            guard
                                let payload = try? WireJSON.encode(
                                    TerminalOutputChunk(
                                        sessionID: request.sessionID,
                                        attachmentID: attachmentID,
                                        data: data
                                    )
                                )
                            else {
                                return
                            }
                            context.connection.send(
                                WirePacket(
                                    kind: .terminalOutput,
                                    payload: payload
                                )
                            )
                        }
                    },
                    terminationHandler: { [weak self, weak context] in
                        guard let self, let context else {
                            return
                        }
                        queue.async {
                            guard
                                context.terminalAttachmentID
                                    == attachmentID
                            else {
                                return
                            }
                            context.terminalAttachment = nil
                            context.terminalAttachmentID = nil
                            context.connection.send(
                                WirePacket(kind: .terminalDetached)
                            )
                        }
                    }
                )
            } catch {
                if context.terminalAttachmentID == attachmentID {
                    context.terminalAttachmentID = nil
                }
                throw error
            }
            context.terminalAttachment = attachment
            context.connection.send(
                WirePacket(
                    kind: .terminalAttached,
                    payload: try WireJSON.encode(
                        TerminalAttached(
                            sessionID: request.sessionID,
                            attachmentID: attachmentID
                        )
                    )
                )
            )
            attachment.start()
        }

        private func detachTerminal(
            from context: ClientContext,
            notify: Bool
        ) {
            let attachment = context.terminalAttachment
            context.terminalAttachment = nil
            context.terminalAttachmentID = nil
            attachment?.close()
            if notify {
                context.connection.send(
                    WirePacket(kind: .terminalDetached)
                )
            }
        }
}

private extension WireMessageKind {
    var isRecoverableServiceMessage: Bool {
        switch self {
        case .terminalListRequest,
             .terminalListResponse,
             .terminalCreateRequest,
             .terminalAttachRequest,
             .terminalAttached,
             .terminalOutput,
             .terminalInput,
             .terminalResize,
             .terminalDetach,
             .terminalDetached,
             .terminalOpenOnMac,
             .terminalRename,
             .terminalKill,
             .terminalArtifactListRequest,
             .terminalArtifactListResponse,
             .terminalArtifactReadRequest,
             .terminalArtifactChunk,
             .fileListRequest,
             .fileListResponse,
             .fileReadRequest,
             .fileChunk,
             .captureTargetListRequest,
             .captureTargetListResponse,
             .captureTargetSelectRequest,
             .captureTargetSelected,
             .hostStatusRequest,
             .hostStatusResponse:
            true
        default:
            false
        }
    }
}

private enum HostServerError: LocalizedError {
    case authenticationRequired
    case authenticationFailed
    case pairingRequestRequired
    case invalidPairingRequest
    case pairingCredentialConsumed
    case invalidConfiguration
    case protocolMismatch
    case hostBusy
    case terminalUnavailable
    case terminalInputTooLarge
    case fileServiceUnavailable
    case captureTargetsUnavailable

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Authentication is required"
        case .authenticationFailed:
            "Authentication failed"
        case .pairingRequestRequired:
            "A pairing request is required"
        case .invalidPairingRequest:
            "The pairing request is invalid"
        case .pairingCredentialConsumed:
            "This pairing code has already been used"
        case .invalidConfiguration:
            "The host configuration is invalid"
        case .protocolMismatch:
            "No compatible ReLand protocol version is available"
        case .hostBusy:
            "Another device is already controlling this Mac"
        case .terminalUnavailable:
            "Terminal access is unavailable on this Mac"
        case .terminalInputTooLarge:
            "The terminal input payload is too large"
        case .fileServiceUnavailable:
            "Mac file browsing is unavailable"
        case .captureTargetsUnavailable:
            "Mac app window capture is unavailable"
        }
    }

    var remoteCode: RemoteErrorCode {
        switch self {
        case .authenticationRequired:
            .authenticationRequired
        case .authenticationFailed:
            .authenticationFailed
        case .pairingRequestRequired:
            .pairingRequestRequired
        case .invalidPairingRequest:
            .invalidPairingRequest
        case .pairingCredentialConsumed:
            .pairingCredentialConsumed
        case .invalidConfiguration:
            .invalidConfiguration
        case .protocolMismatch:
            .protocolMismatch
        case .hostBusy:
            .hostBusy
        case .terminalUnavailable:
            .terminalUnavailable
        case .terminalInputTooLarge:
            .terminalInputTooLarge
        case .fileServiceUnavailable:
            .fileServiceUnavailable
        case .captureTargetsUnavailable:
            .captureTargetsUnavailable
        }
    }
}
