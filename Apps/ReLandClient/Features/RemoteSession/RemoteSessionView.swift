import ReLandCore
import SwiftUI

struct RemoteSessionView: View {
    @Bindable var model: ClientAppModel
    @State private var isKeyboardPresented = false
    @State private var textToSend = ""
    @State private var zoomScale: CGFloat = 1
    @State private var zoomOffset = CGSize.zero
    @State private var viewportSize = CGSize.zero
    @State private var remotePointer = CGPoint(x: 0.5, y: 0.5)
    @State private var isGestureGuidePresented = false
    @State private var isDisconnectConfirmationPresented = false

    var body: some View {
        ZStack {
            ReLandTheme.remoteCanvas
                .ignoresSafeArea()

            remoteDisplay

            RemoteGestureCaptureView(
                directTouch: model.isDirectTouchEnabled,
                dragEnabled: model.isDragEnabled,
                pointerSensitivity: model.pointerSensitivity,
                hapticsEnabled: model.hapticsEnabled,
                zoomScale: zoomScale,
                viewportOffset: zoomOffset,
                contentAspectRatio: contentAspectRatio,
                onZoom: updateZoom,
                onViewportPan: panViewport,
                onPointerPosition: { position in
                    remotePointer = position
                    if position.y >= 0.92 {
                        model.showAppSwitcher()
                    }
                },
                onWindowCycle: { direction in
                    if model.isThreeFingerSwitchingEnabled {
                        model.cycleCaptureTarget(
                            direction: direction
                        )
                    }
                },
                send: model.send
            )
            .accessibilityIdentifier("remoteCanvas")
            .accessibilityLabel("Remote \(model.hostPlatform.displayName) canvas")
            .accessibilityHint(
                model.isAppMode
                    ? "Use three fingers horizontally to switch recent Mac windows."
                    : "Use one finger for the pointer and two fingers to scroll."
            )
            .allowsHitTesting(model.canSendRemoteInput)

            VStack {
                RemoteSessionStatusPill(model: model, zoomScale: zoomScale)
                if needsHostAttention {
                    hostAttentionBanner
                }
                Spacer()
                if
                    model.isAppMode,
                    model.isAppSwitcherVisible
                {
                    appSwitcherStrip
                        .transition(.move(edge: .bottom).combined(
                            with: .opacity
                        ))
                }
                controlBar
            }
            .padding()
        }
        .sheet(isPresented: $isKeyboardPresented) {
            NavigationStack {
                Form {
                    Section("Pointer speed") {
                        HStack {
                            Image(systemName: "tortoise")
                                .accessibilityHidden(true)
                            Slider(
                                value: $model.pointerSensitivity,
                                in: 1...4,
                                step: 0.2
                            )
                            Image(systemName: "hare")
                                .accessibilityHidden(true)
                            Text(
                                model.pointerSensitivity,
                                format: .number.precision(
                                    .fractionLength(1)
                                )
                            )
                            .monospacedDigit()
                        }
                    }

                    Section("Modifiers") {
                        HStack {
                            ForEach(
                                ClientAppModel.KeyboardModifier.allCases
                            ) { modifier in
                                Button {
                                    model.toggle(modifier)
                                } label: {
                                    Group {
                                        if model.hostPlatform == .windows {
                                            Text(modifier.windowsLabel)
                                        } else {
                                            Image(systemName: modifier.symbol)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.bordered)
                                .tint(
                                    model.keyboardModifiers.contains(modifier)
                                        ? ReLandTheme.accent
                                        : .secondary
                                )
                                .accessibilityLabel(modifier.title(for: model.hostPlatform))
                                .disabled(!model.canSendRemoteInput)
                            }
                        }
                    }

                    Section("Special keys") {
                        HStack {
                            specialKey("Escape", label: "esc", code: 53)
                            specialKey("Tab", systemImage: "arrow.right.to.line", code: 48)
                            specialKey("Return", systemImage: "return", code: 36)
                            specialKey("Delete", systemImage: "delete.left", code: 51)
                        }
                        HStack {
                            specialKey("Left", systemImage: "arrow.left", code: 123)
                            specialKey("Right", systemImage: "arrow.right", code: 124)
                            specialKey("Down", systemImage: "arrow.down", code: 125)
                            specialKey("Up", systemImage: "arrow.up", code: 126)
                        }
                    }

                    Section("Text") {
                    TextField(
                        "Text to send",
                        text: $textToSend,
                        axis: .vertical
                    )
                    .accessibilityIdentifier("remoteTextField")
                    .lineLimit(3...8)

                    Button("Send") {
                        if model.sendText(textToSend) {
                            textToSend = ""
                            isKeyboardPresented = false
                        }
                    }
                    .disabled(textToSend.isEmpty || !model.canSendRemoteInput)
                    .accessibilityIdentifier("sendTextButton")
                    }
                }
                .navigationTitle("Keyboard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isKeyboardPresented = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .fullScreenCover(
            isPresented: $model.isTerminalWorkspacePresented
        ) {
            TerminalWorkspaceView(model: model)
        }
        .fullScreenCover(
            isPresented: $model.isRemoteFileBrowserPresented
        ) {
            RemoteFilesView(model: model)
        }
        .sheet(
            isPresented: $model.isCaptureTargetPickerPresented
        ) {
            CaptureTargetPickerView(model: model)
        }
        .onChange(of: model.captureTargetRevision) { _, _ in
            resetZoom()
            remotePointer = CGPoint(x: 0.5, y: 0.5)
        }
        .alert(
            "\(model.hostPlatform.displayName) already in use",
            isPresented:
                $model.isControllerTakeoverConfirmationPresented
        ) {
            Button("Cancel", role: .cancel) {
                model.cancelControllerTakeover()
            }
            Button("Take Over", role: .destructive) {
                model.confirmControllerTakeover()
            }
        } message: {
            Text(
                "Another paired device is controlling this \(model.hostPlatform.displayName). "
                    + "Taking over will disconnect that device."
            )
        }
        .sheet(isPresented: $isGestureGuidePresented) {
            NavigationStack {
                    List {
                        Label(
                            "One finger: move or directly touch",
                            systemImage: "hand.point.up.left"
                        )
                        Label(
                            "Two fingers: scroll",
                            systemImage: "hand.draw"
                        )
                        Label(
                            "Pinch: zoom the remote view",
                            systemImage: "arrow.up.left.and.arrow.down.right"
                        )
                        if model.supports(.captureTargets) {
                            Label(
                                "Three fingers: switch recent app windows",
                                systemImage: "rectangle.3.group"
                            )
                        }
                        Label(
                            "Long press or two-finger tap: right click",
                            systemImage: "cursorarrow.click.2"
                        )
                    }
                    .navigationTitle("Gesture Guide")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                isGestureGuidePresented = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog(
            "Disconnect from this \(model.hostPlatform.displayName)?",
            isPresented: $isDisconnectConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                    model.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var appSwitcherStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(
                    model.captureTargets.filter {
                        $0.kind == .window
                    }
                ) { target in
                    Button {
                        model.selectCaptureTarget(target)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "macwindow")
                                .accessibilityHidden(true)
                            VStack(
                                alignment: .leading,
                                spacing: 1
                            ) {
                                Text(target.applicationName)
                                    .font(
                                        .caption.weight(.semibold)
                                    )
                                Text(target.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(
                            model.selectedCaptureTarget?.id
                                == target.id
                                ? ReLandTheme.accent.opacity(0.75)
                                : ReLandTheme.controlBackground,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "appSwitcher-\(target.id)"
                    )
                }

                Button {
                    model.openCaptureTargetPicker()
                } label: {
                    Label(
                        "All Apps",
                        systemImage: "square.grid.2x2"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(
                        ReLandTheme.controlBackground,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
        .background(
            ReLandTheme.terminalOverlay,
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.24), lineWidth: 1)
        }
        .accessibilityIdentifier("appSwitcherStrip")
    }

    private var needsHostAttention: Bool {
        guard let state = model.hostPermissionState else {
            return false
        }
        return !state.screenRecordingGranted
            || !state.accessibilityGranted
            || !state.sessionUnlocked
    }

    private var hostAttentionBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                hostAttentionTitle,
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline)

            Text(hostAttentionDetail)
                .font(.subheadline)

            ViewThatFits(in: .horizontal) {
                HStack {
                    hostAttentionActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    hostAttentionActions
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            Color.orange.opacity(0.94),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hostAttentionBanner")
    }

    private var hostAttentionTitle: String {
        guard let state = model.hostPermissionState else {
            return "\(model.hostPlatform.displayName) needs attention"
        }
        if !state.sessionUnlocked {
            return "\(model.hostPlatform.displayName) is locked"
        }
        if model.hostPlatform == .windows {
            return "Windows needs attention"
        }
        if !state.screenRecordingGranted {
            return "Screen Recording is required"
        }
        return "Accessibility is required"
    }

    @ViewBuilder
    private var hostAttentionActions: some View {
        if model.supports(.captureTargets) {
            Button("Open Mac Screen") {
                model.openMacScreenForPermission()
            }
            .buttonStyle(.borderedProminent)
        }

        Button("Retry") {
            model.requestHostStatus()
        }
        .buttonStyle(.bordered)
    }

    private var hostAttentionDetail: String {
        guard let state = model.hostPermissionState else {
            return ""
        }
        if model.hostPlatform == .windows {
            return "Unlock the PC or dismiss its system prompt locally, then retry. "
                + "ReLand cannot control the Windows login screen or elevated apps."
        }
        if !state.sessionUnlocked {
            return "Unlock the Mac locally before sending input."
        }
        if !state.screenRecordingGranted {
            return "Approve ReLand Host in macOS Privacy & Security, then retry."
        }
        return "Approve Accessibility on the Mac to control pointer and keyboard input."
    }

    @ViewBuilder
    private var remoteDisplay: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = model.remoteImage {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.low)
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height
                        )
                        .scaleEffect(zoomScale)
                        .offset(zoomOffset)
                        .accessibilityHidden(true)

                    if model.isAppMode {
                        Image(systemName: "cursorarrow")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(
                                color: .black,
                                radius: 2,
                                x: 1,
                                y: 1
                            )
                            .position(
                                pointerPosition(in: proxy.size)
                            )
                            .accessibilityHidden(true)
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height
                        )
                        .accessibilityLabel(
                            "Waiting for the \(model.hostPlatform.displayName) display"
                        )
                }
            }
            .onAppear {
                viewportSize = proxy.size
            }
            .onChange(of: proxy.size) { _, newSize in
                viewportSize = newSize
                zoomOffset = clamped(offset: zoomOffset)
            }
        }
        .clipped()
    }

    private func pointerPosition(in size: CGSize) -> CGPoint {
        let bounds = CGRect(origin: .zero, size: size)
        let contentFrame = fittedContentFrame(in: bounds)
        let base = CGPoint(
            x: contentFrame.minX
                + contentFrame.width * remotePointer.x,
            y: contentFrame.minY
                + contentFrame.height * remotePointer.y
        )
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return CGPoint(
            x: (base.x - center.x) * zoomScale
                + center.x
                + zoomOffset.width,
            y: (base.y - center.y) * zoomScale
                + center.y
                + zoomOffset.height
        )
    }

    private func fittedContentFrame(in bounds: CGRect) -> CGRect {
        guard
            let contentAspectRatio,
            contentAspectRatio > 0
        else {
            return bounds
        }
        let containerAspect = bounds.width / bounds.height
        if containerAspect > contentAspectRatio {
            let width = bounds.height * contentAspectRatio
            return CGRect(
                x: bounds.midX - width / 2,
                y: bounds.minY,
                width: width,
                height: bounds.height
            )
        }
        let height = bounds.width / contentAspectRatio
        return CGRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: bounds.width,
            height: height
        )
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            Text(model.lastInputAcknowledgement)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .accessibilityIdentifier("lastInputAck")

            HStack(spacing: 4) {
                dockButton(
                    title: "End",
                    accessibilityTitle: "Disconnect",
                    systemImage: "xmark",
                    identifier: "disconnectButton",
                    tint: .red
                ) {
                    isDisconnectConfirmationPresented = true
                }
                if model.supports(.captureTargets) {
                    dockButton(
                        title: "Apps",
                        accessibilityTitle: "Mac apps",
                        systemImage: "macwindow",
                        identifier: "appsButton",
                        isActive: model.isAppMode,
                        action: model.openCaptureTargetPicker
                    )
                    .disabled(model.connectionState != .connected)
                }
                dockButton(
                    title: "Keys",
                    accessibilityTitle: "Keyboard",
                    systemImage: "keyboard",
                    identifier: "keyboardButton"
                ) {
                    isKeyboardPresented = true
                }
                .disabled(!model.canSendRemoteInput)
                if model.supports(.terminal) {
                    dockButton(
                        title: "Terminal",
                        accessibilityTitle: "Terminal sessions",
                        systemImage: "terminal",
                        identifier: "terminalButton",
                        action: model.openTerminalWorkspace
                    )
                    .disabled(model.connectionState != .connected)
                }
                if model.supports(.files) {
                    dockButton(
                        title: "Files",
                        accessibilityTitle: "Mac files",
                        systemImage: "folder",
                        identifier: "filesButton",
                        action: model.openRemoteFileBrowser
                    )
                    .disabled(model.connectionState != .connected)
                }
                moreMenu
            }
            .padding(8)
            .background(
                ReLandTheme.terminalOverlay,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private func dockButton(
        title: String,
        accessibilityTitle: String,
        systemImage: String,
        identifier: String,
        tint: Color = .white,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            dockLabel(
                title: title,
                systemImage: systemImage,
                tint: tint,
                isActive: isActive
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityTitle)
        .accessibilityIdentifier(identifier)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                model.isDirectTouchEnabled.toggle()
            } label: {
                Label(
                    model.isDirectTouchEnabled
                        ? "Trackpad mode"
                        : "Direct touch",
                    systemImage:
                        "rectangle.and.hand.point.up.left"
                )
            }
            .accessibilityIdentifier("directTouchToggle")

            Button {
                model.isDragEnabled.toggle()
            } label: {
                Label(
                    model.isDragEnabled ? "Stop drag" : "Drag",
                    systemImage: "hand.draw"
                )
            }
            .accessibilityIdentifier("dragToggle")

            Button {
                model.sendClick(button: .right)
            } label: {
                Label(
                    "Right click",
                    systemImage: "cursorarrow.click.2"
                )
            }
            .accessibilityIdentifier("rightClickButton")
            .disabled(!model.canSendRemoteInput)

            Button {
                model.send(.scroll(x: 0, y: -120))
            } label: {
                Label("Scroll down", systemImage: "arrow.down")
            }
            .accessibilityIdentifier("scrollButton")
            .disabled(!model.canSendRemoteInput)

            if zoomScale > 1.01 {
                Button {
                    resetZoom()
                } label: {
                    Label(
                        "Reset zoom",
                        systemImage:
                            "arrow.down.right.and.arrow.up.left"
                    )
                }
                .accessibilityIdentifier("resetZoomButton")
            }

            Button {
                isGestureGuidePresented = true
            } label: {
                Label(
                    "Gesture Guide",
                    systemImage: "hand.raised"
                )
            }

            if model.isE2EMode {
                Button {
                    model.requestE2EDisconnect()
                } label: {
                    Label(
                        "Test reconnect",
                        systemImage: "arrow.clockwise"
                    )
                }
                .accessibilityIdentifier("reconnectTestButton")
            }
        } label: {
            dockLabel(
                title: "More",
                systemImage: "ellipsis",
                tint: .white,
                isActive: false
            )
        }
        .accessibilityLabel("More remote controls")
        .accessibilityIdentifier("moreButton")
    }

    private func dockLabel(
        title: String,
        systemImage: String,
        tint: Color,
        isActive: Bool
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
        }
        .foregroundStyle(isActive ? Color.white : tint)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(
            isActive
                ? ReLandTheme.accent
                : tint.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    isActive
                        ? ReLandTheme.accent
                        : tint.opacity(0.34),
                    lineWidth: 1
                )
        }
    }

    private var contentAspectRatio: CGFloat? {
        guard
            let information = model.displayInformation,
            information.height > 0
        else {
            return model.remoteImage.map {
                $0.size.width / max($0.size.height, 1)
            }
        }

        return CGFloat(information.width)
            / CGFloat(information.height)
    }

    private func updateZoom(_ multiplier: CGFloat) {
        let nextScale = min(max(zoomScale * multiplier, 1), 4)
        zoomScale = nextScale
        if nextScale <= 1.01 {
            resetZoom()
        } else {
            zoomOffset = clamped(offset: zoomOffset)
        }
    }

    private func panViewport(_ delta: CGSize) {
        zoomOffset = clamped(
            offset: CGSize(
                width: zoomOffset.width + delta.width,
                height: zoomOffset.height + delta.height
            )
        )
    }

    private func resetZoom() {
        zoomScale = 1
        zoomOffset = .zero
    }

    private func clamped(offset: CGSize) -> CGSize {
        guard zoomScale > 1, viewportSize != .zero else {
            return .zero
        }
        let maxX = viewportSize.width * (zoomScale - 1) / 2
        let maxY = viewportSize.height * (zoomScale - 1) / 2
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    private func specialKey(
        _ title: String,
        label: String? = nil,
        systemImage: String? = nil,
        code: UInt16
    ) -> some View {
        Button {
            model.sendKey(code)
        } label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(label ?? title)
                        .font(.caption.bold())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
        .disabled(!model.canSendRemoteInput)
    }
}

private struct RemoteSessionStatusPill: View {
    @Bindable var model: ClientAppModel
    let zoomScale: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            Text(model.connectionState.title)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("connectionStatus")

            if let target = model.selectedCaptureTarget {
                Divider()
                    .frame(height: 16)
                Text(target.kind == .window ? target.applicationName : "Screen")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("captureTargetStatus")
            }

            Divider()
                .frame(height: 16)

            Text("Frames \(model.frameCount)")
                .font(.caption.monospacedDigit())
                .accessibilityIdentifier("frameCount")

            Divider()
                .frame(height: 16)

            Text(
                "Zoom \(zoomScale, format: .number.precision(.fractionLength(1)))×"
            )
            .font(.caption.monospacedDigit())
            .accessibilityIdentifier("zoomStatus")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ReLandTheme.terminalOverlay, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusColor: Color {
        switch model.connectionState {
        case .connected:
            .green
        case .failed:
            .red
        case .idle:
            .gray
        case .connecting, .authenticating, .pairing, .reconnecting:
            .orange
        }
    }
}
