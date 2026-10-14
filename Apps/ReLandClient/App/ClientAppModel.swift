import CryptoKit
import Foundation
import ReLandCore
import Observation
import UIKit

@MainActor
@Observable
final class ClientAppModel {
    enum KeyboardModifier: String, CaseIterable, Identifiable {
        case command
        case option
        case control
        case shift

        var id: String { rawValue }

        var title: String {
            switch self {
            case .command:
                "Command"
            case .option:
                "Option"
            case .control:
                "Control"
            case .shift:
                "Shift"
            }
        }

        var symbol: String {
            switch self {
            case .command:
                "command"
            case .option:
                "option"
            case .control:
                "control"
            case .shift:
                "shift"
            }
        }

        func title(for platform: RemoteHostPlatform) -> String {
            if platform == .windows {
                switch self {
                case .command:
                    return "Windows"
                case .option:
                    return "Alt"
                case .control:
                    return "Control"
                case .shift:
                    return "Shift"
                }
            }
            return title
        }

        var windowsLabel: String {
            switch self {
            case .command:
                "Win"
            case .option:
                "Alt"
            case .control:
                "Ctrl"
            case .shift:
                "Shift"
            }
        }

        var flag: UInt64 {
            switch self {
            case .command:
                0x0010_0000
            case .option:
                0x0008_0000
            case .control:
                0x0004_0000
            case .shift:
                0x0002_0000
            }
        }
    }

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case authenticating
        case pairing
        case connected
        case reconnecting
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                "Disconnected"
            case .connecting:
                "Connecting"
            case .authenticating:
                "Authenticating"
            case .pairing:
                "Pairing"
            case .connected:
                "Connected"
            case .reconnecting:
                "Reconnecting"
            case let .failed(message):
                message
            }
        }
    }

    enum TerminalCreationState: Equatable {
        case idle
        case submitting
        case succeeded
        case failed(String)

        var isSubmitting: Bool {
            self == .submitting
        }
    }

    private enum PendingWorkingDirectoryPreference {
        case directory(TerminalWorkingDirectory)
        case sessionWorkspace
    }

    private struct PendingTerminalCreationRequest {
        let requestID: UUID
        let preferredName: String?
        let launchProfile: TerminalLaunchProfile
        let launchArguments: [String]
        let workingDirectoryPath: String?
    }

    var devices: [RemoteDevice] = []
    var connectionState: ConnectionState = .idle
    var remoteImage: UIImage?
    var frameCount = 0
    var lastInputAcknowledgement = "No input sent"
    var displayInformation: DisplayInformation?
    var isRemoteSessionPresented = false
    var isDirectTouchEnabled = false
    var isDragEnabled = false
    var isPairingSheetPresented = false
    var isSettingsPresented = false
    var hasCompletedOnboarding = false {
        didSet {
            settings.set(
                hasCompletedOnboarding,
                forKey: Self.onboardingCompleteKey
            )
        }
    }
    var alertMessage: String?
    var pendingPairingDescriptor: PairingDescriptor?
    var pendingTerminalExternalURL: URL?
    var terminalSecurityNotice: String?
    var isControllerTakeoverConfirmationPresented = false
    var keyboardModifiers: Set<KeyboardModifier> = []
    var editingDevice: RemoteDevice?
    var pointerSensitivity = 2.4 {
        didSet {
            settings.set(
                pointerSensitivity,
                forKey: Self.pointerSensitivityKey
            )
        }
    }
    var allowsTerminalClipboardWrites = false {
        didSet {
            settings.set(
                allowsTerminalClipboardWrites,
                forKey: Self.terminalClipboardWritesKey
            )
        }
    }
    var isThreeFingerSwitchingEnabled = true {
        didSet {
            settings.set(
                String(isThreeFingerSwitchingEnabled),
                forKey: Self.threeFingerSwitchingKey
            )
        }
    }
    var hapticsEnabled = true {
        didSet {
            settings.set(
                String(hapticsEnabled),
                forKey: Self.hapticsKey
            )
        }
    }
    var isAppSwitcherPinned = false {
        didSet {
            settings.set(
                isAppSwitcherPinned,
                forKey: Self.appSwitcherPinnedKey
            )
            if isAppSwitcherPinned {
                appSwitcherHideTask?.cancel()
                appSwitcherHideTask = nil
            }
        }
    }
    var cacheByteCount: Int64 = 0
    var savedAILaunchProfiles: [AILaunchProfile] = []
    var terminalSessions: [TerminalSessionInfo] = []
    var attachedTerminalSessionID: String?
    var isTerminalAttachmentReady = false
    var terminalCreationState: TerminalCreationState = .idle
    var isTerminalWorkspacePresented = false
    var terminalOutputPreview = ""
    var terminalArtifacts: [TerminalArtifactInfo] = []
    var terminalArtifactSessionID: String?
    var isLoadingTerminalArtifacts = false
    var terminalArtifactDownloadProgress: Double?
    var terminalArtifactPreview: TerminalArtifactPreview?
    var terminalColumns = 80
    var terminalRows = 24
    var remoteFilePath = ""
    var remoteFileParentPath: String?
    var remoteFiles: [RemoteFileEntry] = []
    var remoteFileRootNames: [String: String] = [:]
    var hasLoadedRemoteFileRoots = false
    var isLoadingRemoteFiles = false
    var remoteFileDownloadProgress: Double?
    var remoteFilePreview: RemoteFilePreview?
    var isRemoteFileBrowserPresented = false
    var captureTargets: [RemoteCaptureTargetInfo] = []
    var selectedCaptureTarget: RemoteCaptureTargetInfo?
    var hostPermissionState: HostPermissionState?
    var negotiatedProtocolVersion: UInt16?
    var negotiatedCapabilities: Set<RemoteCapability> = []
    var isCaptureTargetPickerPresented = false
    var captureTargetRevision = 0
    var isAppMode = false
    var isAppSwitcherVisible = false
    var isTerminalOnlyMode = false
    let isE2EMode: Bool

    var hostPlatform: RemoteHostPlatform {
        activeDevice?.hostPlatform ?? .macOS
    }

    func supports(_ capability: RemoteCapability) -> Bool {
        if negotiatedProtocolVersion != nil {
            return negotiatedCapabilities.contains(capability)
        }
        return activeDevice?.supports(capability) ?? false
    }

    var canSendRemoteInput: Bool {
        canUseRemoteSession
            && supports(.input)
            && hostPermissionState?.sessionUnlocked != false
            && hostPermissionState?.accessibilityGranted != false
    }

    var supportsTerminalRename: Bool {
        guard supports(.terminal), let negotiatedProtocolVersion else {
            return false
        }
        return negotiatedProtocolVersion
            >= ReLandConstants.minimumTerminalRenameProtocolVersion
    }

    private var supportsTerminalCreationCorrelation: Bool {
        guard let negotiatedProtocolVersion else {
            return false
        }
        return negotiatedProtocolVersion
            >= ReLandConstants
                .minimumTerminalCreationCorrelationProtocolVersion
    }

    var canPerformTerminalActions: Bool {
        canUseRemoteSession && supports(.terminal)
    }

    private var canUseRemoteSession: Bool {
        connectionState == .connected && session != nil
    }

    private static let pointerSensitivityKey =
        "reland.pointer-sensitivity"
    private static let terminalClipboardWritesKey =
        "reland.terminal.clipboard-writes"
    private static let onboardingCompleteKey =
        "reland.onboarding.complete"
    private static let threeFingerSwitchingKey =
        "reland.controls.three-finger-switching"
    private static let hapticsKey = "reland.controls.haptics"
    private static let appSwitcherPinnedKey =
        "reland.controls.app-switcher-pinned"
    private static let aiLaunchProfilesKey =
        "reland.ai.launch-profiles"
    private static let terminalWorkingDirectoryHistoryKey =
        "reland.terminal.working-directory-history"
    private let settings: any SettingsStoring
    private let deviceStore: DeviceStore
    private var activeDevice: RemoteDevice?
    private var activeCredential: PSKCredential?
    private var session: RemoteClientSession?
    private var reconnectTask: Task<Void, Never>?
    private var manualDisconnect = false
    private var openTerminalAfterConnect = false
    private var refreshTerminalSessionsAfterReconnect = false
    private var pendingCaptureIntent: CaptureIntent?
    private var pendingCaptureCycleDirection:
        CaptureCycleDirection?
    private var captureTargetHistory = CaptureTargetHistory()
    private var cyclingCaptureTargetID: String?
    private var appSwitcherHideTask: Task<Void, Never>?
    private var pendingTerminalCreationRequestID: UUID?
    private var pendingTerminalCreationRequest:
        PendingTerminalCreationRequest?
    private var pendingTerminalCreationExistingIDs:
        Set<String>?
    private var pendingTerminalCreationWasSent = false
    private var pendingTerminalCreationIsReconciling = false
    private var pendingWorkingDirectoryPreference:
        PendingWorkingDirectoryPreference?
    private var pendingTerminalAttachmentSessionID: String?
    private var terminalCreationTimeoutTask: Task<Void, Never>?
    @ObservationIgnored
    private var terminalOutputConsumer: ((Data) -> Void)?
    @ObservationIgnored
    private var pendingTerminalOutput = Data()
    @ObservationIgnored
    private var terminalArtifactDownload:
        TerminalArtifactDownload?
    @ObservationIgnored
    private var remoteFileDownload: RemoteFileDownload?
    private var terminalWorkingDirectoryHistory =
        TerminalWorkingDirectoryHistory()

    init(
        settings: any SettingsStoring =
            UserDefaultsSettingsStore(),
        deviceStore: DeviceStore? = nil
    ) {
        self.settings = settings
        self.deviceStore = deviceStore
            ?? DeviceStore(settings: settings)
        devices = self.deviceStore.loadDevices()
        let savedSensitivity = settings.double(
            forKey: Self.pointerSensitivityKey
        )
        if savedSensitivity >= 1, savedSensitivity <= 4 {
            pointerSensitivity = savedSensitivity
        }
        allowsTerminalClipboardWrites = settings.bool(
            forKey: Self.terminalClipboardWritesKey
        )
        hasCompletedOnboarding = settings.bool(
            forKey: Self.onboardingCompleteKey
        )
        isThreeFingerSwitchingEnabled = Self.boolSetting(
            settings,
            key: Self.threeFingerSwitchingKey,
            defaultValue: true
        )
        hapticsEnabled = Self.boolSetting(
            settings,
            key: Self.hapticsKey,
            defaultValue: true
        )
        isAppSwitcherPinned = settings.bool(
            forKey: Self.appSwitcherPinnedKey
        )
        if
            let profileData = settings.data(
                forKey: Self.aiLaunchProfilesKey
            ),
            let profiles = try? JSONDecoder().decode(
                [AILaunchProfile].self,
                from: profileData
            )
        {
            savedAILaunchProfiles = profiles
        }
        if let historyData = settings.data(
            forKey: Self.terminalWorkingDirectoryHistoryKey
        ) {
            do {
                terminalWorkingDirectoryHistory =
                    try JSONDecoder().decode(
                        TerminalWorkingDirectoryHistory.self,
                        from: historyData
                    )
            } catch {
                terminalSecurityNotice =
                    "ReLand could not load remembered project folders."
            }
        }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        isE2EMode = arguments.contains("--reland-e2e")
        if arguments.contains("--reland-reset-onboarding") {
            hasCompletedOnboarding = false
        } else if
            arguments.contains("--reland-skip-onboarding")
                || arguments.contains("--reland-device-list-e2e")
                || arguments.contains("--reland-windows-device-list-e2e")
                || isE2EMode
        {
            hasCompletedOnboarding = true
        }
        if arguments.contains("--reland-windows-device-list-e2e") {
            devices = [
                RemoteDevice(
                    id: "windows-device-list-e2e",
                    hostID: "windows-device-list-e2e-host",
                    name: "Example Windows PC",
                    address: "100.100.100.100",
                    port: ReLandConstants.defaultPort,
                    credentialID: "windows-device-list-e2e",
                    hostPlatform: .windows,
                    capabilities: [.screen, .input, .hostStatus]
                ),
            ]
        } else if arguments.contains("--reland-device-list-e2e") {
            devices = [
                RemoteDevice(
                    id: "device-list-e2e",
                    hostID: "device-list-e2e-host",
                    name: "Example MacBook Pro with a Long Name",
                    address: "100.100.100.100",
                    port: ReLandConstants.defaultPort,
                    credentialID: "device-list-e2e"
                ),
            ]
        } else if isE2EMode {
            configureE2ESession(arguments: arguments)
        }
        #else
        isE2EMode = false
        #endif
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    func restartOnboarding() {
        isSettingsPresented = false
        hasCompletedOnboarding = false
    }

    func refreshCacheUsage() {
        do {
            cacheByteCount = try Self.directoryByteCount(
                at: cacheRootURL()
            )
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func clearDownloadCache() {
        cancelTerminalArtifactDownload()
        cancelRemoteFileDownload()
        do {
            let root = cacheRootURL()
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            terminalArtifactPreview = nil
            remoteFilePreview = nil
            cacheByteCount = 0
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func resetSavedAILaunchOptions() {
        for profile in TerminalLaunchProfile.allCases {
            let prefix =
                "reland.terminal.\(profile.rawValue)."
            settings.removeObject(forKey: prefix + "bypass")
            settings.removeObject(forKey: prefix + "arguments")
        }
        savedAILaunchProfiles = []
        settings.removeObject(
            forKey: Self.aiLaunchProfilesKey
        )
        terminalSecurityNotice =
            "Reset saved ReLand AI launch arguments."
    }

    func saveAILaunchProfile(
        name: String,
        tool: TerminalLaunchProfile,
        additionalArguments: String,
        bypassPermissions: Bool
    ) throws {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty, tool != .shell else {
            throw ClientModelError.invalidAILaunchProfile
        }
        savedAILaunchProfiles.removeAll {
            $0.name.localizedCaseInsensitiveCompare(
                trimmedName
            ) == .orderedSame
                && $0.tool == tool
        }
        savedAILaunchProfiles.append(
            AILaunchProfile(
                name: trimmedName,
                tool: tool,
                additionalArguments: additionalArguments,
                bypassPermissions: bypassPermissions
            )
        )
        savedAILaunchProfiles.sort {
            $0.name.localizedStandardCompare($1.name)
                == .orderedAscending
        }
        try persistAILaunchProfiles()
    }

    func deleteAILaunchProfile(_ profile: AILaunchProfile) {
        savedAILaunchProfiles.removeAll {
            $0.id == profile.id
        }
        do {
            try persistAILaunchProfiles()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func aiLaunchProfiles(
        for tool: TerminalLaunchProfile
    ) -> [AILaunchProfile] {
        savedAILaunchProfiles.filter { $0.tool == tool }
    }

    func preferredTerminalWorkingDirectory()
        -> TerminalWorkingDirectory?
    {
        guard let hostID = activeDevice?.hostID else {
            return nil
        }
        return terminalWorkingDirectoryHistory.preferredDirectory(
            for: hostID
        )
    }

    func recentTerminalWorkingDirectories()
        -> [TerminalWorkingDirectory]
    {
        guard
            hasLoadedRemoteFileRoots,
            let hostID = activeDevice?.hostID
        else {
            return []
        }
        return terminalWorkingDirectoryHistory.recentDirectories(
            for: hostID
        )
    }

    func rememberTerminalWorkingDirectory(
        path: String,
        name: String
    ) throws {
        guard let hostID = activeDevice?.hostID else {
            throw ClientModelError.notConnected
        }
        var updatedHistory = terminalWorkingDirectoryHistory
        updatedHistory.remember(
            TerminalWorkingDirectory(
                path: path,
                name: name
            ),
            for: hostID
        )
        try persistTerminalWorkingDirectoryHistory(updatedHistory)
        terminalWorkingDirectoryHistory = updatedHistory
    }

    func preferTerminalSessionWorkspace() throws {
        guard let hostID = activeDevice?.hostID else {
            throw ClientModelError.notConnected
        }
        var updatedHistory = terminalWorkingDirectoryHistory
        updatedHistory.preferSessionWorkspace(for: hostID)
        try persistTerminalWorkingDirectoryHistory(updatedHistory)
        terminalWorkingDirectoryHistory = updatedHistory
    }

    func preparePairing(payload: String) {
        let candidate = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            pendingPairingDescriptor = try PairingDescriptor(
                payload: candidate
            )
        } catch {
            pendingPairingDescriptor = nil
            alertMessage = error.localizedDescription
        }
    }

    func cancelPairingConfirmation() {
        pendingPairingDescriptor = nil
    }

    func confirmPairing() {
        guard let descriptor = pendingPairingDescriptor else {
            return
        }
        pendingPairingDescriptor = nil
        guard Date() < descriptor.expiresAt else {
            alertMessage = ReLandSecurityError.expiredPairingCode.localizedDescription
            return
        }
        do {
            let newCredential = try PSKCredential.generate(
                name: UIDevice.current.name
            )
            let pairingSession = try RemoteClientSession(
                address: descriptor.address,
                port: descriptor.port,
                credential: descriptor.credential,
                mode: .pair(newDeviceCredential: newCredential)
            )
            configureCallbacks(
                for: pairingSession,
                pairingDescriptor: descriptor
            )
            session = pairingSession
            connectionState = .pairing
            pairingSession.connect()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func connect(
        to device: RemoteDevice,
        terminalOnly: Bool = false,
        appOnly: Bool = false
    ) {
        guard !terminalOnly || device.supports(.terminal) else {
            alertMessage = "Terminal sessions are not available on this computer."
            return
        }
        guard !appOnly || device.supports(.captureTargets) else {
            alertMessage = "App selection is not available on this computer."
            return
        }
        do {
            guard PrivateNetworkPolicy.allows(device.address) else {
                throw ClientModelError.untrustedNetworkAddress
            }
            guard let credential = try deviceStore.credential(for: device) else {
                throw ClientModelError.missingCredential
            }
            isTerminalOnlyMode = terminalOnly
            openTerminalAfterConnect = terminalOnly
            pendingCaptureIntent = terminalOnly
                ? nil
                : (appOnly ? .app : .screen)
            isAppMode = appOnly
            if appOnly {
                isDirectTouchEnabled = true
                isDragEnabled = false
            }
            startSession(device: device, credential: credential)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func disconnect() {
        manualDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        session?.disconnect()
        session = nil
        activeDevice = nil
        activeCredential = nil
        isRemoteSessionPresented = false
        connectionState = .idle
        keyboardModifiers.removeAll()
        remoteImage = nil
        frameCount = 0
        terminalSessions = []
        attachedTerminalSessionID = nil
        pendingTerminalAttachmentSessionID = nil
        isTerminalAttachmentReady = false
        pendingTerminalCreationRequestID = nil
        pendingTerminalCreationRequest = nil
        pendingTerminalCreationExistingIDs = nil
        pendingTerminalCreationWasSent = false
        pendingTerminalCreationIsReconciling = false
        pendingWorkingDirectoryPreference = nil
        terminalCreationTimeoutTask?.cancel()
        terminalCreationTimeoutTask = nil
        terminalCreationState = .idle
        negotiatedProtocolVersion = nil
        negotiatedCapabilities = []
        resetTerminalArtifacts()
        resetRemoteFiles()
        captureTargets = []
        selectedCaptureTarget = nil
        hostPermissionState = nil
        isCaptureTargetPickerPresented = false
        isAppMode = false
        isAppSwitcherVisible = false
        appSwitcherHideTask?.cancel()
        appSwitcherHideTask = nil
        pendingCaptureCycleDirection = nil
        cyclingCaptureTargetID = nil
        captureTargetHistory = CaptureTargetHistory()
        pendingCaptureIntent = nil
        isControllerTakeoverConfirmationPresented = false
        isTerminalWorkspacePresented = false
        pendingTerminalOutput.removeAll()
        isTerminalOnlyMode = false
        openTerminalAfterConnect = false
        refreshTerminalSessionsAfterReconnect = false
    }

    func remove(_ device: RemoteDevice) {
        do {
            try deviceStore.remove(device)
            devices = deviceStore.loadDevices()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func update(
        _ device: RemoteDevice,
        address: String,
        port: UInt16
    ) {
        var updated = device
        updated.address = address
        updated.port = port
        do {
            try deviceStore.update(updated)
            devices = deviceStore.loadDevices()
            editingDevice = nil
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func send(_ input: RemoteInputEvent) {
        guard canSendRemoteInput else {
            alertMessage = "Connect to an unlocked computer before sending input."
            return
        }
        session?.send(input: input)
    }

    func sendClick(button: MouseButton = .left, clickCount: Int = 1) {
        send(.button(button: button, isDown: true, clickCount: clickCount))
        send(.button(button: button, isDown: false, clickCount: clickCount))
    }

    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard !text.isEmpty else {
            alertMessage = "Enter text to send."
            return false
        }
        guard canSendRemoteInput else {
            alertMessage = "Connect to an unlocked computer before sending text."
            return false
        }
        if hostPlatform == .windows,
           text.utf16.count > 4_096 || text.contains("\0")
        {
            alertMessage = "Send up to 4096 characters at a time, without null characters."
            return false
        }
        if keyboardModifierFlags == 0 {
            send(.text(text))
            return true
        }
        if hostPlatform == .windows,
           text.lowercased().contains(where: { Self.virtualKeyCode(for: $0) == nil })
        {
            alertMessage = "Clear keyboard modifiers before sending this text."
            return false
        }

        let modifiers = keyboardModifierFlags
        for character in text.lowercased() {
            guard let code = Self.virtualKeyCode(for: character) else {
                continue
            }
            send(
                .key(
                    code: code,
                    isDown: true,
                    modifiers: modifiers
                )
            )
            send(
                .key(
                    code: code,
                    isDown: false,
                    modifiers: modifiers
                )
            )
        }
        keyboardModifiers.removeAll()
        return true
    }

    func toggle(_ modifier: KeyboardModifier) {
        if keyboardModifiers.contains(modifier) {
            keyboardModifiers.remove(modifier)
        } else {
            keyboardModifiers.insert(modifier)
        }
    }

    func sendKey(_ code: UInt16) {
        let modifiers = keyboardModifierFlags
        send(.key(code: code, isDown: true, modifiers: modifiers))
        send(.key(code: code, isDown: false, modifiers: modifiers))
        keyboardModifiers.removeAll()
    }

    func requestE2EDisconnect() {
        guard isE2EMode else {
            return
        }
        send(.text("__RELAND_DISCONNECT__"))
    }

    func requestE2EDelayedDisconnect() {
        guard isE2EMode else {
            return
        }
        send(.text("__RELAND_DELAYED_DISCONNECT__"))
    }

    func openTerminalWorkspace() {
        guard requireCapability(.terminal) else {
            return
        }
        isTerminalOnlyMode = false
        presentTerminalWorkspace()
    }

    private func presentTerminalWorkspace() {
        isTerminalWorkspacePresented = true
        requestTerminalSessions()
    }

    func closeTerminalWorkspace() {
        let shouldDisconnect = isTerminalOnlyMode
        detachTerminal()
        isTerminalWorkspacePresented = false
        refreshTerminalSessionsAfterReconnect = false
        if shouldDisconnect {
            disconnect()
        }
    }

    func requestTerminalSessions() {
        if !canUseRemoteSession,
           supports(.terminal),
           activeDevice != nil,
           !manualDisconnect
        {
            refreshTerminalSessionsAfterReconnect = true
            return
        }
        guard requireCapability(.terminal) else {
            return
        }
        refreshTerminalSessionsAfterReconnect = false
        session?.requestTerminalSessions()
    }

    func prepareTerminalCreation() {
        guard !terminalCreationState.isSubmitting else {
            return
        }
        pendingTerminalCreationRequest = nil
        pendingTerminalCreationExistingIDs = nil
        pendingTerminalCreationWasSent = false
        pendingTerminalCreationIsReconciling = false
        pendingWorkingDirectoryPreference = nil
        terminalCreationState = .idle
    }

    func clearTerminalCreationResult() {
        guard !terminalCreationState.isSubmitting else {
            return
        }
        pendingTerminalCreationRequest = nil
        pendingTerminalCreationExistingIDs = nil
        pendingTerminalCreationWasSent = false
        pendingTerminalCreationIsReconciling = false
        pendingWorkingDirectoryPreference = nil
        terminalCreationState = .idle
    }

    func createTerminalSession(
        preferredName: String? = nil,
        launchProfile: TerminalLaunchProfile = .shell,
        launchArguments: [String] = [],
        workingDirectoryPath: String? = nil,
        workingDirectoryName: String? = nil
    ) {
        guard
            connectionState == .connected,
            let activeSession = session
        else {
            terminalCreationState = .failed(
                "Reconnect to the Mac before creating a terminal."
            )
            return
        }

        if let workingDirectoryPath {
            pendingWorkingDirectoryPreference = .directory(
                TerminalWorkingDirectory(
                    path: workingDirectoryPath,
                    name: workingDirectoryName
                        ?? workingDirectoryPath
                )
            )
        } else {
            pendingWorkingDirectoryPreference =
                .sessionWorkspace
        }
        let requestID = UUID()
        pendingTerminalCreationRequestID = requestID
        pendingTerminalCreationRequest =
            PendingTerminalCreationRequest(
                requestID: requestID,
                preferredName: preferredName,
                launchProfile: launchProfile,
                launchArguments: launchArguments,
                workingDirectoryPath: workingDirectoryPath
            )
        pendingTerminalCreationExistingIDs = nil
        pendingTerminalCreationWasSent = false
        pendingTerminalCreationIsReconciling = false
        terminalCreationState = .submitting
        startTerminalCreationTimeout(requestID: requestID)
        activeSession.requestTerminalSessions()
    }

    private func sendPendingTerminalCreation() {
        guard
            terminalCreationState.isSubmitting,
            let request = pendingTerminalCreationRequest,
            let activeSession = session
        else {
            return
        }
        pendingTerminalCreationWasSent = true
        activeSession.createTerminalSession(
            requestID: request.requestID,
            preferredName: request.preferredName,
            launchProfile: request.launchProfile,
            launchArguments: request.launchArguments,
            workingDirectoryPath: request.workingDirectoryPath
        ) { [weak self, weak activeSession] result in
            Task { @MainActor in
                guard
                    let self,
                    self.session === activeSession,
                    self.pendingTerminalCreationRequestID
                        == request.requestID
                else {
                    return
                }
                if case let .failure(error) = result {
                    self.failTerminalCreation(
                        message: error.localizedDescription,
                        requestID: request.requestID
                    )
                }
            }
        }
    }

    private func startTerminalCreationTimeout(requestID: UUID) {
        terminalCreationTimeoutTask?.cancel()
        terminalCreationTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard let self else {
                return
            }
            if self.pendingTerminalCreationWasSent {
                self.beginTerminalCreationReconciliation(
                    requestID: requestID
                )
            } else {
                self.failTerminalCreation(
                    message:
                        "The Mac did not prepare terminal creation. "
                        + "Check the connection and try again.",
                    requestID: requestID
                )
            }
        }
    }

    private func beginTerminalCreationReconciliation(
        requestID: UUID
    ) {
        guard
            terminalCreationState.isSubmitting,
            pendingTerminalCreationRequestID == requestID
        else {
            return
        }
        pendingTerminalCreationIsReconciling = true
        terminalCreationTimeoutTask?.cancel()
        terminalCreationTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard let self else {
                return
            }
            failTerminalCreation(
                message:
                    "The Mac did not confirm terminal creation. "
                    + "Refresh the terminal list before retrying.",
                requestID: requestID
            )
        }
        session?.requestTerminalSessions()
    }

    private func preserveTerminalCreationForReconnect() {
        guard terminalCreationState.isSubmitting else {
            return
        }
        terminalCreationTimeoutTask?.cancel()
        terminalCreationTimeoutTask = nil
        pendingTerminalCreationIsReconciling =
            pendingTerminalCreationWasSent
    }

    private func completeTerminalCreation(
        with sessionInfo: TerminalSessionInfo,
        requestID: UUID
    ) {
        guard
            terminalCreationState.isSubmitting,
            pendingTerminalCreationRequestID == requestID
        else {
            return
        }
        terminalCreationTimeoutTask?.cancel()
        terminalCreationTimeoutTask = nil
        pendingTerminalCreationRequestID = nil
        pendingTerminalCreationRequest = nil
        pendingTerminalCreationExistingIDs = nil
        pendingTerminalCreationWasSent = false
        pendingTerminalCreationIsReconciling = false
        commitPendingWorkingDirectoryPreference()
        terminalCreationState = .succeeded
        attachTerminal(sessionInfo)
    }

    private func failTerminalCreation(
        message: String,
        requestID: UUID? = nil
    ) {
        guard terminalCreationState.isSubmitting else {
            return
        }
        if let requestID,
           pendingTerminalCreationRequestID != requestID
        {
            return
        }
        terminalCreationTimeoutTask?.cancel()
        terminalCreationTimeoutTask = nil
        pendingTerminalCreationRequestID = nil
        pendingTerminalCreationRequest = nil
        pendingTerminalCreationExistingIDs = nil
        pendingTerminalCreationWasSent = false
        pendingTerminalCreationIsReconciling = false
        pendingWorkingDirectoryPreference = nil
        terminalCreationState = .failed(message)
    }

    private func commitPendingWorkingDirectoryPreference() {
        guard let preference = pendingWorkingDirectoryPreference else {
            return
        }
        pendingWorkingDirectoryPreference = nil
        do {
            switch preference {
            case let .directory(directory):
                try rememberTerminalWorkingDirectory(
                    path: directory.path,
                    name: directory.name
                )
            case .sessionWorkspace:
                try preferTerminalSessionWorkspace()
            }
        } catch {
            terminalSecurityNotice =
                "The terminal was created, but ReLand could not "
                + "remember its working folder."
        }
    }

    private func requestPendingTerminalAttachment() {
        guard
            connectionState == .connected,
            let session,
            let sessionID = pendingTerminalAttachmentSessionID
        else {
            return
        }
        session.attachTerminal(
            sessionID: sessionID,
            columns: terminalColumns,
            rows: terminalRows
        )
    }

    @discardableResult
    func attachTerminal(
        _ sessionInfo: TerminalSessionInfo,
        columns: Int = 80,
        rows: Int = 24
    ) -> Bool {
        guard
            connectionState == .connected,
            let session
        else {
            alertMessage =
                "Reconnect to the Mac before opening a terminal."
            return false
        }
        terminalColumns = max(1, columns)
        terminalRows = max(1, rows)
        pendingTerminalOutput.removeAll()
        terminalOutputPreview = ""
        resetTerminalArtifacts()
        pendingTerminalAttachmentSessionID = sessionInfo.id
        isTerminalAttachmentReady = false
        session.attachTerminal(
            sessionID: sessionInfo.id,
            columns: terminalColumns,
            rows: terminalRows
        )
        return true
    }

    func detachTerminal() {
        session?.detachTerminal()
        pendingTerminalAttachmentSessionID = nil
        attachedTerminalSessionID = nil
        isTerminalAttachmentReady = false
        terminalOutputConsumer = nil
        pendingTerminalOutput.removeAll()
        resetTerminalArtifacts()
    }

    @discardableResult
    func openTerminalOnMac(
        _ sessionInfo: TerminalSessionInfo
    ) -> Bool {
        guard canPerformTerminalActions, let session else {
            terminalSecurityNotice =
                "Reconnect to the Mac before opening this terminal."
            return false
        }
        session.openTerminalOnMac(sessionID: sessionInfo.id)
        return true
    }

    func renameTerminal(
        _ sessionInfo: TerminalSessionInfo,
        name: String
    ) {
        guard
            connectionState == .connected,
            supportsTerminalRename,
            let session
        else {
            terminalSecurityNotice =
                connectionState == .connected
                ? "Update ReLand Host to rename terminals."
                : "Reconnect to the Mac before renaming this terminal."
            return
        }
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !trimmedName.isEmpty,
            trimmedName.count
                <= ReLandConstants.maximumTerminalNameLength
        else {
            terminalSecurityNotice =
                "Terminal names must be 1–"
                + "\(ReLandConstants.maximumTerminalNameLength) "
                + "characters."
            return
        }
        session.renameTerminalSession(
            sessionID: sessionInfo.id,
            name: trimmedName
        )
    }

    @discardableResult
    func killTerminal(
        _ sessionInfo: TerminalSessionInfo
    ) -> Bool {
        guard canPerformTerminalActions, let session else {
            terminalSecurityNotice =
                "Reconnect to the Mac before stopping this terminal."
            return false
        }
        session.killTerminalSession(sessionID: sessionInfo.id)
        return true
    }

    func sendTerminalInput(_ data: Data) {
        guard
            connectionState == .connected,
            isTerminalAttachmentReady
        else {
            return
        }
        session?.sendTerminalInput(data)
    }

    func requestOpenTerminalLink(_ value: String) {
        let policy = TerminalContentPolicy(
            allowsClipboardWrites: allowsTerminalClipboardWrites
        )
        guard let url = policy.externalURL(from: value) else {
            terminalSecurityNotice =
                "ReLand blocked a terminal link with an unsafe scheme."
            return
        }
        pendingTerminalExternalURL = url
    }

    func confirmOpenTerminalLink() {
        guard let url = pendingTerminalExternalURL else {
            return
        }
        pendingTerminalExternalURL = nil
        UIApplication.shared.open(url)
    }

    func cancelOpenTerminalLink() {
        pendingTerminalExternalURL = nil
    }

    func handleTerminalClipboardCopy(_ content: Data) {
        let policy = TerminalContentPolicy(
            allowsClipboardWrites: allowsTerminalClipboardWrites
        )
        guard let value = policy.clipboardText(from: content) else {
            terminalSecurityNotice = allowsTerminalClipboardWrites
                ? "ReLand blocked invalid or oversized terminal clipboard content."
                : "Terminal clipboard writes are disabled in ReLand Settings."
            return
        }
        UIPasteboard.general.string = value
        terminalSecurityNotice = "Copied terminal content to the clipboard."
    }

    var artifactStorageInstruction: String {
        """
        For this ReLand terminal session, whenever I ask you to create a screenshot, recording, report, log, or other file that I may want to inspect on my phone, save or publish the completed file in `$RELAND_ARTIFACTS_DIR`. If the file already exists elsewhere, run `reland-ai artifact add "<path>"`. Use a descriptive filename, confirm the published filename, and never publish credentials, pairing codes, tokens, private keys, or unrelated personal files.
        """
    }

    func sendArtifactStorageInstruction() {
        guard attachedTerminalSessionID != nil else {
            alertMessage =
                "Attach to a terminal before sending the artifact instruction."
            return
        }
        sendTerminalInput(
            Data((artifactStorageInstruction + "\r").utf8)
        )
    }

    func copyArtifactStorageInstruction() {
        UIPasteboard.general.string = artifactStorageInstruction
        terminalSecurityNotice =
            "Copied the ReLand artifact instruction."
    }

    func resizeTerminal(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else {
            return
        }
        terminalColumns = columns
        terminalRows = rows
        session?.resizeTerminal(
            columns: terminalColumns,
            rows: terminalRows
        )
    }

    func prepareTerminalArtifacts(sessionID: String) {
        guard terminalArtifactSessionID != sessionID else {
            return
        }
        resetTerminalArtifacts()
        terminalArtifactSessionID = sessionID
    }

    @discardableResult
    func requestTerminalArtifacts(
        sessionID: String
    ) -> Bool {
        prepareTerminalArtifacts(sessionID: sessionID)
        guard canPerformTerminalActions, let session else {
            isLoadingTerminalArtifacts = false
            alertMessage =
                TerminalArtifactDownloadError.notConnected
                    .localizedDescription
            return false
        }
        isLoadingTerminalArtifacts = true
        session.requestTerminalArtifacts(sessionID: sessionID)
        return true
    }

    func downloadTerminalArtifact(
        _ artifact: TerminalArtifactInfo
    ) {
        do {
            cancelTerminalArtifactDownload()
            guard
                artifact.byteCount >= 0,
                artifact.byteCount
                    <= ReLandConstants.maximumArtifactSize
            else {
                throw TerminalArtifactDownloadError.invalidMetadata
            }
            let fileURL = try artifactCacheURL(for: artifact)
            terminalArtifactDownload = TerminalArtifactDownload(
                info: artifact,
                writer: try ChunkedDownloadWriter(
                    fileURL: fileURL,
                    expectedByteCount: artifact.byteCount,
                    maximumByteCount:
                        ReLandConstants.maximumArtifactSize
                )
            )
            terminalArtifactDownloadProgress = 0
            requestNextArtifactChunk()
        } catch {
            failTerminalArtifactDownload(error)
        }
    }

    func openRemoteFileBrowser() {
        guard requestRemoteFiles(path: "") else {
            return
        }
        isRemoteFileBrowserPresented = true
    }

    func openCaptureTargetPicker() {
        guard requireCapability(.captureTargets) else {
            return
        }
        isCaptureTargetPickerPresented = true
        requestCaptureTargets()
    }

    func requestCaptureTargets() {
        guard requireCapability(.captureTargets) else {
            return
        }
        session?.requestCaptureTargets()
    }

    func requestHostStatus() {
        guard requireCapability(.hostStatus) else {
            return
        }
        session?.requestHostStatus()
    }

    func openMacScreenForPermission() {
        pendingCaptureIntent = .screen
        requestCaptureTargets()
    }

    func selectCaptureTarget(
        _ target: RemoteCaptureTargetInfo
    ) {
        if target.kind == .window {
            captureTargetHistory.recordExplicitSelection(
                id: target.id
            )
            showAppSwitcher()
        }
        session?.selectCaptureTarget(id: target.id)
    }

    func cycleCaptureTarget(
        direction: CaptureCycleDirection
    ) {
        guard isAppMode else {
            return
        }
        pendingCaptureCycleDirection = direction
        showAppSwitcher()
        requestCaptureTargets()
    }

    func showAppSwitcher() {
        guard isAppMode else {
            return
        }
        isAppSwitcherVisible = true
        appSwitcherHideTask?.cancel()
        guard !isAppSwitcherPinned else {
            appSwitcherHideTask = nil
            return
        }
        appSwitcherHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else {
                return
            }
            self?.isAppSwitcherVisible = false
        }
    }

    func closeRemoteFileBrowser() {
        isRemoteFileBrowserPresented = false
        remoteFilePreview = nil
    }

    @discardableResult
    func requestRemoteFiles(path: String) -> Bool {
        if path.isEmpty {
            remoteFilePath = ""
            remoteFileParentPath = nil
            remoteFiles = []
            remoteFileRootNames = [:]
            hasLoadedRemoteFileRoots = false
        }
        guard requireCapability(.files), canUseRemoteSession, let session else {
            isLoadingRemoteFiles = false
            return false
        }
        isLoadingRemoteFiles = true
        session.requestFiles(path: path)
        return true
    }

    private func requireCapability(_ capability: RemoteCapability) -> Bool {
        guard canUseRemoteSession else {
            alertMessage = "Reconnect to your computer before using this control."
            return false
        }
        guard supports(capability) else {
            switch capability {
            case .terminal, .artifacts:
                alertMessage = "Terminal sessions are not available on this computer."
            case .files:
                alertMessage = "File browsing is not available on this computer."
            case .captureTargets:
                alertMessage = "App selection is not available on this computer."
            default:
                alertMessage = "This control is not available on this computer."
            }
            return false
        }
        return true
    }

    func openRemoteFile(_ entry: RemoteFileEntry) {
        if entry.kind == .directory {
            requestRemoteFiles(path: entry.path)
        } else {
            downloadRemoteFile(entry)
        }
    }

    func navigateToParentRemoteFolder() {
        guard let remoteFileParentPath else {
            return
        }
        requestRemoteFiles(path: remoteFileParentPath)
    }

    func setTerminalOutputConsumer(
        _ consumer: ((Data) -> Void)?
    ) {
        terminalOutputConsumer = consumer
        if let consumer, !pendingTerminalOutput.isEmpty {
            consumer(pendingTerminalOutput)
            pendingTerminalOutput.removeAll()
        }
    }

    private func startSession(
        device: RemoteDevice,
        credential: PSKCredential,
        requestsControllerTakeover: Bool = false
    ) {
        reconnectTask?.cancel()
        let previousSession = session
        session = nil
        previousSession?.disconnect()
        manualDisconnect = false
        negotiatedProtocolVersion = nil
        negotiatedCapabilities = []
        hostPermissionState = nil
        if activeDevice?.hostID != device.hostID {
            remoteImage = nil
            displayInformation = nil
            frameCount = 0
            lastInputAcknowledgement = "No input sent"
            captureTargets = []
            selectedCaptureTarget = nil
        }
        activeDevice = device
        activeCredential = credential
        isRemoteSessionPresented = true
        connectionState = .connecting
        isControllerTakeoverConfirmationPresented = false

        do {
            let newSession = try RemoteClientSession(
                address: device.address,
                port: device.port,
                credential: credential,
                requestsControllerTakeover:
                    requestsControllerTakeover
            )
            configureCallbacks(for: newSession)
            session = newSession
            newSession.connect()
        } catch {
            connectionState = .failed(error.localizedDescription)
            scheduleReconnect()
        }
    }

    private func configureCallbacks(
        for clientSession: RemoteClientSession,
        pairingDescriptor: PairingDescriptor? = nil
    ) {
        clientSession.onStateChange = {
            [weak self, weak clientSession] state in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                if state != .connected {
                    self.handle(state)
                }
            }
        }
        clientSession.onRemoteError = {
            [weak self, weak clientSession] error in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                switch error.code {
                case .hostBusy:
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.isControllerTakeoverConfirmationPresented =
                        true
                case .sessionTakenOver:
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.manualDisconnect = true
                    self.failTerminalCreation(message: error.message)
                    self.alertMessage = error.message
                default:
                    if
                        error.requestKind == .terminalCreateRequest,
                        let requestID =
                            self.pendingTerminalCreationRequestID,
                        error.requestID == requestID
                    {
                        self.failTerminalCreation(
                            message: error.message,
                            requestID: requestID
                        )
                    } else if
                        error.requestKind == .terminalAttachRequest,
                        self.pendingTerminalAttachmentSessionID != nil
                    {
                        self.pendingTerminalAttachmentSessionID = nil
                        self.attachedTerminalSessionID = nil
                        self.isTerminalAttachmentReady = false
                        self.alertMessage = error.message
                    } else if
                        self.isLegacyTerminalCreationError(error)
                    {
                        self.failTerminalCreation(
                            message: error.message
                        )
                    } else {
                        self.alertMessage = error.message
                    }
                }
            }
        }
        clientSession.onSessionReady = {
            [weak self, weak clientSession] ready in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                self.negotiatedProtocolVersion =
                    ready.protocolVersion
                self.negotiatedCapabilities = ready.capabilities
                self.hostPermissionState = ready.hostPermissions
                if var device = self.activeDevice {
                    device.hostPlatform = ready.hostPlatform
                    device.capabilities = ready.capabilities
                    self.activeDevice = device
                    do {
                        try self.deviceStore.update(device)
                        self.devices = self.deviceStore.loadDevices()
                    } catch {
                        self.alertMessage = "ReLand could not save this computer's supported controls."
                    }
                }
                self.handle(.connected)
            }
        }
        clientSession.onDisplayInformation = { [weak self, weak clientSession] information in
            Task { @MainActor in
                guard let self, self.session === clientSession else {
                    return
                }
                self.displayInformation = information
            }
        }
        clientSession.onFrame = { [weak self, weak clientSession] data in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession,
                    self.hostPermissionState?.sessionUnlocked != false,
                    self.hostPermissionState?.screenRecordingGranted != false,
                    let image = UIImage(data: data)
                else {
                    return
                }
                self.remoteImage = image
                self.frameCount += 1
            }
        }
        clientSession.onInputAcknowledgement = { [weak self, weak clientSession] acknowledgement in
            Task { @MainActor in
                guard let self, self.session === clientSession else {
                    return
                }
                self.lastInputAcknowledgement = acknowledgement.summary
            }
        }
        clientSession.onPaired = { [weak self, weak clientSession] accepted, credential in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession,
                    let pairingDescriptor
                else {
                    return
                }
                guard
                    accepted.hostID == pairingDescriptor.hostID,
                    accepted.hostPlatform == pairingDescriptor.hostPlatform
                else {
                    self.alertMessage = "The computer does not match the pairing code. Create a new code and try again."
                    return
                }
                do {
                    let device = RemoteDevice(
                        hostID: accepted.hostID,
                        name: accepted.hostName,
                        address: pairingDescriptor.address,
                        port: pairingDescriptor.port,
                        credentialID: credential.id,
                        hostPlatform: accepted.hostPlatform,
                        capabilities: accepted.capabilities ?? pairingDescriptor.capabilities
                    )
                    try self.deviceStore.save(
                        device,
                        credential: credential
                    )
                    self.devices = self.deviceStore.loadDevices()
                    self.isPairingSheetPresented = false
                    self.startSession(
                        device: device,
                        credential: credential
                    )
                } catch {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
        clientSession.onTerminalSessionList = {
            [weak self, weak clientSession] list in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                self.terminalSessions = list.sessions
                guard
                    self.terminalCreationState.isSubmitting,
                    let requestID =
                        self.pendingTerminalCreationRequestID
                else {
                    return
                }
                if
                    self.pendingTerminalCreationExistingIDs == nil
                {
                    self.pendingTerminalCreationExistingIDs =
                        Set(list.sessions.map(\.id))
                    self.pendingTerminalCreationIsReconciling = false
                    self.sendPendingTerminalCreation()
                    return
                }
                guard
                    let existingSessionIDs =
                        self.pendingTerminalCreationExistingIDs
                else {
                    return
                }
                switch list.creationMatch(
                    requestID: requestID,
                    existingSessionIDs: existingSessionIDs,
                    allowsLegacyFallback:
                        self.pendingTerminalCreationIsReconciling
                        || !self.supportsTerminalCreationCorrelation
                ) {
                case let .created(created):
                    self.completeTerminalCreation(
                        with: created,
                        requestID: requestID
                    )
                case .invalidResponse:
                    self.failTerminalCreation(
                        message:
                            "The Mac created the terminal but did "
                            + "not return its session details.",
                        requestID: requestID
                    )
                case .ambiguous:
                    self.failTerminalCreation(
                        message:
                            "Multiple terminals appeared while creating "
                            + "this session. Refresh and choose the "
                            + "terminal you want.",
                        requestID: requestID
                    )
                case .pending:
                    break
                }
            }
        }
        clientSession.onTerminalAttached = {
            [weak self, weak clientSession] attached in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                self.pendingTerminalAttachmentSessionID = nil
                self.attachedTerminalSessionID = attached.sessionID
                self.isTerminalAttachmentReady = true
            }
        }
        clientSession.onTerminalOutput = {
            [weak self, weak clientSession] data in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                self.receiveTerminalOutput(data)
            }
        }
        clientSession.onTerminalDetached = {
            [weak self, weak clientSession] in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                self.pendingTerminalAttachmentSessionID = nil
                self.attachedTerminalSessionID = nil
                self.isTerminalAttachmentReady = false
            }
        }
        clientSession.onTerminalArtifacts = {
            [weak self, weak clientSession] response in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession,
                    response.sessionID
                        == self.terminalArtifactSessionID
                else {
                    return
                }
                self.terminalArtifacts = response.artifacts
                self.isLoadingTerminalArtifacts = false
            }
        }
        clientSession.onTerminalArtifactChunk = {
            [weak self, weak clientSession] chunk in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                self.receiveTerminalArtifactChunk(chunk)
            }
        }
        clientSession.onFiles = {
            [weak self, weak clientSession] response in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                self.remoteFilePath = response.path
                self.remoteFileParentPath = response.parentPath
                self.remoteFiles = response.entries
                if response.path.isEmpty {
                    self.remoteFileRootNames = Dictionary(
                        uniqueKeysWithValues: response.entries.map {
                            ($0.path, $0.name)
                        }
                    )
                    self.reconcileTerminalWorkingDirectoryHistory()
                    self.hasLoadedRemoteFileRoots = true
                }
                self.isLoadingRemoteFiles = false
            }
        }
        clientSession.onFileChunk = {
            [weak self, weak clientSession] chunk in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                self.receiveRemoteFileChunk(chunk)
            }
        }
        clientSession.onCaptureTargets = { [weak self, weak clientSession] response in
            Task { @MainActor in
                guard let self, self.session === clientSession else {
                    return
                }
                self.captureTargets = response.targets
                self.selectedCaptureTarget =
                    response.targets.first(where: {
                        $0.id == response.selectedTargetID
                    })
                let windows = response.targets.filter {
                    $0.kind == .window
                }
                self.captureTargetHistory.prune(
                    availableIDs: windows.map(\.id)
                )
                switch self.pendingCaptureIntent {
                case .screen:
                    if
                        let display = response.targets.first(where: {
                            $0.kind == .display
                        }),
                        display.id != response.selectedTargetID
                    {
                        self.selectCaptureTarget(display)
                    }
                    self.pendingCaptureIntent = nil
                case .app:
                    self.isCaptureTargetPickerPresented = true
                    self.pendingCaptureIntent = nil
                case nil:
                    break
                }
                if
                    let direction =
                        self.pendingCaptureCycleDirection,
                    let targetID =
                        self.captureTargetHistory.targetID(
                            from: self.selectedCaptureTarget?.id,
                            direction: direction,
                            availableIDs: windows.map(\.id)
                        ),
                    targetID != self.selectedCaptureTarget?.id
                {
                    self.pendingCaptureCycleDirection = nil
                    self.cyclingCaptureTargetID = targetID
                    self.session?.selectCaptureTarget(id: targetID)
                } else {
                    self.pendingCaptureCycleDirection = nil
                }
            }
        }
        clientSession.onCaptureTargetSelected = {
            [weak self, weak clientSession] selected in
            Task { @MainActor in
                guard let self, self.session === clientSession else {
                    return
                }
                self.selectedCaptureTarget = selected.target
                self.displayInformation =
                    selected.displayInformation
                self.isAppMode = selected.target.kind == .window
                if self.isAppMode {
                    if
                        self.cyclingCaptureTargetID
                            != selected.target.id
                    {
                        self.captureTargetHistory
                            .recordExplicitSelection(
                                id: selected.target.id
                            )
                    }
                    self.cyclingCaptureTargetID = nil
                    self.showAppSwitcher()
                    self.isDirectTouchEnabled = true
                    self.isDragEnabled = false
                } else {
                    self.isAppSwitcherVisible = false
                    self.appSwitcherHideTask?.cancel()
                    self.appSwitcherHideTask = nil
                }
                self.captureTargetRevision += 1
                self.isCaptureTargetPickerPresented = false
            }
        }
        clientSession.onHostPermissionState = {
            [weak self, weak clientSession] state in
            Task { @MainActor in
                guard
                    let self,
                    self.session === clientSession
                else {
                    return
                }
                self.hostPermissionState = state
                if !state.sessionUnlocked || !state.screenRecordingGranted {
                    self.remoteImage = nil
                }
            }
        }
    }

    private func isLegacyTerminalCreationError(
        _ error: RemoteErrorMessage
    ) -> Bool {
        guard
            terminalCreationState.isSubmitting,
            negotiatedProtocolVersion.map({
                $0 < ReLandConstants
                    .minimumTerminalCreationCorrelationProtocolVersion
            }) == true,
            error.requestKind == nil,
            error.requestID == nil
        else {
            return false
        }
        switch error.code {
        case .terminalUnavailable, .internalError:
            return true
        default:
            return false
        }
    }

    private func handle(_ state: RemoteClientSession.State) {
        switch state {
        case .idle:
            connectionState = .idle
        case .connecting:
            connectionState = .connecting
        case .authenticating:
            connectionState = .authenticating
        case .pairing:
            connectionState = .pairing
        case .connected:
            reconnectTask?.cancel()
            reconnectTask = nil
            isControllerTakeoverConfirmationPresented = false
            connectionState = .connected
            if !supports(.captureTargets) {
                if isAppMode {
                    alertMessage = "App selection is not available on this computer."
                }
                pendingCaptureIntent = nil
                isAppMode = false
                isCaptureTargetPickerPresented = false
                isAppSwitcherVisible = false
            }
            if !supports(.terminal) {
                refreshTerminalSessionsAfterReconnect = false
                if openTerminalAfterConnect {
                    disconnect()
                    alertMessage = "Terminal sessions are not available on this computer."
                    return
                }
                isTerminalWorkspacePresented = false
                pendingTerminalAttachmentSessionID = nil
                attachedTerminalSessionID = nil
                isTerminalAttachmentReady = false
                if terminalCreationState.isSubmitting {
                    failTerminalCreation(message: "Terminal sessions are not available on this computer.")
                }
            }
            requestPendingTerminalAttachment()
            if
                terminalCreationState.isSubmitting,
                let requestID = pendingTerminalCreationRequestID
            {
                if pendingTerminalCreationWasSent {
                    beginTerminalCreationReconciliation(
                        requestID: requestID
                    )
                } else {
                    startTerminalCreationTimeout(
                        requestID: requestID
                    )
                    requestTerminalSessions()
                }
            }
            if openTerminalAfterConnect {
                openTerminalAfterConnect = false
                presentTerminalWorkspace()
                return
            }
            if pendingCaptureIntent != nil {
                requestCaptureTargets()
            }
            if isTerminalWorkspacePresented || refreshTerminalSessionsAfterReconnect {
                requestTerminalSessions()
            }
        case .waiting:
            connectionState = .reconnecting
            negotiatedProtocolVersion = nil
            negotiatedCapabilities = []
            preserveTerminalAttachmentForReconnect()
            preserveTerminalCreationForReconnect()
        case let .failed(message):
            connectionState = .failed(message)
            negotiatedProtocolVersion = nil
            negotiatedCapabilities = []
            preserveTerminalAttachmentForReconnect()
            preserveTerminalCreationForReconnect()
            scheduleReconnect()
        case .disconnected:
            negotiatedProtocolVersion = nil
            negotiatedCapabilities = []
            preserveTerminalAttachmentForReconnect()
            preserveTerminalCreationForReconnect()
            if manualDisconnect {
                connectionState = .idle
            } else if activeDevice != nil {
                connectionState = .reconnecting
                scheduleReconnect()
            }
        }
    }

    private func preserveTerminalAttachmentForReconnect() {
        guard let attachedTerminalSessionID else {
            return
        }
        pendingTerminalAttachmentSessionID =
            attachedTerminalSessionID
        isTerminalAttachmentReady = false
    }

    private func scheduleReconnect() {
        guard
            !manualDisconnect,
            !isControllerTakeoverConfirmationPresented,
            reconnectTask == nil,
            let activeDevice,
            let activeCredential
        else {
            return
        }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                self.reconnectTask = nil
                self.startSession(
                    device: activeDevice,
                    credential: activeCredential
                )
            }
        }
    }

    func cancelControllerTakeover() {
        isControllerTakeoverConfirmationPresented = false
        disconnect()
    }

    func confirmControllerTakeover() {
        guard let activeDevice, let activeCredential else {
            isControllerTakeoverConfirmationPresented = false
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        session?.disconnect()
        startSession(
            device: activeDevice,
            credential: activeCredential,
            requestsControllerTakeover: true
        )
    }

    #if DEBUG
    private func configureE2ESession(arguments: [String]) {
        let host = arguments.value(after: "--e2e-host") ?? "127.0.0.1"
        let port = UInt16(
            arguments.value(after: "--e2e-port") ?? ""
        ) ?? ReLandConstants.defaultPort
        let key = Data((0..<32).map(UInt8.init))
        do {
            let credential = try PSKCredential(
                id: "reland-e2e-device",
                key: key,
                name: "iOS Simulator"
            )
            let device = RemoteDevice(
                id: "reland-e2e-device",
                hostID: "reland-e2e-host",
                name: "ReLand E2E Host",
                address: host,
                port: port,
                credentialID: credential.id
            )
            pendingCaptureIntent = .screen
            isAppMode = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.startSession(device: device, credential: credential)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }
    #endif

    private var keyboardModifierFlags: UInt64 {
        keyboardModifiers.reduce(0) { result, modifier in
            result | modifier.flag
        }
    }

    private static func virtualKeyCode(for character: Character) -> UInt16? {
        let mapping: [Character: UInt16] = [
            "a": 0,
            "s": 1,
            "d": 2,
            "f": 3,
            "h": 4,
            "g": 5,
            "z": 6,
            "x": 7,
            "c": 8,
            "v": 9,
            "b": 11,
            "q": 12,
            "w": 13,
            "e": 14,
            "r": 15,
            "y": 16,
            "t": 17,
            "1": 18,
            "2": 19,
            "3": 20,
            "4": 21,
            "6": 22,
            "5": 23,
            "=": 24,
            "9": 25,
            "7": 26,
            "-": 27,
            "8": 28,
            "0": 29,
            "]": 30,
            "o": 31,
            "u": 32,
            "[": 33,
            "i": 34,
            "p": 35,
            "l": 37,
            "j": 38,
            "'": 39,
            "k": 40,
            ";": 41,
            "\\": 42,
            ",": 43,
            "/": 44,
            "n": 45,
            "m": 46,
            ".": 47,
            " ": 49,
        ]
        return mapping[character]
    }

    private func receiveTerminalOutput(_ data: Data) {
        let decoded = String(decoding: data, as: UTF8.self)
        terminalOutputPreview = String(
            (terminalOutputPreview + decoded).suffix(512)
        )
        if let terminalOutputConsumer {
            terminalOutputConsumer(data)
            return
        }
        pendingTerminalOutput.append(data)
        if pendingTerminalOutput.count > 1_048_576 {
            pendingTerminalOutput.removeFirst(
                pendingTerminalOutput.count - 1_048_576
            )
        }
    }

    private func cacheRootURL() -> URL {
        FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent(
            "ReLand",
            isDirectory: true
        )
    }

    private func artifactCacheURL(
        for artifact: TerminalArtifactInfo
    ) throws -> URL {
        guard let activeDevice else {
            throw TerminalArtifactDownloadError.cacheUnavailable
        }
        let cacheRoot = cacheRootURL()
        .appendingPathComponent(
            "TerminalArtifacts",
            isDirectory: true
        )
        let safeName = URL(
            fileURLWithPath: artifact.name
        ).lastPathComponent
        guard !safeName.isEmpty else {
            throw TerminalArtifactDownloadError.invalidMetadata
        }
        return cacheRoot
            .appendingPathComponent(
                safePathComponent(activeDevice.hostID),
                isDirectory: true
            )
            .appendingPathComponent(
                safePathComponent(artifact.sessionID),
                isDirectory: true
            )
            .appendingPathComponent(
                safePathComponent(artifact.id),
                isDirectory: true
            )
            .appendingPathComponent(safeName)
    }

    private func safePathComponent(_ value: String) -> String {
        let sanitized = value.map { character -> Character in
            character.isLetter || character.isNumber
                || character == "-"
                || character == "_"
                ? character
                : "_"
        }
        return String(sanitized.prefix(128))
    }

    private func requestNextArtifactChunk() {
        guard let download = terminalArtifactDownload else {
            return
        }
        guard let session else {
            failTerminalArtifactDownload(
                TerminalArtifactDownloadError.notConnected
            )
            return
        }
        session.requestTerminalArtifactChunk(
            sessionID: download.info.sessionID,
            artifactID: download.info.id,
            offset: download.writer.nextOffset
        )
    }

    private func receiveTerminalArtifactChunk(
        _ chunk: TerminalArtifactChunk
    ) {
        do {
            guard
                let download = terminalArtifactDownload,
                chunk.sessionID == download.info.sessionID,
                chunk.artifactID == download.info.id,
                chunk.offset == download.writer.nextOffset
            else {
                throw TerminalArtifactDownloadError.invalidChunk
            }
            let progress = try download.writer.append(
                offset: chunk.offset,
                totalByteCount: chunk.totalByteCount,
                data: chunk.data,
                isComplete: chunk.isComplete
            )
            terminalArtifactDownloadProgress = progress.progress

            if progress.isComplete {
                terminalArtifactDownload = nil
                terminalArtifactDownloadProgress = nil
                terminalArtifactPreview = TerminalArtifactPreview(
                    info: download.info,
                    fileURL: download.writer.fileURL
                )
            } else {
                requestNextArtifactChunk()
            }
        } catch {
            failTerminalArtifactDownload(error)
        }
    }

    private func cancelTerminalArtifactDownload() {
        guard let download = terminalArtifactDownload else {
            return
        }
        do {
            try download.writer.cancel()
        } catch {
            if alertMessage == nil {
                alertMessage = error.localizedDescription
            }
        }
        terminalArtifactDownload = nil
        terminalArtifactDownloadProgress = nil
    }

    private func failTerminalArtifactDownload(_ error: Error) {
        cancelTerminalArtifactDownload()
        alertMessage = error.localizedDescription
    }

    private func resetTerminalArtifacts() {
        cancelTerminalArtifactDownload()
        terminalArtifactSessionID = nil
        terminalArtifacts = []
        isLoadingTerminalArtifacts = false
        terminalArtifactPreview = nil
    }

    private func downloadRemoteFile(_ entry: RemoteFileEntry) {
        do {
            cancelRemoteFileDownload()
            guard
                let byteCount = entry.byteCount,
                byteCount >= 0,
                byteCount
                    <= ReLandConstants.maximumArtifactSize
            else {
                throw RemoteFileDownloadError.invalidMetadata
            }
            let fileURL = try remoteFileCacheURL(for: entry)
            remoteFileDownload = RemoteFileDownload(
                entry: entry,
                writer: try ChunkedDownloadWriter(
                    fileURL: fileURL,
                    expectedByteCount: byteCount,
                    maximumByteCount:
                        ReLandConstants.maximumArtifactSize
                )
            )
            remoteFileDownloadProgress = 0
            requestNextRemoteFileChunk()
        } catch {
            failRemoteFileDownload(error)
        }
    }

    private func remoteFileCacheURL(
        for entry: RemoteFileEntry
    ) throws -> URL {
        guard let activeDevice else {
            throw RemoteFileDownloadError.cacheUnavailable
        }
        let cacheRoot = cacheRootURL()
        .appendingPathComponent(
            "RemoteFiles",
            isDirectory: true
        )
        let safeName = URL(
            fileURLWithPath: entry.name
        ).lastPathComponent
        guard !safeName.isEmpty else {
            throw RemoteFileDownloadError.invalidMetadata
        }
        let pathHash = SHA256.hash(
            data: Data(entry.path.utf8)
        )
        .map { String(format: "%02x", $0) }
        .joined()
        return cacheRoot
            .appendingPathComponent(
                safePathComponent(activeDevice.hostID),
                isDirectory: true
            )
            .appendingPathComponent(
                pathHash,
                isDirectory: true
            )
            .appendingPathComponent(safeName)
    }

    private func requestNextRemoteFileChunk() {
        guard let download = remoteFileDownload else {
            return
        }
        guard let session else {
            failRemoteFileDownload(
                RemoteFileDownloadError.notConnected
            )
            return
        }
        session.requestFileChunk(
            path: download.entry.path,
            offset: download.writer.nextOffset
        )
    }

    private func receiveRemoteFileChunk(_ chunk: RemoteFileChunk) {
        do {
            guard
                let download = remoteFileDownload,
                chunk.path == download.entry.path,
                chunk.offset == download.writer.nextOffset
            else {
                throw RemoteFileDownloadError.invalidChunk
            }
            let progress = try download.writer.append(
                offset: chunk.offset,
                totalByteCount: chunk.totalByteCount,
                data: chunk.data,
                isComplete: chunk.isComplete
            )
            remoteFileDownloadProgress = progress.progress
            if progress.isComplete {
                remoteFileDownload = nil
                remoteFileDownloadProgress = nil
                remoteFilePreview = RemoteFilePreview(
                    entry: download.entry,
                    fileURL: download.writer.fileURL
                )
            } else {
                requestNextRemoteFileChunk()
            }
        } catch {
            failRemoteFileDownload(error)
        }
    }

    private func cancelRemoteFileDownload() {
        guard let download = remoteFileDownload else {
            return
        }
        do {
            try download.writer.cancel()
        } catch {
            if alertMessage == nil {
                alertMessage = error.localizedDescription
            }
        }
        remoteFileDownload = nil
        remoteFileDownloadProgress = nil
    }

    private func failRemoteFileDownload(_ error: Error) {
        cancelRemoteFileDownload()
        alertMessage = error.localizedDescription
    }

    private func resetRemoteFiles() {
        cancelRemoteFileDownload()
        remoteFilePath = ""
        remoteFileParentPath = nil
        remoteFiles = []
        remoteFileRootNames = [:]
        hasLoadedRemoteFileRoots = false
        isLoadingRemoteFiles = false
        remoteFilePreview = nil
        isRemoteFileBrowserPresented = false
    }

    private static func boolSetting(
        _ settings: any SettingsStoring,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard let stored = settings.string(forKey: key) else {
            return defaultValue
        }
        return stored == String(true)
    }

    private func persistAILaunchProfiles() throws {
        settings.set(
            try JSONEncoder().encode(savedAILaunchProfiles),
            forKey: Self.aiLaunchProfilesKey
        )
    }

    private func persistTerminalWorkingDirectoryHistory(
        _ history: TerminalWorkingDirectoryHistory
    ) throws {
        settings.set(
            try JSONEncoder().encode(history),
            forKey: Self.terminalWorkingDirectoryHistoryKey
        )
    }

    private func reconcileTerminalWorkingDirectoryHistory() {
        guard let hostID = activeDevice?.hostID else {
            return
        }
        let approvedRoots = Set(remoteFileRootNames.keys)
        var updatedHistory = terminalWorkingDirectoryHistory
        updatedHistory.retainDirectories(for: hostID) {
            directory in
            guard
                let rootPath = Self.remoteFileRootPath(
                    for: directory.path
                )
            else {
                return false
            }
            return approvedRoots.contains(rootPath)
        }
        guard updatedHistory != terminalWorkingDirectoryHistory else {
            return
        }
        terminalWorkingDirectoryHistory = updatedHistory
        do {
            try persistTerminalWorkingDirectoryHistory(
                updatedHistory
            )
        } catch {
            terminalSecurityNotice =
                "ReLand could not update remembered project folders."
        }
    }

    private static func remoteFileRootPath(
        for path: String
    ) -> String? {
        guard path.hasPrefix("@") else {
            return nil
        }
        guard let separator = path.firstIndex(of: "/") else {
            return path
        }
        return String(path[..<separator])
    }

    private static func directoryByteCount(
        at root: URL
    ) throws -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return 0
        }
        var enumerationError: Error?
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else {
            throw ClientModelError.cacheUnavailable
        }

        var result: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                ]
            )
            if
                values.isRegularFile == true,
                let fileSize = values.fileSize
            {
                result += Int64(fileSize)
            }
        }
        if let enumerationError {
            throw enumerationError
        }
        return result
    }
}

