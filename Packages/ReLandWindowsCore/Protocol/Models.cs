using System.Security.Cryptography;
using System.Text.Json.Serialization;

namespace ReLand.Windows.Core.Protocol;

public static class HostProtocol
{
    public const ushort DefaultPort = 45454;
    public const string Platform = "windows";
    public const int FramesPerSecond = 10;
    public static ProtocolVersionRange Versions { get; } = new(7, 8);
    public static IReadOnlySet<string> Capabilities { get; } =
        new HashSet<string>(["screen", "input", "hostStatus"], StringComparer.Ordinal);
}

public sealed record ProtocolVersionRange(ushort Minimum, ushort Maximum)
{
    public bool Contains(ushort version) =>
        Minimum <= Maximum && version >= Minimum && version <= Maximum;
}

public sealed record PskCredential(
    string Id,
    byte[] Key,
    string Name,
    bool IsPairingCredential = false)
{
    public static PskCredential Generate(string name, bool pairing = false) =>
        new(Guid.NewGuid().ToString("D"), RandomNumberGenerator.GetBytes(32), name, pairing);

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(Id)
            || Id.Length > 128
            || Id.Any(character => !char.IsAsciiLetterOrDigit(character)
                && character is not '-' and not '_' and not '.')
            || Key is null
            || Key.Length is < 32 or > 64
            || string.IsNullOrWhiteSpace(Name)
            || Name.Length > 256
            || Name.Any(char.IsControl))
        {
            throw new InvalidDataException("The security credential is invalid.");
        }
    }

    public byte[] AuthenticationCode(byte[] challenge) =>
        HMACSHA256.HashData(Key, challenge);

    public bool Validates(byte[] code, byte[] challenge) =>
        code is not null
        && code.Length == 32
        && CryptographicOperations.FixedTimeEquals(AuthenticationCode(challenge), code);
}

public sealed record AuthenticationChallenge(
    byte[] Nonce,
    ProtocolVersionRange SupportedVersions,
    string[] Capabilities);

public sealed record AuthenticationResponse(
    [property: JsonPropertyName("credentialID")] string CredentialId,
    byte[] AuthenticationCode,
    ushort ProtocolVersion,
    string[] Capabilities,
    bool RequestsControllerTakeover = false);

public sealed record PairDeviceRequest(PskCredential DeviceCredential);

public sealed record PairDeviceAccepted(
    [property: JsonPropertyName("hostID")] string HostId,
    string HostName,
    string HostPlatform,
    string[] Capabilities);

public sealed record SessionReady(
    [property: JsonPropertyName("sessionID")] string SessionId,
    ushort ProtocolVersion,
    string[] Capabilities,
    HostPermissionState HostPermissions,
    string HostPlatform = HostProtocol.Platform);

public sealed record HostPermissionState(
    bool ScreenRecordingGranted,
    bool AccessibilityGranted,
    bool SessionUnlocked)
{
    public static HostPermissionState Granted { get; } = new(true, true, true);
}

public sealed record DisplayInformation(
    int Width,
    int Height,
    int FramesPerSecond = HostProtocol.FramesPerSecond,
    string Encoding = "jpeg");

public sealed record InputAcknowledgement(ulong Sequence, string Summary);

public sealed record RemoteErrorMessage(
    string Code,
    string Message,
    bool IsRecoverable = false,
    WireKind? RequestKind = null,
    [property: JsonPropertyName("requestID")] string? RequestId = null);

public sealed record HostState(
    [property: JsonPropertyName("hostID")] string HostId,
    string HostName,
    PskCredential[] Credentials);
