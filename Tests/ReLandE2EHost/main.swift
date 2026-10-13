import Foundation
import ReLandCore
import ReLandHostCore

let port = UInt16(
    ProcessInfo.processInfo.environment["RELAND_E2E_PORT"] ?? ""
) ?? ReLandConstants.defaultPort
let key = Data((0..<32).map(UInt8.init))
let credential = try PSKCredential(
    id: "reland-e2e-device",
    key: key,
    name: "iOS Simulator"
)
let frameSource = SyntheticJPEGFrameSource(
    width: 960,
    height: 540,
    fps: 10
)
let inputSink = RecordingInputSink()
let permissionState = ProcessInfo.processInfo.environment[
    "RELAND_E2E_MISSING_PERMISSIONS"
] == "1"
    ? HostPermissionState(
        screenRecordingGranted: false,
        accessibilityGranted: false,
        sessionUnlocked: true
    )
    : .granted
private let terminalService = try makeTerminalService()
private let fileService = EchoRemoteFileService()
private let configuration = RemoteHostConfiguration(
    hostID: "reland-e2e-host",
    hostName: "ReLand E2E Host",
    port: port,
    credentials: [credential]
)
let server = RemoteHostServer(
    frameSource: frameSource,
    inputSink: inputSink,
    terminalService: terminalService,
    fileService: fileService,
    permissionStateProvider: {
        permissionState
    }
)
private let windowsInputSink = RecordingInputSink()
private let windowsConfiguration = RemoteHostConfiguration(
    hostID: "reland-windows-e2e-host",
    hostName: "ReLand Windows E2E Host",
    port: try fixturePort(after: port, offset: 1),
    credentials: [credential],
    hostPlatform: .windows
)
private let windowsServer = RemoteHostServer(
    frameSource: DesktopOnlyFrameSource(),
    inputSink: windowsInputSink
)
private let delayedReconnect = try DelayedReconnectFixture(
    server: server,
    configuration: configuration,
    controlPort: fixturePort(after: port, offset: 2)
)

server.onStateChange = { state in
    delayedReconnect.hostStateChanged(state)
    switch state {
    case let .ready(activePort):
        print("RELAND_E2E_READY:\(activePort)")
        fflush(stdout)
    case let .failed(message):
        fputs("RELAND_E2E_FAILED:\(message)\n", stderr)
        fflush(stderr)
    case .starting, .stopped:
        break
    }
}

windowsServer.onStateChange = { state in
    switch state {
    case let .ready(activePort):
        print("RELAND_E2E_WINDOWS_READY:\(activePort)")
        fflush(stdout)
    case let .failed(message):
        fputs("RELAND_E2E_WINDOWS_FAILED:\(message)\n", stderr)
        fflush(stderr)
    case .starting, .stopped:
        break
    }
}

configureInputHandlers(
    inputSink,
    server: server,
    configuration: configuration,
    delayedReconnect: delayedReconnect
)
configureInputHandlers(
    windowsInputSink,
    server: windowsServer,
    configuration: windowsConfiguration
)

server.start(configuration: configuration)
windowsServer.start(configuration: windowsConfiguration)
delayedReconnect.start()

dispatchMain()

private func configureInputHandlers(
    _ inputSink: RecordingInputSink,
    server: RemoteHostServer,
    configuration: RemoteHostConfiguration,
    delayedReconnect: DelayedReconnectFixture? = nil
) {
    inputSink.onEvent = { event, summary in
        print("RELAND_E2E_INPUT:\(summary)")
        fflush(stdout)
        if case .text("__RELAND_DISCONNECT__") = event {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                server.disconnectClients()
            }
        } else if case .text("__RELAND_DELAYED_DISCONNECT__") = event {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if let delayedReconnect {
                    delayedReconnect.pause()
                } else {
                    server.stop()
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + 1.5
                    ) {
                        server.start(configuration: configuration)
                    }
                }
            }
        }
    }
}

private func fixturePort(after port: UInt16, offset: UInt16) throws -> UInt16 {
    guard port <= UInt16.max - offset else {
        throw RemoteCaptureTargetSourceError.message(
            "The E2E port leaves no port for a companion fixture."
        )
    }
    return port + offset
}

private final class DesktopOnlyFrameSource: RemoteFrameSource {
    private let source = SyntheticJPEGFrameSource(
        width: 960, height: 540, fps: 10
    )

    var displayInformation: DisplayInformation {
        source.displayInformation
    }

    func start(
        frameHandler: @escaping @Sendable (Data) -> Void,
        errorHandler: @escaping @Sendable (Error) -> Void
    ) {
        source.start(frameHandler: frameHandler, errorHandler: errorHandler)
    }

    func stop() {
        source.stop()
    }
}

private func makeTerminalService() throws -> any RemoteTerminalService {
    if ProcessInfo.processInfo.environment[
        "RELAND_E2E_USE_TMUX"
    ] == "1" {
        return try TmuxTerminalService()
    }
    return EchoTerminalService()
}

