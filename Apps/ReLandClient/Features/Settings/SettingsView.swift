import ReLandCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: ClientAppModel

    @Environment(\.dismiss) private var dismiss
    @State private var isClearCacheConfirmationPresented = false
    @State private var isResetAIConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Pointer speed") {
                        Text(
                            model.pointerSensitivity,
                            format: .number.precision(
                                .fractionLength(1)
                            )
                        )
                        .monospacedDigit()
                    }
                    Slider(
                        value: $model.pointerSensitivity,
                        in: 1...4,
                        step: 0.2
                    )
                    .accessibilityLabel("Default pointer speed")

                    Toggle(
                        "Three-finger app switching",
                        isOn: $model.isThreeFingerSwitchingEnabled
                    )
                    Toggle("Haptic feedback", isOn: $model.hapticsEnabled)
                    Toggle(
                        "Keep App Mode switcher visible",
                        isOn: $model.isAppSwitcherPinned
                    )
                } header: {
                    Text("Controls")
                        .accessibilityIdentifier(
                            "settingsControlsSection"
                        )
                }

                Section("ReLand AI") {
                    Text(
                        "ReLand AI starts supported local AI CLIs with "
                            + "session-specific artifact instructions. "
                            + "Raw shell commands remain unchanged."
                    )
                    LabeledContent("Saved launch profiles") {
                        Text(
                            String(
                                model.savedAILaunchProfiles.count
                            )
                        )
                        .monospacedDigit()
                    }
                    Button("Reset saved launch arguments") {
                        isResetAIConfirmationPresented = true
                    }
                }

                Section {
                    LabeledContent("Downloaded cache") {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: model.cacheByteCount,
                                countStyle: .file
                            )
                        )
                    }
                    Button("Clear downloaded cache", role: .destructive) {
                        isClearCacheConfirmationPresented = true
                    }
                } header: {
                    Text("Storage")
                        .accessibilityIdentifier(
                            "settingsStorageSection"
                        )
                }

                Section("Network & Pairing") {
                    Text(
                        "Use the same trusted LAN or a private Tailscale "
                            + "network. ReLand pairing does not add a "
                            + "Tailscale user or device."
                    )
                    Link(
                        "Tailscale prerequisites",
                        destination: URL(
                            string:
                                "https://tailscale.com/docs/getting-started"
                        )!
                    )
                    Link(
                        "Tailscale plans",
                        destination: URL(
                            string: "https://tailscale.com/pricing"
                        )!
                    )
                }

                Section {
                    Toggle(
                        "Allow terminal clipboard writes",
                        isOn: $model.allowsTerminalClipboardWrites
                    )
                    Text(
                        "Off by default. When enabled, ReLand accepts "
                            + "UTF-8 terminal clipboard content up to 4 KiB."
                    )
                    Text(
                        "ReLand has no account or cloud relay. Terminal "
                            + "links always require confirmation."
                    )
                } header: {
                    Text("Privacy & Security")
                        .accessibilityIdentifier(
                            "settingsPrivacySection"
                        )
                }

                Section("Help") {
                    Button("Show setup guide again") {
                        model.restartOnboarding()
                        dismiss()
                    }
                    Link(
                        "Project documentation",
                        destination: URL(
                            string:
                                "https://github.com/ppanwin10/ReLand"
                        )!
                    )
                }

                Section("About") {
                    LabeledContent("App", value: "ReLand")
                    LabeledContent(
                        "Version",
                        value: versionDescription
                    )
                    LabeledContent(
                        "Protocol",
                        value: String(
                            ReLandConstants.protocolVersion
                        )
                    )
                    Text("Apache License 2.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            model.refreshCacheUsage()
        }
        .confirmationDialog(
            "Clear downloaded cache?",
            isPresented: $isClearCacheConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                model.clearDownloadCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes downloaded previews only. "
                    + "It does not delete Mac session files or artifacts."
            )
        }
        .confirmationDialog(
            "Reset ReLand AI launch arguments?",
            isPresented: $isResetAIConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                model.resetSavedAILaunchOptions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Saved custom arguments are removed. Permission-bypass "
                    + "options already default off for every new launch."
            )
        }
    }

    private var versionDescription: String {
        let version =
            Bundle.main.object(
                forInfoDictionaryKey:
                    "CFBundleShortVersionString"
            ) as? String ?? "1.0"
        let build =
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "1"
        return "\(version) (\(build))"
    }
}
