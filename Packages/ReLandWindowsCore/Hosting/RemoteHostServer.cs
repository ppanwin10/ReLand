using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using Org.BouncyCastle.Tls;
using ReLand.Windows.Core.Desktop;
using ReLand.Windows.Core.Input;
using ReLand.Windows.Core.Protocol;
using ReLand.Windows.Core.Security;
using ReLand.Windows.Core.Transport;

namespace ReLand.Windows.Core.Hosting;

public sealed class RemoteHostServer(
    CredentialRegistry credentials,
    IRemoteDesktop desktop,
    TimeSpan? controllerLease = null) : IAsyncDisposable
{
    private const int MaximumConnections = 8;
    private const int MaximumCommandSize = 64 * 1024;
    private readonly object gate = new();
    private readonly Dictionary<Guid, ClientContext> clients = [];
    private readonly TimeSpan lease = controllerLease ?? TimeSpan.FromSeconds(20);
    private TcpListener? listener;
    private CancellationTokenSource? lifetime;
    private Task? acceptTask;
    private Task? frameTask;
    private Task? stoppingTask;
    private ClientContext? controller;

    public event Action? StateChanged;
    public event Action? PairingAccepted;
    public event Action<string>? ErrorOccurred;

    public bool IsRunning
    {
        get
        {
            lock (gate)
            {
                return listener is not null && lifetime?.IsCancellationRequested == false;
            }
        }
    }

    public bool HasController
    {
        get
        {
            lock (gate)
            {
                return controller is { IsClosed: false };
            }
        }
    }

    public IPEndPoint? Endpoint
    {
        get
        {
            lock (gate)
            {
                return listener?.LocalEndpoint as IPEndPoint;
            }
        }
    }

    public void Start(IPAddress address, ushort port = HostProtocol.DefaultPort)
    {
        if (!PrivateNetworkPolicy.Allows(address))
        {
            throw new InvalidDataException("The host can listen only on a private LAN or Tailscale address.");
        }
        lock (gate)
        {
            if (lifetime is not null || stoppingTask is { IsCompleted: false })
            {
                throw new InvalidOperationException("Stop the host before starting it again.");
            }

            var candidate = new TcpListener(address, port);
            candidate.Start(MaximumConnections);
            stoppingTask = null;
            listener = candidate;
            lifetime = new CancellationTokenSource();
            CancellationToken token = lifetime.Token;
            acceptTask = AcceptConnections(candidate, token);
            frameTask = Task.Run(() => StreamFrames(token), CancellationToken.None);
        }
        StateChanged?.Invoke();
    }

    public string CreatePairingCode()
    {
        lock (gate)
        {
            if (!IsRunning || Endpoint is not { } endpoint)
            {
                throw new InvalidOperationException("Start ReLand Host before creating a pairing code.");
            }
            if (controller is not null)
            {
                throw new InvalidOperationException("Disconnect the controlling device before creating a pairing code.");
            }
            return credentials.CreatePairingPayload(endpoint.Address, (ushort)endpoint.Port);
        }
    }

    public Task StopAsync()
    {
        lock (gate)
        {
            if (stoppingTask is { IsCompleted: false })
            {
                return stoppingTask;
            }
            if (lifetime is null)
            {
                return Task.CompletedTask;
            }
            CancellationTokenSource stoppedLifetime = lifetime;
            stoppedLifetime.Cancel();
            listener?.Stop();
            foreach (ClientContext client in clients.Values)
            {
                client.Close();
            }
            Task[] tasks = [.. clients.Values.Select(value => value.Completion),
                acceptTask ?? Task.CompletedTask, frameTask ?? Task.CompletedTask];
            controller = null;
            credentials.CancelPairing();
            stoppingTask = FinishStop(stoppedLifetime, tasks);
            return stoppingTask;
        }
    }

    private async Task FinishStop(CancellationTokenSource stoppedLifetime, Task[] tasks)
    {
        ReleaseInput();
        await Task.WhenAll(tasks).ConfigureAwait(false);
        lock (gate)
        {
            listener = null;
            lifetime = null;
            acceptTask = null;
            frameTask = null;
        }
        stoppedLifetime.Dispose();
        StateChanged?.Invoke();
    }

    public void DisconnectDevice(string credentialId)
    {
        lock (gate)
        {
            foreach (ClientContext client in clients.Values.Where(value => value.CredentialId == credentialId))
            {
                client.Close();
            }
            if (controller?.CredentialId == credentialId)
            {
                controller = null;
                ReleaseInput();
            }
        }
        StateChanged?.Invoke();
    }

    public void RefreshIdleInput()
    {
        lock (gate)
        {
            if (controller is null)
            {
                ReleaseInput();
            }
        }
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    private async Task AcceptConnections(TcpListener activeListener, CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                TcpClient socket = await activeListener.AcceptTcpClientAsync(token).ConfigureAwait(false);
                if (socket.Client.RemoteEndPoint is not IPEndPoint endpoint
                    || !PrivateNetworkPolicy.Allows(endpoint.Address))
                {
                    socket.Dispose();
                    continue;
                }
                lock (gate)
                {
                    if (token.IsCancellationRequested || clients.Count >= MaximumConnections)
                    {
                        socket.Dispose();
                        continue;
                    }
                    var context = new ClientContext(socket, token);
                    clients.Add(context.Id, context);
                    context.Completion = Task.Run(() => RunSession(context, token), CancellationToken.None);
                }
            }
        }
        catch (Exception error) when (error is OperationCanceledException or SocketException or ObjectDisposedException)
        {
            if (!token.IsCancellationRequested)
            {
                ErrorOccurred?.Invoke("The listener stopped unexpectedly. Stop and restart ReLand Host.");
                lock (gate)
                {
                    lifetime?.Cancel();
                }
                StateChanged?.Invoke();
            }
        }
    }

    private void RunSession(ClientContext context, CancellationToken token)
    {
        try
        {
            var tls = new PskTlsTransport(credentials);
            var protocol = new TlsServerProtocol(context.Socket.GetStream());
            protocol.Accept(tls);
            if (tls.CredentialId is null)
            {
                throw new HostRequestException("authenticationFailed", "Authentication failed.");
            }
            context.Stream = protocol.Stream;
            byte[] nonce = RandomNumberGenerator.GetBytes(32);
            context.Send(WirePacket.Json(WireKind.Challenge,
                new AuthenticationChallenge(nonce, HostProtocol.Versions, HostProtocol.Capabilities.ToArray())));
            WirePacket authentication = ReadRequired(context);
            if (authentication.Kind != WireKind.Authenticate)
            {
                throw new HostRequestException("authenticationRequired", "Authentication is required.");
            }
            AuthenticationResponse response = WireJson.Decode<AuthenticationResponse>(authentication.Payload);
            if (!HostProtocol.Versions.Contains(response.ProtocolVersion)
                || response.Capabilities is null
                || response.Capabilities.Length > HostProtocol.Capabilities.Count
                || response.Capabilities.Distinct(StringComparer.Ordinal).Count() != response.Capabilities.Length
                || response.Capabilities.Any(value => !HostProtocol.Capabilities.Contains(value)))
            {
                throw new HostRequestException("protocolMismatch", "The client and host could not negotiate compatible features.");
            }
            if (response.CredentialId != tls.CredentialId
                || credentials.Find(response.CredentialId) is not { } credential
                || !credential.Validates(response.AuthenticationCode, nonce))
            {
                throw new HostRequestException("authenticationFailed", "Authentication failed.");
            }
            context.CredentialId = credential.Id;
            context.Capabilities = new HashSet<string>(response.Capabilities, StringComparer.Ordinal);
            context.ProtocolVersion = response.ProtocolVersion;

            if (credential.IsPairingCredential)
            {
                PairDevice(context, credential);
                return;
            }

            Activate(context, response.RequestsControllerTakeover);
            while (!token.IsCancellationRequested && !context.IsClosed)
            {
                WirePacket? packet = WireCodec.Read(context.Stream, MaximumCommandSize);
                if (packet is null)
                {
                    break;
                }
                HandleActive(context, packet);
            }
        }
        catch (HostRequestException error)
        {
            SendError(context, error.Code, error.Message);
        }
        catch (DesktopOperationException error)
        {
            ErrorOccurred?.Invoke(error.Message);
            SendError(context, "internalError", error.Message);
        }
        catch (Exception error) when (error is JsonException or InvalidDataException)
        {
            SendError(context, "internalError", "The client sent an invalid message.");
        }
        catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException)
        {
            if (!context.IsClosed && !token.IsCancellationRequested)
            {
                ErrorOccurred?.Invoke("A connection was interrupted. Reconnect from your device.");
            }
        }
        catch (InvalidOperationException) when (context.IsClosed || token.IsCancellationRequested)
        {
            return;
        }
        finally
        {
            context.Close();
            lock (gate)
            {
                clients.Remove(context.Id);
                if (ReferenceEquals(controller, context))
                {
                    controller = null;
                    ReleaseInput();
                }
            }
            context.Dispose();
            StateChanged?.Invoke();
        }
    }

    private void PairDevice(ClientContext context, PskCredential pairing)
    {
        WirePacket packet = ReadRequired(context);
        if (packet.Kind != WireKind.PairRequest)
        {
            throw new HostRequestException("pairingRequestRequired", "A pairing request is required.");
        }
        PairDeviceRequest request = WireJson.Decode<PairDeviceRequest>(packet.Payload);
        if (request.DeviceCredential is null)
        {
            throw new HostRequestException("invalidPairingRequest", "A valid device credential is required.");
        }
        try
        {
            credentials.CompletePairing(pairing.Id, request.DeviceCredential);
        }
        catch (InvalidOperationException)
        {
            throw new HostRequestException("pairingCredentialConsumed", "The pairing code expired or was already used.");
        }
        catch (InvalidDataException)
        {
            throw new HostRequestException("invalidPairingRequest", "A fresh device credential is required.");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            ErrorOccurred?.Invoke("Device credentials could not be saved. Check local storage and try pairing again.");
            throw new HostRequestException("internalError", "The host could not save your device. Try pairing again.");
        }
        HostState state = credentials.State;
        context.Send(WirePacket.Json(WireKind.PairAccepted,
            new PairDeviceAccepted(state.HostId, state.HostName,
                HostProtocol.Platform, HostProtocol.Capabilities.ToArray())));
        PairingAccepted?.Invoke();
    }

    private void Activate(ClientContext context, bool takeover)
    {
        ClientContext? previous;
        lock (gate)
        {
            if (context.IsClosed || credentials.Find(context.CredentialId!) is null)
            {
                throw new HostRequestException("authenticationFailed", "Authentication failed.");
            }
            previous = controller;
            if (previous is not null && previous.CredentialId != context.CredentialId && !takeover)
            {
                throw new HostRequestException("hostBusy", "Another paired device is controlling this Windows PC.");
            }
            controller = null;
            if (previous is not null)
            {
                SendError(previous, "sessionTakenOver", "Another device took over this session.");
                previous.Close();
            }
            if (!ReleaseInput())
            {
                throw new HostRequestException("internalError",
                    "Windows could not release remote input. Stop the host and retry.");
            }
            controller = context;
            credentials.CancelPairing();
            context.DisableAuthenticationDeadline();
            context.RefreshActivity();
        }
        HostPermissionState permissions = desktop.PermissionState;
        context.Send(WirePacket.Json(WireKind.SessionReady,
            new SessionReady(Guid.NewGuid().ToString("D"), context.ProtocolVersion,
                context.Capabilities.ToArray(), permissions)));
        context.LastPermissions = permissions;
        context.LastDisplay = desktop.DisplayInformation;
        context.Send(WirePacket.Json(WireKind.DisplayInfo, context.LastDisplay));
        context.IsReadyToStream = true;
        StateChanged?.Invoke();
    }

    private void HandleActive(ClientContext context, WirePacket packet)
    {
        lock (gate)
        {
            if (!ReferenceEquals(controller, context) || context.IsClosed
                || credentials.Find(context.CredentialId!) is null)
            {
                throw new HostRequestException("authenticationRequired", "This session is no longer active.");
            }
            context.RefreshActivity();
            switch (packet.Kind)
            {
                case WireKind.Ping:
                    context.Send(WirePacket.Empty(WireKind.Pong));
                    return;
                case WireKind.Pong:
                    return;
                case WireKind.HostStatusRequest:
                    RequireCapability(context, "hostStatus");
                    context.Send(WirePacket.Json(WireKind.HostStatusResponse, desktop.PermissionState));
                    return;
                case WireKind.Input:
                    RequireCapability(context, "input");
                    HandleInput(context, packet);
                    return;
            }
        }
        string code = packet.Kind switch
        {
            >= WireKind.TerminalListRequest and <= WireKind.TerminalArtifactChunk
                or WireKind.TerminalRename => "terminalUnavailable",
            >= WireKind.FileListRequest and <= WireKind.FileChunk => "fileServiceUnavailable",
            >= WireKind.CaptureTargetListRequest and <= WireKind.CaptureTargetSelected => "captureTargetsUnavailable",
            _ => throw new HostRequestException("protocolMismatch", "The message is not valid for an active session."),
        };
        string message = code switch
        {
            "terminalUnavailable" => "Terminal sessions are not supported by this Windows host.",
            "fileServiceUnavailable" => "File browsing is not supported by this Windows host.",
            _ => "This Windows host shares its primary screen; app selection is not supported.",
        };
        context.Send(WirePacket.Json(WireKind.Error,
            new RemoteErrorMessage(code, message, true, packet.Kind,
                RequestIdForUnsupportedService(packet))));
    }

    private void HandleInput(ClientContext context, WirePacket packet)
    {
        try
        {
            RemoteInput input = RemoteInput.Parse(packet.Payload);
            if (!desktop.PermissionState.SessionUnlocked)
            {
                throw new DesktopOperationException("Unlock the PC or dismiss the system prompt locally before sending input.");
            }
            string summary = desktop.Handle(input);
            context.Send(WirePacket.Json(WireKind.InputAcknowledgement,
                new InputAcknowledgement(++context.InputSequence, summary)));
        }
        catch (Exception error) when (error is DesktopOperationException or InvalidDataException or JsonException)
        {
            string message = error is DesktopOperationException
                ? error.Message
                : "The input event is invalid or is not supported by this Windows host.";
            context.Send(WirePacket.Json(WireKind.Error,
                new RemoteErrorMessage("internalError", message, true, WireKind.Input)));
        }
    }

    private async Task StreamFrames(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                await Task.Delay(1000 / HostProtocol.FramesPerSecond, token).ConfigureAwait(false);
                ClientContext? context;
                lock (gate)
                {
                    context = controller;
                    if (context is null)
                    {
                        ReleaseInput();
                    }
                }
                if (context is null || context.IsClosed || !context.IsReadyToStream)
                {
                    continue;
                }
                if (context.IdleTime > lease)
                {
                    EndController(context, "sessionExpired", "The controller session expired. Reconnect to continue.");
                    continue;
                }
                if (credentials.Find(context.CredentialId!) is null)
                {
                    EndController(context, "authenticationRequired", "This device no longer has access to the host.");
                    continue;
                }

                try
                {
                    HostPermissionState permissions = desktop.PermissionState;
                    lock (gate)
                    {
                        if (!ReferenceEquals(controller, context) || context.IsClosed)
                        {
                            continue;
                        }
                        if (permissions != context.LastPermissions)
                        {
                            bool wasLocked = context.LastPermissions?.SessionUnlocked == false;
                            context.Send(WirePacket.Json(WireKind.HostStatusResponse, permissions));
                            context.LastPermissions = permissions;
                            if (!permissions.SessionUnlocked || wasLocked)
                            {
                                ReleaseInput();
                            }
                        }
                    }
                    if (!context.Capabilities.Contains("screen") || !permissions.SessionUnlocked)
                    {
                        continue;
                    }
                    DesktopFrame? frame = desktop.Capture();
                    lock (gate)
                    {
                        if (frame is null || !ReferenceEquals(controller, context) || context.IsClosed)
                        {
                            continue;
                        }
                    }
                    if (frame.Information != context.LastDisplay)
                    {
                        context.Send(WirePacket.Json(WireKind.DisplayInfo, frame.Information));
                        context.LastDisplay = frame.Information;
                    }
                    context.Send(new(WireKind.VideoFrame, frame.Jpeg));
                }
                catch (DesktopOperationException error)
                {
                    ErrorOccurred?.Invoke(error.Message);
                    EndController(context, "internalError", error.Message);
                }
                catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException)
                {
                    if (!context.IsClosed)
                    {
                        ErrorOccurred?.Invoke("Screen streaming was interrupted. Reconnect from your device.");
                    }
                    EndController(context);
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            return;
        }
    }

    private void EndController(ClientContext context, string? code = null, string? message = null)
    {
        lock (gate)
        {
            if (ReferenceEquals(controller, context))
            {
                controller = null;
                ReleaseInput();
            }
        }
        if (code is not null && message is not null)
        {
            SendError(context, code, message);
        }
        context.Close();
        StateChanged?.Invoke();
    }

    private bool ReleaseInput()
    {
        try
        {
            desktop.ReleaseInput();
            return true;
        }
        catch (DesktopOperationException error)
        {
            ErrorOccurred?.Invoke(error.Message);
            return false;
        }
    }

    private static void RequireCapability(ClientContext context, string capability)
    {
        if (!context.Capabilities.Contains(capability))
        {
            throw new HostRequestException("protocolMismatch", "The requested feature was not negotiated.");
        }
    }

    private static string? RequestIdForUnsupportedService(WirePacket packet)
    {
        if (packet.Kind != WireKind.TerminalCreateRequest)
        {
            return null;
        }
        using var document = JsonDocument.Parse(packet.Payload);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            throw new HostRequestException("internalError", "The request must be a JSON object.");
        }
        if (!document.RootElement.TryGetProperty("requestID", out JsonElement value))
        {
            return null;
        }
        if (value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.String || !Guid.TryParse(value.GetString(), out Guid id))
        {
            throw new HostRequestException("internalError", "The request identifier is invalid.");
        }
        return id.ToString("D");
    }

    private void SendError(ClientContext context, string code, string message)
    {
        if (context.IsClosed || context.Stream is null)
        {
            return;
        }
        try
        {
            context.Send(WirePacket.Json(WireKind.Error, new RemoteErrorMessage(code, message)));
        }
        catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException)
        {
            ErrorOccurred?.Invoke("A device disconnected before the host could deliver its status.");
        }
    }

    private static WirePacket ReadRequired(ClientContext context) =>
        WireCodec.Read(context.Stream!, MaximumCommandSize)
        ?? throw new EndOfStreamException();

    private sealed class HostRequestException(string code, string message) : Exception(message)
    {
        public string Code { get; } = code;
    }

    private sealed class ClientContext : IDisposable
    {
        private readonly object sendGate = new();
        private readonly CancellationTokenSource authenticationDeadline;
        private readonly CancellationTokenRegistration closeRegistration;
        private long lastActivity = Stopwatch.GetTimestamp();
        private int closed;
        private volatile bool ready;

        public ClientContext(TcpClient socket, CancellationToken token)
        {
            Socket = socket;
            socket.NoDelay = true;
            socket.ReceiveTimeout = 20_000;
            socket.SendTimeout = 5_000;
            authenticationDeadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            closeRegistration = authenticationDeadline.Token.Register(Close);
            authenticationDeadline.CancelAfter(TimeSpan.FromSeconds(12));
        }

        public Guid Id { get; } = Guid.NewGuid();
        public TcpClient Socket { get; }
        public Stream? Stream { get; set; }
        public string? CredentialId { get; set; }
        public ushort ProtocolVersion { get; set; }
        public HashSet<string> Capabilities { get; set; } = [];
        public ulong InputSequence { get; set; }
        public HostPermissionState? LastPermissions { get; set; }
        public DisplayInformation? LastDisplay { get; set; }
        public Task Completion { get; set; } = Task.CompletedTask;
        public bool IsClosed => Volatile.Read(ref closed) != 0;
        public TimeSpan IdleTime => Stopwatch.GetElapsedTime(Interlocked.Read(ref lastActivity));
        public bool IsReadyToStream { get => ready; set => ready = value; }

        public void RefreshActivity() => Interlocked.Exchange(ref lastActivity, Stopwatch.GetTimestamp());
        public void DisableAuthenticationDeadline() => authenticationDeadline.CancelAfter(Timeout.InfiniteTimeSpan);

        public void Send(WirePacket packet)
        {
            lock (sendGate)
            {
                if (IsClosed || Stream is null)
                {
                    throw new IOException("The connection is closed.");
                }
                Stream.Write(WireCodec.Encode(packet));
                Stream.Flush();
            }
        }

        public void Close()
        {
            if (Interlocked.Exchange(ref closed, 1) == 0)
            {
                Socket.Dispose();
            }
        }

        public void Dispose()
        {
            Close();
            closeRegistration.Dispose();
            authenticationDeadline.Dispose();
        }
    }
}
