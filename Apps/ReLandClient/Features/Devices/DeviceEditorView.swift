import ReLandCore
import SwiftUI

struct DeviceEditorView: View {
    @Bindable var model: ClientAppModel
    let device: RemoteDevice

    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var port: String

    init(model: ClientAppModel, device: RemoteDevice) {
        self.model = model
        self.device = device
        _address = State(initialValue: device.address)
        _port = State(initialValue: String(device.port))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Private IP address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }

                Section {
                    Text(
                        "Use your computer's private LAN address "
                            + "or Tailscale 100.x address."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(device.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let portValue = UInt16(port) else {
                            model.alertMessage = "Enter a valid port."
                            return
                        }
                        model.update(
                            device,
                            address: address,
                            port: portValue
                        )
                        dismiss()
                    }
                    .disabled(address.isEmpty || UInt16(port) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
