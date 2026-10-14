using ReLand.Windows.Core.Input;
using ReLand.Windows.Core.Protocol;

namespace ReLand.Windows.Core.Desktop;

public sealed record DesktopFrame(DisplayInformation Information, byte[] Jpeg);

public sealed class DesktopOperationException(string message, Exception? inner = null)
    : Exception(message, inner);

public interface IRemoteDesktop
{
    DisplayInformation DisplayInformation { get; }
    HostPermissionState PermissionState { get; }
    DesktopFrame? Capture();
    string Handle(RemoteInput input);
    void ReleaseInput();
}
