using System.Net;
using System.Security.Cryptography;
using System.Text.Json.Serialization;
using ReLand.Windows.Core.Protocol;

namespace ReLand.Windows.Core.Security;

public interface IHostCredentialStore
{
    HostState Load();
    void Save(HostState state);
}

public sealed record PairingCode(PskCredential Credential, DateTimeOffset ExpiresAt);

public sealed class CredentialRegistry
{
    public const int MaximumDevices = 64;
    private readonly object gate = new();
    private readonly IHostCredentialStore store;
    private readonly TimeProvider clock;
    private HostState state;
    private PairingCode? pendingPairing;
    private long pairingCreatedTimestamp;

    public CredentialRegistry(IHostCredentialStore store, TimeProvider? clock = null)
    {
        this.store = store;
        this.clock = clock ?? TimeProvider.System;
        state = store.Load();
        if (!Guid.TryParse(state.HostId, out _)
            || string.IsNullOrWhiteSpace(state.HostName)
            || state.HostName.Length > 256
            || state.HostName.Any(char.IsControl)
            || state.Credentials is null
            || state.Credentials.Length > MaximumDevices)
        {
            throw new InvalidDataException("The saved host configuration is invalid.");
        }

        var identities = new HashSet<string>(StringComparer.Ordinal);
        foreach (PskCredential credential in state.Credentials)
        {
            if (credential is null)
            {
                throw new InvalidDataException("The saved device credentials are invalid.");
            }
            credential.Validate();
            if (credential.IsPairingCredential || !identities.Add(credential.Id))
            {
                throw new InvalidDataException("The saved device credentials are invalid.");
            }
        }
        state = Copy(state);
    }

    public HostState State
    {
        get
        {
            lock (gate)
            {
                return Copy(state);
            }
        }
    }

    public PairingCode? PendingPairing
    {
        get
        {
            lock (gate)
            {
                ExpirePairing();
                return pendingPairing is { } pairing
                    ? pairing with { Credential = Copy(pairing.Credential) }
                    : null;
            }
        }
    }

    public string CreatePairingPayload(IPAddress address, ushort port)
    {
        if (!PrivateNetworkPolicy.Allows(address) || port == 0)
        {
            throw new InvalidDataException("Choose a private LAN or Tailscale address.");
        }

        lock (gate)
        {
            if (state.Credentials.Length >= MaximumDevices)
            {
                throw new InvalidOperationException("Remove a paired device before creating another code.");
            }

            ClearPairing();
            pairingCreatedTimestamp = clock.GetTimestamp();
            pendingPairing = new(PskCredential.Generate("Pairing", pairing: true),
                clock.GetUtcNow().AddMinutes(10));
            var payload = new PairingPayload(
                2, state.HostId, state.HostName, address.ToString(), port,
                pendingPairing.Credential,
                pendingPairing.ExpiresAt.ToUnixTimeMilliseconds() / 1000.0,
                HostProtocol.Platform, HostProtocol.Capabilities.ToArray());
            string encoded = "reland-pair:v2:"
                + Convert.ToBase64String(WireJson.Encode(payload))
                    .TrimEnd('=').Replace('+', '-').Replace('/', '_');
            if (encoded.Length > 4096)
            {
                ClearPairing();
                throw new InvalidDataException("The pairing code exceeds the supported size.");
            }
            return encoded;
        }
    }

    public void CancelPairing()
    {
        lock (gate)
        {
            ClearPairing();
        }
    }

    public PskCredential? Find(string identity)
    {
        lock (gate)
        {
            ExpirePairing();
            if (pendingPairing?.Credential.Id == identity)
            {
                return Copy(pendingPairing.Credential);
            }
            PskCredential? credential = state.Credentials.FirstOrDefault(value => value.Id == identity);
            return credential is null ? null : Copy(credential);
        }
    }

    public void CompletePairing(string pairingIdentity, PskCredential device)
    {
        device.Validate();
        lock (gate)
        {
            ExpirePairing();
            if (pendingPairing is not { } pairing || pairing.Credential.Id != pairingIdentity)
            {
                throw new InvalidOperationException("The one-time pairing code expired or was already used.");
            }
            if (device.IsPairingCredential
                || device.Id == pairingIdentity
                || state.Credentials.Any(value => value.Id == device.Id)
                || CryptographicOperations.FixedTimeEquals(device.Key, pairing.Credential.Key)
                || state.Credentials.Length >= MaximumDevices)
            {
                throw new InvalidDataException("A fresh device credential is required.");
            }

            HostState updated = state with { Credentials = [.. state.Credentials, Copy(device)] };
            store.Save(Copy(updated));
            state = updated;
            ClearPairing();
        }
    }

    public void Remove(string identity)
    {
        lock (gate)
        {
            HostState updated = state with
            {
                Credentials = state.Credentials.Where(value => value.Id != identity).ToArray(),
            };
            store.Save(Copy(updated));
            state = updated;
        }
    }

    private void ExpirePairing()
    {
        if (pendingPairing is { } pairing
            && (clock.GetUtcNow() >= pairing.ExpiresAt
                || clock.GetElapsedTime(pairingCreatedTimestamp) >= TimeSpan.FromMinutes(10)))
        {
            ClearPairing();
        }
    }

    private void ClearPairing()
    {
        if (pendingPairing is { } pairing)
        {
            CryptographicOperations.ZeroMemory(pairing.Credential.Key);
            pendingPairing = null;
        }
    }

    private static PskCredential Copy(PskCredential value) => value with { Key = [.. value.Key] };

    private static HostState Copy(HostState value) =>
        value with { Credentials = value.Credentials.Select(Copy).ToArray() };

    private sealed record PairingPayload(
        int Version,
        [property: JsonPropertyName("hostID")] string HostId,
        string HostName,
        string Address,
        ushort Port,
        PskCredential Credential,
        double ExpiresAt,
        string HostPlatform,
        string[] Capabilities);
}
