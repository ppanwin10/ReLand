import SwiftUI
import VisionKit

struct PairingView: View {
    @Bindable var model: ClientAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isScannerPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "Pair once while you are physically at your computer.",
                        systemImage: "lock.shield"
                    )
                    Text(
                        "Open ReLand Host, create a one-time code, "
                            + "then scan its QR code. The secret is never "
                            + "copied to the clipboard or opened as a link."
                    )
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Secure pairing")
                }

                Section {
                    if DataScannerViewController.isSupported,
                       DataScannerViewController.isAvailable
                    {
                        Button {
                            isScannerPresented = true
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        ContentUnavailableView(
                            "QR scanning unavailable",
                            systemImage: "camera.fill",
                            description: Text(
                                "Use an iPhone or iPad with a supported camera."
                            )
                        )
                    }
                }
            }
            .navigationTitle("Add computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .fullScreenCover(isPresented: $isScannerPresented) {
            ZStack(alignment: .topTrailing) {
                QRCodeScannerView(
                    onCode: { code in
                        isScannerPresented = false
                        model.preparePairing(payload: code)
                    }
                )
                .ignoresSafeArea()

                Button {
                    isScannerPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding()
                .accessibilityLabel("Close scanner")
            }
        }
        .alert(
            "Pair with this computer?",
            isPresented: Binding(
                get: { model.pendingPairingDescriptor != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelPairingConfirmation()
                    }
                }
            ),
            presenting: model.pendingPairingDescriptor
        ) { _ in
            Button("Cancel", role: .cancel) {
                model.cancelPairingConfirmation()
            }
            Button("Pair") {
                model.confirmPairing()
            }
        } message: { descriptor in
            Text(
                "\(descriptor.hostName)\n"
                    + "\(descriptor.address):\(descriptor.port)"
            )
        }
    }
}
