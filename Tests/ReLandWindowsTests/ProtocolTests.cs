using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using ReLand.Windows.Core.Protocol;
using Xunit;

namespace ReLand.Windows.Tests;

public sealed class ProtocolTests
{
    [Fact]
    public void ReadsFragmentedSwiftPackets()
    {
        var packet = new WirePacket(WireKind.Input, Encoding.UTF8.GetBytes(
            """{"pointerAbsolute":{"x":0.25,"y":0.75}}"""));
        using var stream = new FragmentedStream(WireCodec.Encode(packet));

        WirePacket decoded = Assert.IsType<WirePacket>(WireCodec.Read(stream));

        Assert.Equal(packet.Kind, decoded.Kind);
        Assert.Equal(packet.Payload, decoded.Payload);
        Assert.Null(WireCodec.Read(stream));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(WireCodec.MaximumPacketSize + 1)]
    [InlineData(uint.MaxValue)]
    public void RejectsInvalidLengthsBeforeAllocating(uint length)
    {
        byte[] header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, length);
        using var stream = new MemoryStream(header);

        Assert.Throws<InvalidDataException>(() => WireCodec.Read(stream));
    }

    [Fact]
    public void SkipsOptionalExtensionsButRejectsUnknownCoreKinds()
    {
        byte[] extension = WireCodec.Encode(new((WireKind)200, [1, 2, 3]));
        byte[] pong = WireCodec.Encode(WirePacket.Empty(WireKind.Pong));
        using var stream = new FragmentedStream([.. extension, .. pong]);
        Assert.Equal(WireKind.Pong, WireCodec.Read(stream)?.Kind);

        using var reserved = new MemoryStream(WireCodec.Encode(new((WireKind)40, [])));
        Assert.Throws<InvalidDataException>(() => WireCodec.Read(reserved));
    }

    [Fact]
    public void RejectsTruncatedPackets()
    {
        using var header = new MemoryStream([0, 0]);
        using var body = new MemoryStream([0, 0, 0, 3, 7, 1]);

        Assert.Throws<EndOfStreamException>(() => WireCodec.Read(header));
        Assert.Throws<EndOfStreamException>(() => WireCodec.Read(body));
    }

    [Fact]
    public void JsonMatchesSwiftFieldNamesAndBase64Data()
    {
        var credential = new PskCredential(
            "test-device", Enumerable.Range(0, 32).Select(value => (byte)value).ToArray(), "Test Phone");
        var authentication = new AuthenticationResponse(
            credential.Id, credential.AuthenticationCode(Encoding.UTF8.GetBytes("test nonce")),
            8, ["screen", "input", "hostStatus"]);
        using var json = JsonDocument.Parse(WireJson.Encode(authentication));

        Assert.Equal("test-device", json.RootElement.GetProperty("credentialID").GetString());
        Assert.Equal(Convert.ToBase64String(authentication.AuthenticationCode),
            json.RootElement.GetProperty("authenticationCode").GetString());
        Assert.Equal(8, json.RootElement.GetProperty("protocolVersion").GetInt32());
        Assert.Equal(authentication, WireJson.Decode<AuthenticationResponse>(
            WireJson.Encode(authentication)) with
        {
            AuthenticationCode = authentication.AuthenticationCode,
            Capabilities = authentication.Capabilities,
        });
    }

    private sealed class FragmentedStream(byte[] bytes) : MemoryStream(bytes)
    {
        public override int Read(byte[] buffer, int offset, int count) =>
            base.Read(buffer, offset, Math.Min(count, 2));

        public override int Read(Span<byte> buffer) =>
            base.Read(buffer[..Math.Min(buffer.Length, 2)]);
    }
}
