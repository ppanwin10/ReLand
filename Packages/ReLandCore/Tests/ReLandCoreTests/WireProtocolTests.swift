import Foundation
import Testing
@testable import ReLandCore

struct WireProtocolTests {
    @Test
    func windowsSessionAndPairingMetadataRoundTrip() throws {
        let capabilities: Set<RemoteCapability> = [
            .screen, .input, .hostStatus,
        ]
        let ready = SessionReady(
            sessionID: "windows-session",
            protocolVersion: 8,
            capabilities: capabilities,
            hostPlatform: .windows
        )
        let accepted = PairDeviceAccepted(
            hostID: "windows-host",
            hostName: "Test Windows PC",
            hostPlatform: .windows,
            capabilities: capabilities
        )

        #expect(try WireJSON.decode(SessionReady.self, from: WireJSON.encode(ready)) == ready)
        #expect(
            try WireJSON.decode(
                PairDeviceAccepted.self,
                from: WireJSON.encode(accepted)
            ) == accepted
        )
    }

    @Test
    func legacyMacMetadataStillDecodes() throws {
        let accepted = try WireJSON.decode(
            PairDeviceAccepted.self,
            from: Data(#"{"hostID":"host","hostName":"Test Mac"}"#.utf8)
        )
        let ready = try WireJSON.decode(
            SessionReady.self,
            from: Data(
                """
                {
                  "sessionID":"legacy-session",
                  "protocolVersion":7,
                  "capabilities":["screen","input"],
                  "hostPermissions":{
                    "screenRecordingGranted":true,
                    "accessibilityGranted":true,
                    "sessionUnlocked":true
                  }
                }
                """.utf8
            )
        )

        #expect(accepted.hostPlatform == .macOS)
        #expect(accepted.capabilities == nil)
        #expect(ready.hostPlatform == .macOS)
        #expect(ready.protocolVersion == 7)
    }

    @Test
    func savedLegacyMacAndWindowsCapabilitiesRemainDistinct() throws {
        let legacy = try WireJSON.decode(
            RemoteDevice.self,
            from: Data(
                """
                {
                  "id":"device","hostID":"host","name":"Test Mac",
                  "address":"192.168.1.20","port":45454,"credentialID":"credential"
                }
                """.utf8
            )
        )
        let windows = RemoteDevice(
            hostID: "windows-host",
            name: "Test Windows PC",
            address: "192.168.1.20",
            port: 45454,
            credentialID: "windows-credential",
            hostPlatform: .windows,
            capabilities: [.screen, .input, .hostStatus]
        )
        let decoded = try WireJSON.decode(RemoteDevice.self, from: WireJSON.encode(windows))

        #expect(legacy.hostPlatform == .macOS)
        #expect(legacy.supports(.terminal))
        #expect(legacy.supports(.captureTargets))
        #expect(decoded == windows)
        #expect(decoded.supports(.screen))
        #expect(!decoded.supports(.terminal))
        #expect(!decoded.supports(.files))
        #expect(!decoded.supports(.captureTargets))
    }

    @Test
    func windowsDeviceWithoutCapabilitySnapshotDefaultsToDesktopOnly() {
        let device = RemoteDevice(
            hostID: "host", name: "Test Windows PC",
            address: "192.168.1.20", port: 45454, credentialID: "credential",
            hostPlatform: .windows
        )
        #expect(device.supports(.screen))
        #expect(device.supports(.input))
        #expect(!device.supports(.terminal))
        #expect(!device.supports(.files))
        #expect(!device.supports(.captureTargets))
    }

    @Test
    func packetRoundTripAcrossFragmentedReads() throws {
        let first = WirePacket(
            kind: .challenge,
            payload: Data("first".utf8)
        )
        let second = WirePacket(
            kind: .input,
            payload: Data("second".utf8)
        )
        let encoded = try WirePacketCodec.encode(first)
            + WirePacketCodec.encode(second)
        let decoder = WirePacketStreamDecoder()

        #expect(try decoder.append(encoded.prefix(3)).isEmpty)
        #expect(try decoder.append(encoded.dropFirst(3).prefix(5)).isEmpty)
        let packets = try decoder.append(encoded.dropFirst(8))

        #expect(packets == [first, second])
    }

    @Test
    func rejectsOversizedPacket() throws {
        var data = Data()
        data.appendUInt32(
            UInt32(ReLandConstants.maximumPacketSize + 1)
        )
        data.append(WireMessageKind.videoFrame.rawValue)

        let decoder = WirePacketStreamDecoder()
        #expect(throws: WireProtocolError.packetTooLarge) {
            _ = try decoder.append(data)
        }
    }

    @Test
    func skipsUnknownOptionalExtensionPacket() throws {
        var extensionPacket = Data()
        extensionPacket.appendUInt32(4)
        extensionPacket.append(200)
        extensionPacket.append(Data([1, 2, 3]))
        let known = WirePacket(
            kind: .pong,
            payload: Data("known".utf8)
        )
        let decoder = WirePacketStreamDecoder()

        let packets = try decoder.append(
            extensionPacket + WirePacketCodec.encode(known)
        )

        #expect(packets == [known])
    }

    @Test
    func rejectsUnknownReservedCorePacket() {
        var packet = Data()
        packet.appendUInt32(1)
        packet.append(40)
        let decoder = WirePacketStreamDecoder()

        #expect(throws: WireProtocolError.unknownMessageKind(40)) {
            _ = try decoder.append(packet)
        }
    }

    @Test
    func artifactChunkRoundTrips() throws {
        let chunk = TerminalArtifactChunk(
            sessionID: "rl-test",
            artifactID: "artifact-1",
            offset: 256,
            totalByteCount: 512,
            data: Data("preview".utf8),
            isComplete: true
        )

        let decoded = try WireJSON.decode(
            TerminalArtifactChunk.self,
            from: WireJSON.encode(chunk)
        )

        #expect(decoded == chunk)
        #expect(ReLandConstants.protocolVersion == 8)
        #expect(ProtocolVersionRange.current.minimum == 7)
        #expect(ProtocolVersionRange.current.maximum == 8)
    }

    @Test
    func remoteFileListRoundTrips() throws {
        let response = RemoteFileListResponse(
            path: "Documents",
            parentPath: "",
            entries: [
                RemoteFileEntry(
                    path: "Documents/report.txt",
                    name: "report.txt",
                    contentType: "public.plain-text",
                    kind: .text,
                    byteCount: 12,
                    modifiedAt: Date(
                        timeIntervalSince1970: 1_700_000_000
                    )
                ),
            ]
        )

        let decoded = try WireJSON.decode(
            RemoteFileListResponse.self,
            from: WireJSON.encode(response)
        )

        #expect(decoded == response)
    }

    @Test
    func captureTargetSelectionRoundTrips() throws {
        let selected = RemoteCaptureTargetSelected(
            target: RemoteCaptureTargetInfo(
                id: "window-42",
                kind: .window,
                applicationName: "Preview",
                title: "Document",
                width: 900,
                height: 700
            ),
            displayInformation: DisplayInformation(
                width: 900,
                height: 700,
                framesPerSecond: 12
            )
        )

        let decoded = try WireJSON.decode(
            RemoteCaptureTargetSelected.self,
            from: WireJSON.encode(selected)
        )

        #expect(decoded == selected)
    }

    @Test
    func negotiatesHighestCommonProtocolVersion() {
        let local = ProtocolVersionRange(minimum: 6, maximum: 8)
        let overlapping = ProtocolVersionRange(
            minimum: 5,
            maximum: 7
        )
        let incompatible = ProtocolVersionRange(
            minimum: 9,
            maximum: 10
        )

        #expect(local.highestCommonVersion(with: overlapping) == 7)
        #expect(local.highestCommonVersion(with: incompatible) == nil)
    }

    @Test
    func authenticationNegotiationRoundTrips() throws {
        let capabilities: Set<RemoteCapability> = [
            .screen,
            .input,
            .terminal,
            .artifacts,
            .files,
            .captureTargets,
        ]
        let challenge = AuthenticationChallenge(
            nonce: Data(repeating: 0x42, count: 32),
            supportedVersions: .current,
            capabilities: capabilities
        )
        let response = AuthenticationResponse(
            credentialID: "device",
            authenticationCode: Data(repeating: 0x24, count: 32),
            protocolVersion: ReLandConstants.protocolVersion,
            capabilities: [.screen, .input]
        )
        let ready = SessionReady(
            sessionID: "session",
            protocolVersion: ReLandConstants.protocolVersion,
            capabilities: capabilities
        )

        #expect(
            try WireJSON.decode(
                AuthenticationChallenge.self,
                from: WireJSON.encode(challenge)
            ) == challenge
        )
        #expect(
            try WireJSON.decode(
                AuthenticationResponse.self,
                from: WireJSON.encode(response)
            ) == response
        )
        #expect(
            try WireJSON.decode(
                SessionReady.self,
                from: WireJSON.encode(ready)
            ) == ready
        )
    }

    @Test
    func structuredRemoteErrorRoundTrips() throws {
        let requestID = UUID()
        let error = RemoteErrorMessage(
            code: .authenticationFailed,
            message: "Authentication failed",
            isRecoverable: true,
            requestKind: .terminalCreateRequest,
            requestID: requestID
        )

        let decoded = try WireJSON.decode(
            RemoteErrorMessage.self,
            from: WireJSON.encode(error)
        )

        #expect(decoded == error)
    }

    @Test
    func legacyRemoteErrorDefaultsToNonRecoverable() throws {
        let legacyPayload = Data(
            """
            {
              "code": "authenticationFailed",
              "message": "Authentication failed"
            }
            """.utf8
        )

        let decoded = try WireJSON.decode(
            RemoteErrorMessage.self,
            from: legacyPayload
        )

        #expect(decoded.isRecoverable == false)
        #expect(decoded.requestKind == nil)
        #expect(decoded.requestID == nil)
    }

    @Test
    func terminalSessionListIdentifiesCreatedSession() throws {
        let requestID = UUID()
        let session = TerminalSessionInfo(
            id: "rl-terminal-2",
            name: "terminal-2",
            windowCount: 1,
            attachedClientCount: 0,
            createdAt: nil
        )
        let list = TerminalSessionList(
            sessions: [session],
            createdSessionID: session.id,
            createdRequestID: requestID
        )

        let decoded = try WireJSON.decode(
            TerminalSessionList.self,
            from: WireJSON.encode(list)
        )

        #expect(decoded == list)
    }

    @Test
    func legacyTerminalSessionListHasNoCreationContext() throws {
        let decoded = try WireJSON.decode(
            TerminalSessionList.self,
            from: Data(#"{"sessions":[]}"#.utf8)
        )

        #expect(decoded.sessions.isEmpty)
        #expect(decoded.createdSessionID == nil)
        #expect(decoded.createdRequestID == nil)
    }

    @Test
    func legacyTerminalCreationMatchesSingleNewSession() {
        let requestID = UUID()
        let existing = TerminalSessionInfo(
            id: "rl-existing",
            name: "existing",
            windowCount: 1,
            attachedClientCount: 0,
            createdAt: nil
        )
        let created = TerminalSessionInfo(
            id: "rl-created",
            name: "created",
            windowCount: 1,
            attachedClientCount: 0,
            createdAt: nil
        )
        let list = TerminalSessionList(
            sessions: [existing, created]
        )

        #expect(
            list.creationMatch(
                requestID: requestID,
                existingSessionIDs: [existing.id]
            ) == .created(created)
        )
    }

    @Test
    func legacyTerminalCreationUsesRefreshedHostBaseline() {
        let requestID = UUID()
        let stale = TerminalSessionInfo(
            id: "rl-stale",
            name: "stale",
            windowCount: 1,
            attachedClientCount: 0,
            createdAt: nil
        )
        let created = TerminalSessionInfo(
            id: "rl-created",
            name: "created",
            windowCount: 1,
            attachedClientCount: 0,
            createdAt: nil
        )
        let list = TerminalSessionList(
            sessions: [stale, created]
        )

        #expect(
            list.creationMatch(
                requestID: requestID,
                existingSessionIDs: [stale.id]
            ) == .created(created)
        )
    }

    @Test
    func correlatedCreationDoesNotUseLegacyFallback() {
        let requestID = UUID()
        let list = TerminalSessionList(
            sessions: [
                TerminalSessionInfo(
                    id: "rl-created",
                    name: "created",
                    windowCount: 1,
                    attachedClientCount: 0,
                    createdAt: nil
                ),
            ]
        )

        #expect(
            list.creationMatch(
                requestID: requestID,
                existingSessionIDs: [],
                allowsLegacyFallback: false
            ) == .pending
        )
    }

    @Test
    func legacyTerminalCreationRejectsAmbiguousNewSessions() {
        let requestID = UUID()
        let list = TerminalSessionList(
            sessions: [
                TerminalSessionInfo(
                    id: "rl-created-1",
                    name: "created-1",
                    windowCount: 1,
                    attachedClientCount: 0,
                    createdAt: nil
                ),
                TerminalSessionInfo(
                    id: "rl-created-2",
                    name: "created-2",
                    windowCount: 1,
                    attachedClientCount: 0,
                    createdAt: nil
                ),
            ]
        )

        #expect(
            list.creationMatch(
                requestID: requestID,
                existingSessionIDs: []
            ) == .ambiguous
        )
    }

    @Test
    func hostPermissionStateRoundTrips() throws {
        let state = HostPermissionState(
            screenRecordingGranted: false,
            accessibilityGranted: true,
            sessionUnlocked: false
        )

        let decoded = try WireJSON.decode(
            HostPermissionState.self,
            from: WireJSON.encode(state)
        )

        #expect(decoded == state)
        #expect(WireMessageKind.hostStatusRequest.rawValue == 37)
        #expect(WireMessageKind.hostStatusResponse.rawValue == 38)
    }

    @Test
    func terminalCreateRequestCarriesApprovedWorkingFolder() throws {
        let requestID = UUID()
        let request = TerminalCreateRequest(
            requestID: requestID,
            preferredName: "project",
            launchProfile: .copilot,
            launchArguments: ["--model", "test"],
            workingDirectoryPath: "@shared-id/Project"
        )

        let decoded = try WireJSON.decode(
            TerminalCreateRequest.self,
            from: WireJSON.encode(request)
        )

        #expect(decoded == request)
    }

    @Test
    func terminalRenameRequestPreservesStableSessionID() throws {
        let request = TerminalRenameRequest(
            sessionID: "rl-terminal-2",
            name: "Project API"
        )

        let decoded = try WireJSON.decode(
            TerminalRenameRequest.self,
            from: WireJSON.encode(request)
        )

        #expect(decoded == request)
        #expect(WireMessageKind.terminalRename.rawValue == 39)
    }
}
