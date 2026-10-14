import Foundation
import Network
import ReLandHostCore

final class DelayedReconnectFixture: @unchecked Sendable {
    private let server: RemoteHostServer
    private let configuration: RemoteHostConfiguration
    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "com.landai.reland.e2e-reconnect-fixture"
    )
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var waitingForReady: Set<ObjectIdentifier> = []
    private var isReady = false
    private var isPaused = false

    init(
        server: RemoteHostServer,
        configuration: RemoteHostConfiguration,
        controlPort: UInt16
    ) throws {
        guard let port = NWEndpoint.Port(rawValue: controlPort) else {
            throw POSIXError(.EINVAL)
        }
        self.server = server
        self.configuration = configuration
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: port
        )
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed = state {
                fputs("RELAND_E2E_CONTROL_FAILED\n", stderr)
                fflush(stderr)
            }
        }
        listener.start(queue: queue)
    }

    func pause() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            isReady = false
            isPaused = true
            server.stop()
        }
    }

    func hostStateChanged(_ state: RemoteHostServer.State) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            switch state {
            case .ready:
                isReady = true
                let pending = waitingForReady
                waitingForReady.removeAll()
                for identity in pending {
                    if let connection = connections[identity] {
                        acknowledge(connection)
                    }
                }
            case .stopped, .starting, .failed:
                isReady = false
            }
        }
    }

    // Only the E2E executable includes this loopback-only listener. It restores
    // the fixture listener without accepting input or exposing host data.
    private func accept(_ connection: NWConnection) {
        guard
            connections.count < 4,
            case let .hostPort(host, _) = connection.endpoint,
            String(describing: host) == "127.0.0.1"
        else {
            connection.cancel()
            return
        }
        let identity = ObjectIdentifier(connection)
        connections[identity] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }
            switch state {
            case .ready:
                receiveResumeRequest(from: connection)
            case .cancelled, .failed:
                connections.removeValue(forKey: identity)
                waitingForReady.remove(identity)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak connection] in
            connection?.cancel()
        }
    }

    private func receiveResumeRequest(from connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 6,
            maximumLength: 6
        ) { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else {
                return
            }
            guard error == nil, data == Data("resume".utf8) else {
                connection.cancel()
                return
            }
            if isReady {
                acknowledge(connection)
            } else {
                waitingForReady.insert(ObjectIdentifier(connection))
                if isPaused {
                    isPaused = false
                    server.start(configuration: configuration)
                }
            }
        }
    }

    private func acknowledge(_ connection: NWConnection) {
        connection.send(
            content: Data("ready".utf8),
            completion: .contentProcessed { error in
                if error != nil {
                    fputs("RELAND_E2E_CONTROL_REPLY_FAILED\n", stderr)
                    fflush(stderr)
                }
                connection.cancel()
            }
        )
    }
}