private final class EchoTerminalService:
    RemoteTerminalService,
    @unchecked Sendable
{
    private static let artifactData = Data(
        "ReLand terminal artifact preview\n".utf8
    )

    private let lock = NSLock()
    private var attachmentCounts: [String: Int] = [:]
    private var sessions: [TerminalSessionInfo] = [
        TerminalSessionInfo(
            id: "rl-e2e",
            name: "E2E Terminal",
            windowCount: 1,
            attachedClientCount: 0,
            createdAt: Date()
        ),
    ]

    func listSessions() throws -> [TerminalSessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    func createSession(
        preferredName: String?,
        launchProfile _: TerminalLaunchProfile,
        launchArguments _: [String],
        workingDirectory _: URL?
    ) throws -> TerminalSessionInfo {
        lock.lock()
        defer { lock.unlock() }
        let number = sessions.count + 1
        let name = preferredName ?? "terminal-\(number)"
        let session = TerminalSessionInfo(
            id: "rl-e2e-\(number)",
            name: name,
            windowCount: 1,
            attachedClientCount: 0,
            createdAt: Date()
        )
        sessions.append(session)
        return session
    }

    func attach(
        attachmentID: UUID,
        sessionID: String,
        columns: Int,
        rows: Int,
        outputHandler: @escaping @Sendable (Data) -> Void,
        terminationHandler: @escaping @Sendable () -> Void
    ) throws -> any RemoteTerminalAttachment {
        lock.lock()
        guard sessions.contains(where: { $0.id == sessionID }) else {
            lock.unlock()
            throw EchoTerminalError.missingSession
        }
        let attachmentNumber =
            (attachmentCounts[sessionID] ?? 0) + 1
        attachmentCounts[sessionID] = attachmentNumber
        lock.unlock()
        return EchoTerminalAttachment(
            attachmentID: attachmentID,
            sessionID: sessionID,
            attachmentNumber: attachmentNumber,
            columns: columns,
            rows: rows,
            outputHandler: outputHandler,
            terminationHandler: terminationHandler
        )
    }

    func openOnMac(sessionID: String) throws {
        guard sessions.contains(where: { $0.id == sessionID }) else {
            throw EchoTerminalError.missingSession
        }
    }

    func renameSession(sessionID: String, name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard
            let index = sessions.firstIndex(where: {
                $0.id == sessionID
            })
        else {
            throw EchoTerminalError.missingSession
        }
        let session = sessions[index]
        sessions[index] = TerminalSessionInfo(
            id: session.id,
            name: name,
            windowCount: session.windowCount,
            attachedClientCount: session.attachedClientCount,
            createdAt: session.createdAt
        )
    }

    func killSession(sessionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll { $0.id == sessionID }
    }

    func listArtifacts(
        sessionID: String
    ) throws -> [TerminalArtifactInfo] {
        guard sessions.contains(where: { $0.id == sessionID }) else {
            throw EchoTerminalError.missingSession
        }
        if sessionID != "rl-e2e" {
            Thread.sleep(forTimeInterval: 0.5)
        }
        let artifactID = "artifact-\(sessionID)"
        return [
            TerminalArtifactInfo(
                id: artifactID,
                sessionID: sessionID,
                name: "\(sessionID)-artifact.txt",
                contentType: "public.plain-text",
                kind: .text,
                byteCount: Int64(Self.artifactData.count),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ]
    }

    func readArtifact(
        request: TerminalArtifactReadRequest
    ) throws -> TerminalArtifactChunk {
        guard sessions.contains(where: {
            $0.id == request.sessionID
        }) else {
            throw EchoTerminalError.missingSession
        }
        guard
            request.artifactID == "artifact-\(request.sessionID)",
            request.offset >= 0,
            request.offset <= Int64(Self.artifactData.count),
            request.length > 0
        else {
            throw EchoTerminalError.missingArtifact
        }
        let start = Int(request.offset)
        let end = min(
            start + request.length,
            Self.artifactData.count
        )
        let data = Self.artifactData.subdata(in: start..<end)
        return TerminalArtifactChunk(
            sessionID: request.sessionID,
            artifactID: request.artifactID,
            offset: request.offset,
            totalByteCount: Int64(Self.artifactData.count),
            data: data,
            isComplete: end >= Self.artifactData.count
        )
    }
}

private final class EchoTerminalAttachment:
    RemoteTerminalAttachment,
    @unchecked Sendable
{
    let attachmentID: UUID
    let sessionID: String

    private let attachmentNumber: Int
    private let columns: Int
    private let rows: Int
    private let outputHandler: @Sendable (Data) -> Void
    private let terminationHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var isClosed = false
    private var backspaceCount = 0

    init(
        attachmentID: UUID,
        sessionID: String,
        attachmentNumber: Int,
        columns: Int,
        rows: Int,
        outputHandler: @escaping @Sendable (Data) -> Void,
        terminationHandler: @escaping @Sendable () -> Void
    ) {
        self.attachmentID = attachmentID
        self.sessionID = sessionID
        self.attachmentNumber = attachmentNumber
        self.columns = columns
        self.rows = rows
        self.outputHandler = outputHandler
        self.terminationHandler = terminationHandler
    }

    func start() {
        var lines = [
            "",
            "ReLand E2E terminal",
            "attachment-\(attachmentNumber)-size-\(columns)x\(rows)",
            "Swipe vertically for history and horizontally for wide output.",
        ]
        for index in 1...120 {
            let prefix = String(format: "%03d | ", index)
            let label = "terminal-scroll-fixture-\(index)"
            let padding = String(
                repeating: "-",
                count: max(1, 78 - prefix.count - label.count)
            )
            lines.append(prefix + label + padding + "|")
        }
        lines.append(
            "attachment-\(attachmentNumber)-size-\(columns)x\(rows)"
        )
        lines.append("$ ")
        outputHandler(Data(lines.joined(separator: "\r\n").utf8))
    }

    func send(_ data: Data) {
        if data == Data([0x7F]) {
            lock.lock()
            backspaceCount += 1
            let count = backspaceCount
            lock.unlock()
            outputHandler(
                Data("\rbackspace-count-\(count)".utf8)
            )
            return
        }
        outputHandler(data)
        if data.contains(0x0D) {
            outputHandler(Data("\r\n$ ".utf8))
        }
    }

    func resize(columns _: Int, rows _: Int) {}

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        terminationHandler()
    }
}

private enum EchoTerminalError: LocalizedError {
    case missingSession
    case missingArtifact

    var errorDescription: String? {
        switch self {
        case .missingSession:
            "The E2E terminal session does not exist"
        case .missingArtifact:
            "The E2E terminal artifact does not exist"
        }
    }
}

private final class EchoRemoteFileService:
    RemoteFileService,
    @unchecked Sendable
{
    private let files: [String: Data] = [
        "@test/home-note.txt": Data(
            "ReLand home file preview\n".utf8
        ),
        "@test/Test Files/nested.txt": Data(
            "Nested ReLand file\n".utf8
        ),
    ]

    func list(
        request: RemoteFileListRequest
    ) throws -> RemoteFileListResponse {
        switch request.path {
        case "":
            RemoteFileListResponse(
                path: "",
                parentPath: nil,
                entries: [
                    RemoteFileEntry(
                        path: "@reland",
                        name: "ReLand Storage",
                        contentType: "public.folder",
                        kind: .directory,
                        byteCount: nil,
                        modifiedAt: .distantPast
                    ),
                    RemoteFileEntry(
                        path: "@test",
                        name: "Test Home",
                        contentType: "public.folder",
                        kind: .directory,
                        byteCount: nil,
                        modifiedAt: .distantPast
                    ),
                ]
            )
        case "@reland":
            RemoteFileListResponse(
                path: "@reland",
                parentPath: "",
                entries: []
            )
        case "@test":
            RemoteFileListResponse(
                path: "@test",
                parentPath: "",
                entries: [
                    RemoteFileEntry(
                        path: "@test/Test Files",
                        name: "Test Files",
                        contentType: "public.folder",
                        kind: .directory,
                        byteCount: nil,
                        modifiedAt: Date(
                            timeIntervalSince1970: 1_700_000_000
                        )
                    ),
                    fileEntry(path: "@test/home-note.txt"),
                ]
            )
        case "@test/Test Files":
            RemoteFileListResponse(
                path: "@test/Test Files",
                parentPath: "@test",
                entries: [
                    fileEntry(
                        path: "@test/Test Files/nested.txt"
                    ),
                ]
            )
        default:
            throw EchoRemoteFileError.missingPath
        }
    }

    func read(
        request: RemoteFileReadRequest
    ) throws -> RemoteFileChunk {
        guard
            let file = files[request.path],
            request.offset >= 0,
            request.offset <= Int64(file.count),
            request.length > 0
        else {
            throw EchoRemoteFileError.missingPath
        }
        let start = Int(request.offset)
        let end = min(start + request.length, file.count)
        return RemoteFileChunk(
            path: request.path,
            offset: request.offset,
            totalByteCount: Int64(file.count),
            data: file.subdata(in: start..<end),
            isComplete: end >= file.count
        )
    }

    func resolveDirectory(path: String) throws -> URL {
        let allowed = [
            "@reland",
            "@test",
            "@test/Test Files",
        ]
        guard allowed.contains(path) else {
            throw EchoRemoteFileError.missingPath
        }
        return FileManager.default.temporaryDirectory
    }

    private func fileEntry(path: String) -> RemoteFileEntry {
        RemoteFileEntry(
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            contentType: "public.plain-text",
            kind: .text,
            byteCount: Int64(files[path]?.count ?? 0),
            modifiedAt: Date(
                timeIntervalSince1970: 1_700_000_000
            )
        )
    }
}

private enum EchoRemoteFileError: LocalizedError {
    case missingPath

    var errorDescription: String? {
        "The E2E Mac file path does not exist"
    }
}
