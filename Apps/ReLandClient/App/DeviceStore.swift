import Foundation
import ReLandCore

struct DeviceStore {
    private static let devicesKey = "reland.devices"
    private let settings: any SettingsStoring
    private let credentials: any CredentialStoring

    init(
        settings: any SettingsStoring =
            UserDefaultsSettingsStore(),
        credentials: any CredentialStoring =
            KeychainSecretStore(
                service: "com.ppanwin10.reland.device-credentials"
            )
    ) {
        self.settings = settings
        self.credentials = credentials
    }

    func loadDevices() -> [RemoteDevice] {
        guard let data = settings.data(forKey: Self.devicesKey) else {
            return []
        }
        return (try? JSONDecoder().decode([RemoteDevice].self, from: data))
            ?? []
    }

    func credential(for device: RemoteDevice) throws -> PSKCredential? {
        guard
            let key = try credentials.data(
                for: device.credentialID
            )
        else {
            return nil
        }
        return try PSKCredential(
            id: device.credentialID,
            key: key,
            name: device.name
        )
    }

    func save(
        _ device: RemoteDevice,
        credential: PSKCredential
    ) throws {
        try credentials.set(credential.key, for: credential.id)
        var devices = loadDevices()
        devices.removeAll { $0.hostID == device.hostID }
        devices.append(device)
        let data = try JSONEncoder().encode(devices)
        settings.set(data, forKey: Self.devicesKey)
    }

    func remove(_ device: RemoteDevice) throws {
        try credentials.remove(account: device.credentialID)
        let devices = loadDevices().filter { $0.id != device.id }
        settings.set(
            try JSONEncoder().encode(devices),
            forKey: Self.devicesKey
        )
    }

    func update(_ device: RemoteDevice) throws {
        var devices = loadDevices()
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else {
            return
        }
        devices[index] = device
        settings.set(
            try JSONEncoder().encode(devices),
            forKey: Self.devicesKey
        )
    }
}
