import ReLandCore
import SwiftUI

struct DeviceListView: View {
    @Bindable var model: ClientAppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.devices.isEmpty {
                    ContentUnavailableView {
                        Label("No computers yet", systemImage: "desktopcomputer")
                    } description: {
                        Text(
                            "Pair this iPhone or iPad with "
                                + "ReLand Host."
                        )
                    } actions: {
                        Button("Add computer") {
                            model.isPairingSheetPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityHint("Opens the pairing flow")
                    }
                } else {
                    List {
                        ForEach(model.devices) { device in
                            VStack(alignment: .leading, spacing: 10) {
                                DeviceRow(device: device)

                                DeviceActionsView(
                                    model: model,
                                    device: device
                                )
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    model.remove(device)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("ReLand")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.isSettingsPresented = true
                    } label: {
                        Label(
                            "Settings",
                            systemImage: "gearshape"
                        )
                    }
                    .accessibilityIdentifier(
                        "appSettingsButton"
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.isPairingSheetPresented = true
                    } label: {
                        Label("Add computer", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $model.isPairingSheetPresented) {
                PairingView(model: model)
            }
            .sheet(item: $model.editingDevice) { device in
                DeviceEditorView(model: model, device: device)
            }
            .sheet(isPresented: $model.isSettingsPresented) {
                SettingsView(model: model)
            }
        }
    }
}

private struct DeviceActionsView: View {
    @Bindable var model: ClientAppModel
    let device: RemoteDevice

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                screenButton(compact: false)
                if device.supports(.captureTargets) {
                    appButton(compact: false)
                }
                if device.supports(.terminal) {
                    terminalButton(compact: false)
                }
                settingsButton(compact: false)
            }

            HStack(spacing: 8) {
                screenButton(compact: true)
                if device.supports(.captureTargets) {
                    appButton(compact: true)
                }
                if device.supports(.terminal) {
                    terminalButton(compact: true)
                }
                settingsButton(compact: true)
            }
        }
    }

    private func screenButton(compact: Bool) -> some View {
        Button {
            model.connect(to: device)
        } label: {
            DeviceActionLabel(
                title: "Screen",
                systemImage: "display",
                compact: compact
            )
            .frame(
                maxWidth: compact ? .infinity : nil,
                minHeight: compact ? 58 : 44
            )
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Screen")
        .accessibilityIdentifier("deviceScreenButton")
    }

    private func appButton(compact: Bool) -> some View {
        Button {
            model.connect(to: device, appOnly: true)
        } label: {
            DeviceActionLabel(
                title: "App",
                systemImage: "macwindow",
                compact: compact
            )
            .frame(
                maxWidth: compact ? .infinity : nil,
                minHeight: compact ? 58 : 44
            )
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("App")
        .accessibilityIdentifier("deviceAppButton")
    }

    private func terminalButton(compact: Bool) -> some View {
        Button {
            model.connect(to: device, terminalOnly: true)
        } label: {
            DeviceActionLabel(
                title: "Terminal",
                systemImage: "terminal",
                compact: compact
            )
            .frame(
                maxWidth: compact ? .infinity : nil,
                minHeight: compact ? 58 : 44
            )
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Terminal")
        .accessibilityIdentifier("deviceTerminalButton")
    }

    private func settingsButton(compact: Bool) -> some View {
        Button {
            model.editingDevice = device
        } label: {
            Group {
                if compact {
                    VStack(spacing: 3) {
                        Image(systemName: "gearshape")
                            .font(.body.weight(.semibold))
                        Text("Edit")
                            .font(.caption2.weight(.semibold))
                    }
                } else {
                    Image(systemName: "gearshape")
                }
            }
                .frame(
                    minWidth: compact ? nil : 44,
                    maxWidth: compact ? .infinity : nil,
                    minHeight: compact ? 58 : 44
                )
                .background(
                    ReLandTheme.controlBackground,
                    in: RoundedRectangle(cornerRadius: 11)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(ReLandTheme.accent)
        .accessibilityLabel("Edit connection for \(device.name)")
    }
}

private struct DeviceActionLabel: View {
    let title: String
    let systemImage: String
    let compact: Bool

    @ViewBuilder
    var body: some View {
        if compact {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
        } else {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct DeviceRow: View {
    let device: RemoteDevice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.hostPlatform == .windows ? "desktopcomputer" : "macbook")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(device.address):\(device.port)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
