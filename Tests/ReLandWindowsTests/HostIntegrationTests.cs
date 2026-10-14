using System.Net;
using System.Net.Sockets;
using System.Text;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;
using ReLand.Windows.Core.Desktop;
using ReLand.Windows.Core.Hosting;
using ReLand.Windows.Core.Input;
using ReLand.Windows.Core.Protocol;
using ReLand.Windows.Core.Security;
using Xunit;

namespace ReLand.Windows.Tests;

public sealed class HostIntegrationTests
{
    [Theory]
    [InlineData(false, 7)]
    [InlineData(false, 8)]
    [InlineData(true, 7)]
    [InlineData(true, 8)]
    public async Task StreamsFramesAndInputsUsingTlsPskAndProtocol7Or8(bool tls13, ushort version)
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var desktop = new TestDesktop();
        var registry = new CredentialRegistry(new MemoryCredentialStore(credential));
        await using var host = new RemoteHostServer(registry, desktop);
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, credential, tls13);
        client.Authenticate(credential, version);
        SessionReady ready = WireJson.Decode<SessionReady>(client.Read(WireKind.SessionReady).Payload);
        Assert.Equal(version, ready.ProtocolVersion);
        Assert.Equal("windows", ready.HostPlatform);
        Assert.Equal(HostProtocol.Capabilities.Order(), ready.Capabilities.Order());
        Assert.Equal(desktop.DisplayInformation,
            WireJson.Decode<DisplayInformation>(client.Read(WireKind.DisplayInfo).Payload));
        Assert.Equal(desktop.FrameBytes, client.Read(WireKind.VideoFrame).Payload);

        client.Send(new(WireKind.Input, Encoding.UTF8.GetBytes(
            """{"pointerAbsolute":{"x":0.25,"y":0.75}}""")));
        InputAcknowledgement acknowledgement = WireJson.Decode<InputAcknowledgement>(
            client.Read(WireKind.InputAcknowledgement).Payload);
        Assert.Equal(1UL, acknowledgement.Sequence);
        Assert.Equal(new RemoteInput.PointerAbsolute(0.25, 0.75), Assert.Single(desktop.Inputs));
        client.Send(WirePacket.Empty(WireKind.Ping));
        client.Read(WireKind.Pong);
        client.Dispose();
        await host.StopAsync();
        Assert.True(desktop.ReleaseCount > 0);
    }

    [Fact]
    public async Task PairsAndReconnectsWithFreshDeviceCredential()
    {
        var registry = new CredentialRegistry(new MemoryCredentialStore());
        await using var host = new RemoteHostServer(registry, new TestDesktop());
        host.Start(IPAddress.Loopback, 0);
        host.CreatePairingCode();
        PskCredential pairing = Assert.IsType<PairingCode>(registry.PendingPairing).Credential;
        PskCredential device = PskCredential.Generate("New Test Phone");
        using (var client = new TestClient(host.Endpoint!, pairing, true))
        {
            client.Authenticate(pairing);
            client.Send(WirePacket.Json(WireKind.PairRequest, new PairDeviceRequest(device)));
            PairDeviceAccepted accepted = WireJson.Decode<PairDeviceAccepted>(
                client.Read(WireKind.PairAccepted).Payload);
            Assert.Equal(registry.State.HostId, accepted.HostId);
            Assert.Equal("windows", accepted.HostPlatform);
            Assert.Equal(HostProtocol.Capabilities.Order(), accepted.Capabilities.Order());
        }
        Assert.Null(registry.Find(pairing.Id));
        using var reconnected = new TestClient(host.Endpoint!, device, false);
        reconnected.Authenticate(device);
        reconnected.Read(WireKind.SessionReady);
    }

    [Fact]
    public async Task BindsApplicationAuthenticationToTlsIdentity()
    {
        PskCredential first = PskCredential.Generate("First Test Phone");
        PskCredential second = PskCredential.Generate("Second Test Phone");
        var registry = new CredentialRegistry(new MemoryCredentialStore(first, second));
        await using var host = new RemoteHostServer(registry, new TestDesktop());
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, first, false);
        client.Authenticate(second);

        Assert.Equal("authenticationFailed", client.ReadError().Code);
        Assert.False(host.HasController);
    }

    [Fact]
    public async Task RequiresAuthenticationBeforeDesktopInput()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var desktop = new TestDesktop();
        var registry = new CredentialRegistry(new MemoryCredentialStore(credential));
        await using var host = new RemoteHostServer(registry, desktop);
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, credential, false);
        client.Send(new(WireKind.Input, Encoding.UTF8.GetBytes("""{"text":{"_0":"test"}}""")));

        Assert.Equal("authenticationRequired", client.ReadError().Code);
        Assert.Empty(desktop.Inputs);
    }

    [Fact]
    public async Task RejectsVersionsAndUnadvertisedCapabilities()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var registry = new CredentialRegistry(new MemoryCredentialStore(credential));
        await using var host = new RemoteHostServer(registry, new TestDesktop());
        host.Start(IPAddress.Loopback, 0);
        using (var incompatible = new TestClient(host.Endpoint!, credential, false))
        {
            incompatible.Authenticate(credential, 9);
            Assert.Equal("protocolMismatch", incompatible.ReadError().Code);
        }
        using var unsupported = new TestClient(host.Endpoint!, credential, true);
        unsupported.Authenticate(credential, capabilities: ["screen", "terminal"]);
        Assert.Equal("protocolMismatch", unsupported.ReadError().Code);
    }

    [Fact]
    public async Task RefusesInputWithoutNegotiatedInputCapability()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var desktop = new TestDesktop();
        await using var host = new RemoteHostServer(
            new CredentialRegistry(new MemoryCredentialStore(credential)), desktop);
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, credential, false);
        client.Authenticate(credential, capabilities: ["screen"]);
        client.Read(WireKind.SessionReady);
        client.Send(new(WireKind.Input, Encoding.UTF8.GetBytes("""{"text":{"_0":"test"}}""")));

        Assert.Equal("protocolMismatch", client.ReadError().Code);
        Assert.Empty(desktop.Inputs);
    }

    [Fact]
    public async Task TakeoverRequiresConsentAndRevokesPreviousController()
    {
        PskCredential first = PskCredential.Generate("First Test Phone");
        PskCredential second = PskCredential.Generate("Second Test Phone");
        var desktop = new TestDesktop();
        await using var host = new RemoteHostServer(
            new CredentialRegistry(new MemoryCredentialStore(first, second)), desktop);
        host.Start(IPAddress.Loopback, 0);
        using var original = new TestClient(host.Endpoint!, first, false);
        original.Authenticate(first);
        original.Read(WireKind.SessionReady);
        Assert.Throws<InvalidOperationException>(() => host.CreatePairingCode());
        using (var refused = new TestClient(host.Endpoint!, second, true))
        {
            refused.Authenticate(second);
            Assert.Equal("hostBusy", refused.ReadError().Code);
        }
        using var replacement = new TestClient(host.Endpoint!, second, false);
        replacement.Authenticate(second, takeover: true);
        replacement.Read(WireKind.SessionReady);
        Assert.Equal("sessionTakenOver", original.ReadError().Code);
        Assert.True(desktop.ReleaseCount >= 2);
    }

    [Fact]
    public async Task SameDeviceReconnectRevokesItsStaleConnection()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        await using var host = new RemoteHostServer(
            new CredentialRegistry(new MemoryCredentialStore(credential)), new TestDesktop());
        host.Start(IPAddress.Loopback, 0);
        using var original = new TestClient(host.Endpoint!, credential, false);
        original.Authenticate(credential);
        original.Read(WireKind.SessionReady);
        using var replacement = new TestClient(host.Endpoint!, credential, true);
        replacement.Authenticate(credential);
        replacement.Read(WireKind.SessionReady);

        Assert.Equal("sessionTakenOver", original.ReadError().Code);
    }

    [Fact]
    public async Task LockedDesktopBlocksInputAndReportsStatusWithoutStreaming()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var desktop = new TestDesktop { Unlocked = false };
        await using var host = new RemoteHostServer(
            new CredentialRegistry(new MemoryCredentialStore(credential)), desktop);
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, credential, true);
        client.Authenticate(credential);
        SessionReady ready = WireJson.Decode<SessionReady>(client.Read(WireKind.SessionReady).Payload);
        Assert.False(ready.HostPermissions.SessionUnlocked);
        client.Send(new(WireKind.Input, Encoding.UTF8.GetBytes("""{"text":{"_0":"test"}}""")));
        Assert.Equal(WireKind.Input, client.ReadError().RequestKind);
        Assert.Empty(desktop.Inputs);
        client.Send(WirePacket.Empty(WireKind.HostStatusRequest));
        Assert.False(WireJson.Decode<HostPermissionState>(
            client.Read(WireKind.HostStatusResponse).Payload).SessionUnlocked);
        Assert.Equal(0, desktop.CaptureCount);
    }

    [Fact]
    public async Task UnsupportedServicesReturnCorrelatedRecoverableErrors()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        await using var host = new RemoteHostServer(
            new CredentialRegistry(new MemoryCredentialStore(credential)), new TestDesktop());
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, credential, false);
        client.Authenticate(credential);
        client.Read(WireKind.SessionReady);
        foreach ((WireKind kind, string code) in new[]
        {
            (WireKind.TerminalListRequest, "terminalUnavailable"),
            (WireKind.FileListRequest, "fileServiceUnavailable"),
            (WireKind.CaptureTargetListRequest, "captureTargetsUnavailable"),
        })
        {
            client.Send(WirePacket.Empty(kind));
            RemoteErrorMessage error = client.ReadError();
            Assert.Equal(kind, error.RequestKind);
            Assert.Equal(code, error.Code);
            Assert.True(error.IsRecoverable);
        }
        string requestId = Guid.NewGuid().ToString("D");
        client.Send(WirePacket.Json(WireKind.TerminalCreateRequest, new { requestID = requestId }));
        RemoteErrorMessage createError = client.ReadError();
        Assert.Equal(WireKind.TerminalCreateRequest, createError.RequestKind);
        Assert.Equal(requestId, createError.RequestId);
        Assert.True(createError.IsRecoverable);
        client.Send(WirePacket.Empty(WireKind.Ping));
        client.Read(WireKind.Pong);
    }

    [Fact]
    public async Task ExpiresInactiveControllerAndReleasesInput()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var desktop = new TestDesktop();
        await using var host = new RemoteHostServer(
            new CredentialRegistry(new MemoryCredentialStore(credential)), desktop,
            controllerLease: TimeSpan.FromMilliseconds(500));
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, credential, false);
        client.Authenticate(credential);
        client.Read(WireKind.SessionReady);
        Assert.Equal("sessionExpired", client.ReadError().Code);
        Assert.True(desktop.ReleaseCount >= 2);
    }

    [Fact]
    public async Task CanStopImmediatelyAndRestartOnAnEphemeralPort()
    {
        await using var host = new RemoteHostServer(
            new CredentialRegistry(new MemoryCredentialStore()), new TestDesktop());
        host.Start(IPAddress.Loopback, 0);
        await host.StopAsync();
        Assert.False(host.IsRunning);
        host.Start(IPAddress.Loopback, 0);
        Assert.True(host.IsRunning);
        await host.StopAsync();
    }

    [Fact]
    public async Task ConcurrentStopsShareShutdownAndCannotClearRestartedHost()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        await using var host = new RemoteHostServer(
            new CredentialRegistry(new MemoryCredentialStore(credential)), new TestDesktop());
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, credential, true);
        client.Authenticate(credential);
        client.Read(WireKind.SessionReady);
        await Task.WhenAll(host.StopAsync(), host.StopAsync(), host.StopAsync());
        host.Start(IPAddress.Loopback, 0);
        Assert.True(host.IsRunning);
        using var reconnected = new TestClient(host.Endpoint!, credential, false);
        reconnected.Authenticate(credential);
        reconnected.Read(WireKind.SessionReady);
    }

    [Fact]
    public async Task PairingCodeExpirationAfterTlsHandshakeStillPreventsPairing()
    {
        var clock = new TestClock();
        var registry = new CredentialRegistry(new MemoryCredentialStore(), clock);
        await using var host = new RemoteHostServer(registry, new TestDesktop());
        host.Start(IPAddress.Loopback, 0);
        host.CreatePairingCode();
        PskCredential pairing = Assert.IsType<PairingCode>(registry.PendingPairing).Credential;
        using var client = new TestClient(host.Endpoint!, pairing, true);
        clock.Advance(TimeSpan.FromMinutes(10));
        client.Authenticate(pairing);

        Assert.Equal("authenticationFailed", client.ReadError().Code);
        Assert.Empty(registry.State.Credentials);
    }

    [Fact]
    public async Task RemovingCredentialRevokesAnAlreadyAuthenticatedController()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var registry = new CredentialRegistry(new MemoryCredentialStore(credential));
        await using var host = new RemoteHostServer(registry, new TestDesktop());
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, credential, false);
        client.Authenticate(credential);
        client.Read(WireKind.SessionReady);
        registry.Remove(credential.Id);

        Assert.Equal("authenticationRequired", client.ReadError().Code);
        Assert.False(host.HasController);
    }

    [Fact]
    public async Task UnlockAfterDisconnectStillReleasesDeferredInput()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        var desktop = new TestDesktop();
        await using var host = new RemoteHostServer(
            new CredentialRegistry(new MemoryCredentialStore(credential)), desktop);
        host.Start(IPAddress.Loopback, 0);
        using var client = new TestClient(host.Endpoint!, credential, false);
        client.Authenticate(credential);
        client.Read(WireKind.SessionReady);
        client.Send(new(WireKind.Input, Encoding.UTF8.GetBytes(
            """{"button":{"button":"left","isDown":true,"clickCount":1}}""")));
        client.Read(WireKind.InputAcknowledgement);
        Assert.True(desktop.HoldsInput);
        desktop.Unlocked = false;
        client.Dispose();
        Assert.True(SpinWait.SpinUntil(() => !host.HasController, TimeSpan.FromSeconds(2)));
        Assert.True(desktop.HoldsInput);
        desktop.Unlocked = true;

        Assert.True(SpinWait.SpinUntil(() => !desktop.HoldsInput, TimeSpan.FromSeconds(2)));
    }

    private sealed class TestDesktop : IRemoteDesktop
    {
        private readonly object gate = new();
        private readonly List<RemoteInput> inputs = [];
        private int releaseCount;
        private int captureCount;
        private volatile bool unlocked = true;
        private volatile bool holdsInput;
        public bool Unlocked { get => unlocked; set => unlocked = value; }
        public bool HoldsInput => holdsInput;
        public int ReleaseCount => Volatile.Read(ref releaseCount);
        public int CaptureCount => Volatile.Read(ref captureCount);
        public DisplayInformation DisplayInformation { get; } = new(640, 480);
        public HostPermissionState PermissionState => new(true, true, Unlocked);
        public byte[] FrameBytes { get; } = [0xFF, 0xD8, 0xFF, 0xD9];
        public RemoteInput[] Inputs
        {
            get
            {
                lock (gate)
                {
                    return inputs.ToArray();
                }
            }
        }

        public DesktopFrame Capture()
        {
            Interlocked.Increment(ref captureCount);
            return new(DisplayInformation, FrameBytes);
        }

        public string Handle(RemoteInput input)
        {
            lock (gate)
            {
                inputs.Add(input);
                if (input is RemoteInput.Button { IsDown: true })
                {
                    holdsInput = true;
                }
            }
            return "Test input";
        }

        public void ReleaseInput()
        {
            Interlocked.Increment(ref releaseCount);
            if (unlocked)
            {
                holdsInput = false;
            }
        }
    }

    private sealed class TestClient : IDisposable
    {
        private readonly TcpClient socket = new();
        private readonly Stream stream;
        private readonly AuthenticationChallenge challenge;

        public TestClient(IPEndPoint endpoint, PskCredential credential, bool tls13)
        {
            socket.Connect(endpoint);
            socket.ReceiveTimeout = 5000;
            socket.SendTimeout = 5000;
            var protocol = new TlsClientProtocol(socket.GetStream());
            protocol.Connect(new TestPskClient(credential, tls13));
            stream = protocol.Stream;
            challenge = WireJson.Decode<AuthenticationChallenge>(Read(WireKind.Challenge).Payload);
        }

        public void Authenticate(PskCredential credential, ushort version = 8,
            bool takeover = false, string[]? capabilities = null) =>
            Send(WirePacket.Json(WireKind.Authenticate,
                new AuthenticationResponse(credential.Id, credential.AuthenticationCode(challenge.Nonce),
                    version, capabilities ?? challenge.Capabilities, takeover)));

        public void Send(WirePacket packet)
        {
            stream.Write(WireCodec.Encode(packet));
            stream.Flush();
        }

        public WirePacket Read(WireKind expected)
        {
            for (int count = 0; count < 100; count++)
            {
                WirePacket packet = WireCodec.Read(stream) ?? throw new EndOfStreamException();
                if (packet.Kind == expected)
                {
                    return packet;
                }
                Assert.True(packet.Kind is WireKind.VideoFrame or WireKind.DisplayInfo or WireKind.HostStatusResponse,
                    $"Expected {expected}, received {packet.Kind}.");
            }
            throw new InvalidDataException("Expected message was not received.");
        }

        public RemoteErrorMessage ReadError() =>
            WireJson.Decode<RemoteErrorMessage>(Read(WireKind.Error).Payload);

        public void Dispose() => socket.Dispose();
    }

    private sealed class TestPskClient(PskCredential credential, bool tls13)
        : PskTlsClient(new BcTlsCrypto(),
            new BasicTlsPskIdentity(Encoding.UTF8.GetBytes(credential.Id), credential.Key))
    {
        protected override ProtocolVersion[] GetSupportedVersions() =>
            (tls13 ? ProtocolVersion.TLSv13 : ProtocolVersion.TLSv12).Only();

        protected override int[] GetSupportedCipherSuites() => tls13
            ? [CipherSuite.TLS_AES_128_GCM_SHA256]
            : [CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256];

        public override IList<TlsPskExternal> GetExternalPsks() =>
            [new BasicTlsPskExternal(Encoding.UTF8.GetBytes(credential.Id), Crypto.CreateSecret(credential.Key))];
    }
}
