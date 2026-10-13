using System.Net;
using System.Text;
using System.Text.Json;
using ReLand.Windows.Core.Protocol;
using ReLand.Windows.Core.Security;
using Xunit;

namespace ReLand.Windows.Tests;

public sealed class CredentialRegistryTests
{
    [Fact]
    public void PairingPayloadUsesV2UnixTimeAndWindowsCapabilities()
    {
        var clock = new TestClock();
        var registry = new CredentialRegistry(new MemoryCredentialStore(), clock);
        string payload = registry.CreatePairingPayload(IPAddress.Parse("192.168.1.20"), 45454);
        Assert.StartsWith("reland-pair:v2:", payload);
        string encoded = payload["reland-pair:v2:".Length..].Replace('-', '+').Replace('_', '/');
        encoded = encoded.PadRight((encoded.Length + 3) / 4 * 4, '=');
        using var document = JsonDocument.Parse(Convert.FromBase64String(encoded));
        JsonElement json = document.RootElement;
        Assert.Equal(2, json.GetProperty("version").GetInt32());
        Assert.Equal("windows", json.GetProperty("hostPlatform").GetString());
        Assert.Equal(clock.GetUtcNow().AddMinutes(10).ToUnixTimeSeconds(),
            json.GetProperty("expiresAt").GetDouble());
        Assert.True(json.GetProperty("credential").GetProperty("isPairingCredential").GetBoolean());
        Assert.Equal(32, json.GetProperty("credential").GetProperty("key").GetBytesFromBase64().Length);
        Assert.DoesNotContain("terminal", json.GetProperty("capabilities").ToString());
    }

    [Fact]
    public void PairingExpiresAndCanBeConsumedOnlyOnce()
    {
        var store = new MemoryCredentialStore();
        var clock = new TestClock();
        var registry = new CredentialRegistry(store, clock);
        registry.CreatePairingPayload(IPAddress.Loopback, 45454);
        string expired = Assert.IsType<PairingCode>(registry.PendingPairing).Credential.Id;
        clock.Advance(TimeSpan.FromMinutes(10));
        Assert.Null(registry.Find(expired));
        Assert.Throws<InvalidOperationException>(() =>
            registry.CompletePairing(expired, PskCredential.Generate("Test Phone")));

        registry.CreatePairingPayload(IPAddress.Loopback, 45454);
        string identity = Assert.IsType<PairingCode>(registry.PendingPairing).Credential.Id;
        PskCredential device = PskCredential.Generate("Test Phone");
        registry.CompletePairing(identity, device);
        Assert.Null(registry.Find(identity));
        Assert.NotNull(registry.Find(device.Id));
        Assert.Single(store.State.Credentials);
        Assert.Throws<InvalidOperationException>(() =>
            registry.CompletePairing(identity, PskCredential.Generate("Second Phone")));
    }

    [Fact]
    public void MovingWallClockBackwardCannotExtendPairingLifetime()
    {
        var clock = new TestClock();
        var registry = new CredentialRegistry(new MemoryCredentialStore(), clock);
        registry.CreatePairingPayload(IPAddress.Loopback, 45454);
        string identity = Assert.IsType<PairingCode>(registry.PendingPairing).Credential.Id;
        clock.Advance(TimeSpan.FromMinutes(10));
        clock.ChangeWallClock(TimeSpan.FromHours(-2));

        Assert.Null(registry.Find(identity));
        Assert.Null(registry.PendingPairing);
    }

    [Fact]
    public void PersistenceFailureDoesNotConsumePairingOrActivateDevice()
    {
        var store = new MemoryCredentialStore { FailWrites = true };
        var registry = new CredentialRegistry(store);
        registry.CreatePairingPayload(IPAddress.Loopback, 45454);
        string identity = Assert.IsType<PairingCode>(registry.PendingPairing).Credential.Id;
        PskCredential device = PskCredential.Generate("Test Phone");

        Assert.Throws<IOException>(() => registry.CompletePairing(identity, device));
        Assert.NotNull(registry.Find(identity));
        Assert.Null(registry.Find(device.Id));
    }

    [Fact]
    public void RefusesPairingCredentialReuseAndIdentityOverwrite()
    {
        PskCredential existing = PskCredential.Generate("Existing Phone");
        var registry = new CredentialRegistry(new MemoryCredentialStore(existing));
        registry.CreatePairingPayload(IPAddress.Loopback, 45454);
        PskCredential pairing = Assert.IsType<PairingCode>(registry.PendingPairing).Credential;

        Assert.Throws<InvalidDataException>(() => registry.CompletePairing(pairing.Id, existing));
        Assert.Throws<InvalidDataException>(() => registry.CompletePairing(
            pairing.Id, pairing with { Id = "different", IsPairingCredential = false }));
        Assert.Throws<InvalidDataException>(() => registry.CompletePairing(
            pairing.Id, PskCredential.Generate("Another pairing", pairing: true)));
        Assert.NotNull(registry.PendingPairing);
    }

    [Fact]
    public void RemovingDeviceRevokesFutureAuthentication()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var store = new MemoryCredentialStore(credential);
        var registry = new CredentialRegistry(store);
        registry.Remove(credential.Id);

        Assert.Null(registry.Find(credential.Id));
        Assert.Empty(store.State.Credentials);
    }

    [Fact]
    public void CredentialCopiesCannotMutateRegistryKeys()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var registry = new CredentialRegistry(new MemoryCredentialStore(credential));
        byte[] original = [.. credential.Key];
        registry.State.Credentials[0].Key[0] ^= 0xFF;
        Assert.IsType<PskCredential>(registry.Find(credential.Id)).Key[0] ^= 0xFF;

        Assert.Equal(original, Assert.IsType<PskCredential>(registry.Find(credential.Id)).Key);
    }

    [Fact]
    public void RejectsPublicPairingDestination()
    {
        var registry = new CredentialRegistry(new MemoryCredentialStore());
        Assert.Throws<InvalidDataException>(() =>
            registry.CreatePairingPayload(IPAddress.Parse("203.0.113.10"), 45454));
    }
}

internal sealed class MemoryCredentialStore(params PskCredential[] credentials) : IHostCredentialStore
{
    public HostState State { get; private set; } = new(
        Guid.NewGuid().ToString("D"), "Test Windows PC", credentials);
    public bool FailWrites { get; set; }

    public HostState Load() => State;

    public void Save(HostState state)
    {
        if (FailWrites)
        {
            throw new IOException("Test storage failure");
        }
        State = state;
    }
}

internal sealed class TestClock : TimeProvider
{
    private DateTimeOffset now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
    private long timestamp;
    public override DateTimeOffset GetUtcNow() => now;
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    public override long GetTimestamp() => timestamp;
    public void Advance(TimeSpan duration)
    {
        now += duration;
        timestamp += duration.Ticks;
    }
    public void ChangeWallClock(TimeSpan duration) => now += duration;
}
