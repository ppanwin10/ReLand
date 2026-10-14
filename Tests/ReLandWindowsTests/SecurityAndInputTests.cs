using System.Net;
using System.Text;
using ReLand.Windows.Core.Input;
using ReLand.Windows.Core.Protocol;
using ReLand.Windows.Core.Security;
using Xunit;

namespace ReLand.Windows.Tests;

public sealed class SecurityAndInputTests
{
    [Theory]
    [InlineData("127.0.0.1", true)]
    [InlineData("10.1.2.3", true)]
    [InlineData("172.16.4.5", true)]
    [InlineData("172.31.255.255", true)]
    [InlineData("172.32.0.1", false)]
    [InlineData("192.168.10.20", true)]
    [InlineData("100.64.0.1", true)]
    [InlineData("100.127.255.255", true)]
    [InlineData("100.128.0.1", false)]
    [InlineData("169.254.10.20", true)]
    [InlineData("fd7a:115c:a1e0::1", true)]
    [InlineData("fe80::1", true)]
    [InlineData("::1", true)]
    [InlineData("::ffff:192.168.1.20", true)]
    [InlineData("::ffff:203.0.113.10", false)]
    [InlineData("8.8.8.8", false)]
    [InlineData("203.0.113.10", false)]
    [InlineData("2001:db8::1", false)]
    [InlineData("0.0.0.0", false)]
    [InlineData("::", false)]
    public void EnforcesPrivateNetworkBoundary(string address, bool allowed) =>
        Assert.Equal(allowed, PrivateNetworkPolicy.Allows(IPAddress.Parse(address)));

    [Theory]
    [InlineData("""{"pointerDelta":{"x":1,"y":-2}}""", typeof(RemoteInput.PointerDelta))]
    [InlineData("""{"pointerAbsolute":{"x":0,"y":1}}""", typeof(RemoteInput.PointerAbsolute))]
    [InlineData("""{"button":{"button":"right","isDown":true,"clickCount":2}}""", typeof(RemoteInput.Button))]
    [InlineData("""{"scroll":{"x":0,"y":-120}}""", typeof(RemoteInput.Scroll))]
    [InlineData("""{"text":{"_0":"Hello \uD83D\uDC4B"}}""", typeof(RemoteInput.Text))]
    [InlineData("""{"key":{"code":53,"isDown":false,"modifiers":0}}""", typeof(RemoteInput.Key))]
    public void ReadsSwiftSynthesizedInputEnums(string json, Type type) =>
        Assert.IsType(type, RemoteInput.Parse(Encoding.UTF8.GetBytes(json)));

    [Theory]
    [InlineData("""{}""")]
    [InlineData("""{"pointerAbsolute":{"x":2,"y":0}}""")]
    [InlineData("""{"pointerDelta":{"x":1e300,"y":0}}""")]
    [InlineData("""{"scroll":{"x":0,"y":1000000}}""")]
    [InlineData("""{"button":{"button":"middle","isDown":true,"clickCount":1}}""")]
    [InlineData("""{"text":{"_0":""}}""")]
    [InlineData("""{"text":{"_0":"\u0000"}}""")]
    [InlineData("""{"key":{"code":65535,"isDown":true,"modifiers":0}}""")]
    [InlineData("""{"key":{"code":53,"isDown":true,"modifiers":1}}""")]
    [InlineData("""{"pointerDelta":{"x":1}}""")]
    [InlineData("""{"text":{"_0":"a"},"key":{"code":53,"isDown":true,"modifiers":0}}""")]
    public void RejectsInvalidInputBeforeNativeCalls(string json) =>
        Assert.Throws<InvalidDataException>(() => RemoteInput.Parse(Encoding.UTF8.GetBytes(json)));

    [Theory]
    [InlineData(0, 0x41)]
    [InlineData(8, 0x43)]
    [InlineData(36, 0x0D)]
    [InlineData(48, 0x09)]
    [InlineData(51, 0x08)]
    [InlineData(53, 0x1B)]
    [InlineData(55, 0x5B)]
    [InlineData(123, 0x25)]
    [InlineData(124, 0x27)]
    [InlineData(125, 0x28)]
    [InlineData(126, 0x26)]
    public void MapsMacWireKeyCodesToWindowsKeys(ushort code, ushort expected)
    {
        Assert.True(WindowsKeyMap.TryTranslate(code, out ushort key));
        Assert.Equal(expected, key);
    }

    [Fact]
    public void MapsCommandToWindowsAndOptionToAlt()
    {
        Assert.Equal(new ushort[] { 0xA0, 0xA2, 0xA4, 0x5B },
            WindowsKeyMap.Modifiers(WindowsKeyMap.AllowedModifiers));
        Assert.True(WindowsKeyMap.IsExtended(0x25));
        Assert.False(WindowsKeyMap.IsExtended(0x41));
    }

    [Fact]
    public void HmacRejectsWrongChallengeAndTruncatedCode()
    {
        PskCredential credential = PskCredential.Generate("Test Phone");
        byte[] first = Encoding.UTF8.GetBytes("first challenge");
        byte[] second = Encoding.UTF8.GetBytes("second challenge");
        byte[] code = credential.AuthenticationCode(first);
        Assert.True(credential.Validates(code, first));
        Assert.False(credential.Validates(code, second));
        Assert.False(credential.Validates(code[..16], first));
    }
}
