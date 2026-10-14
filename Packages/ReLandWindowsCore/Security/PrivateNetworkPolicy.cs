using System.Net;
using System.Net.Sockets;

namespace ReLand.Windows.Core.Security;

public static class PrivateNetworkPolicy
{
    public static bool Allows(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6)
        {
            address = address.MapToIPv4();
        }

        byte[] bytes = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            return IPAddress.IsLoopback(address)
                || (bytes[0] & 0xFE) == 0xFC
                || (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80);
        }

        return address.AddressFamily == AddressFamily.InterNetwork
            && (bytes[0] is 127 or 10
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31)
                || (bytes[0] == 100 && bytes[1] is >= 64 and <= 127));
    }
}