private enum CaptureIntent {
    case screen
    case app
}

private enum ClientModelError: LocalizedError {
    case missingCredential
    case untrustedNetworkAddress
    case cacheUnavailable
    case invalidAILaunchProfile
    case notConnected

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "The saved access credential is missing. Pair this computer again."
        case .untrustedNetworkAddress:
            "ReLand only connects to private LAN or Tailscale addresses."
        case .cacheUnavailable:
            "ReLand could not inspect its download cache."
        case .invalidAILaunchProfile:
            "Enter a name for a ReLand AI launch profile."
        case .notConnected:
            "Reconnect to the Mac before changing terminal settings."
        }
    }
}

private final class TerminalArtifactDownload {
    let info: TerminalArtifactInfo
    let writer: ChunkedDownloadWriter

    init(
        info: TerminalArtifactInfo,
        writer: ChunkedDownloadWriter
    ) {
        self.info = info
        self.writer = writer
    }
}

private enum TerminalArtifactDownloadError: LocalizedError {
    case invalidMetadata
    case invalidChunk
    case cacheUnavailable
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            "The terminal artifact metadata is invalid."
        case .invalidChunk:
            "The terminal artifact transfer was interrupted."
        case .cacheUnavailable:
            "ReLand could not create the artifact cache."
        case .notConnected:
            "The Mac is not connected."
        }
    }
}

private final class RemoteFileDownload {
    let entry: RemoteFileEntry
    let writer: ChunkedDownloadWriter

    init(
        entry: RemoteFileEntry,
        writer: ChunkedDownloadWriter
    ) {
        self.entry = entry
        self.writer = writer
    }
}

private enum RemoteFileDownloadError: LocalizedError {
    case invalidMetadata
    case invalidChunk
    case cacheUnavailable
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            "The Mac file metadata is invalid."
        case .invalidChunk:
            "The Mac file transfer was interrupted."
        case .cacheUnavailable:
            "ReLand could not create the Mac file cache."
        case .notConnected:
            "The Mac is not connected."
        }
    }
}

private extension Array where Element == String {
    func value(after flag: String) -> String? {
        guard
            let index = firstIndex(of: flag),
            indices.contains(index + 1)
        else {
            return nil
        }
        return self[index + 1]
    }
}
