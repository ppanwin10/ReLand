using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ReLand.Windows.Core.Protocol;

public enum WireKind : byte
{
    Challenge = 1,
    Authenticate = 2,
    PairRequest = 3,
    PairAccepted = 4,
    SessionReady = 5,
    DisplayInfo = 6,
    VideoFrame = 7,
    Input = 8,
    InputAcknowledgement = 9,
    Ping = 10,
    Pong = 11,
    Error = 12,
    TerminalListRequest = 13,
    TerminalListResponse = 14,
    TerminalCreateRequest = 15,
    TerminalAttachRequest = 16,
    TerminalAttached = 17,
    TerminalOutput = 18,
    TerminalInput = 19,
    TerminalResize = 20,
    TerminalDetach = 21,
    TerminalDetached = 22,
    TerminalOpenOnMac = 23,
    TerminalKill = 24,
    TerminalArtifactListRequest = 25,
    TerminalArtifactListResponse = 26,
    TerminalArtifactReadRequest = 27,
    TerminalArtifactChunk = 28,
    FileListRequest = 29,
    FileListResponse = 30,
    FileReadRequest = 31,
    FileChunk = 32,
    CaptureTargetListRequest = 33,
    CaptureTargetListResponse = 34,
    CaptureTargetSelectRequest = 35,
    CaptureTargetSelected = 36,
    HostStatusRequest = 37,
    HostStatusResponse = 38,
    TerminalRename = 39,
}

public sealed record WirePacket(WireKind Kind, byte[] Payload)
{
    public static WirePacket Empty(WireKind kind) => new(kind, []);

    public static WirePacket Json<T>(WireKind kind, T value) =>
        new(kind, WireJson.Encode(value));
}

public static class WireJson
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        MaxDepth = 16,
    };

    public static byte[] Encode<T>(T value) =>
        JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T Decode<T>(byte[] bytes) =>
        JsonSerializer.Deserialize<T>(bytes, Options)
        ?? throw new JsonException("A non-null message is required.");
}

public static class WireCodec
{
    public const int MaximumPacketSize = 8 * 1024 * 1024;

    public static byte[] Encode(WirePacket packet)
    {
        int bodyLength = checked(packet.Payload.Length + 1);
        if (bodyLength > MaximumPacketSize)
        {
            throw new InvalidDataException("The packet exceeds the protocol limit.");
        }

        byte[] bytes = new byte[4 + bodyLength];
        BinaryPrimitives.WriteUInt32BigEndian(bytes, (uint)bodyLength);
        bytes[4] = (byte)packet.Kind;
        packet.Payload.CopyTo(bytes, 5);
        return bytes;
    }

    public static WirePacket? Read(Stream stream, int maximumBodyLength = MaximumPacketSize)
    {
        Span<byte> header = stackalloc byte[4];
        Span<byte> discard = stackalloc byte[4096];
        while (true)
        {
            if (stream.Read(header[..1]) == 0)
            {
                return null;
            }

            stream.ReadExactly(header[1..]);
            uint length = BinaryPrimitives.ReadUInt32BigEndian(header);
            if (length is < 1 or > MaximumPacketSize || length > maximumBodyLength)
            {
                throw new InvalidDataException("The packet length is invalid.");
            }

            int kind = stream.ReadByte();
            if (kind < 0)
            {
                throw new EndOfStreamException();
            }

            int remaining = (int)length - 1;
            if (kind >= 128)
            {
                while (remaining > 0)
                {
                    int count = Math.Min(remaining, discard.Length);
                    stream.ReadExactly(discard[..count]);
                    remaining -= count;
                }
                continue;
            }

            if (!Enum.IsDefined((WireKind)kind))
            {
                throw new InvalidDataException("The core message kind is unknown.");
            }

            byte[] payload = new byte[remaining];
            stream.ReadExactly(payload);
            return new((WireKind)kind, payload);
        }
    }
}
