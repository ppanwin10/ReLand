using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using ReLand.Windows.Core.Desktop;

namespace ReLand.Windows.Host.Desktop;

internal interface IWindowsInputBackend
{
    bool IsInteractiveDesktop { get; }
    Rectangle PrimaryBounds { get; }
    Rectangle VirtualBounds { get; }
    NativeMethods.Point CursorPosition { get; }
    uint Send(NativeMethods.Input[] inputs);
}

internal sealed class WindowsInputBackend : IWindowsInputBackend
{
    public Rectangle PrimaryBounds =>
        Screen.PrimaryScreen?.Bounds
        ?? throw new DesktopOperationException("No primary display is available. Connect a display and retry.");

    public Rectangle VirtualBounds => SystemInformation.VirtualScreen;

    public NativeMethods.Point CursorPosition
    {
        get
        {
            if (!NativeMethods.GetCursorPos(out NativeMethods.Point point))
            {
                throw new DesktopOperationException("Windows could not read the pointer position.",
                    new Win32Exception(Marshal.GetLastWin32Error()));
            }
            return point;
        }
    }

    public bool IsInteractiveDesktop
    {
        get
        {
            IntPtr desktop = NativeMethods.OpenInputDesktop(0, false, 0x0001);
            if (desktop == IntPtr.Zero)
            {
                return false;
            }
            try
            {
                NativeMethods.GetUserObjectInformation(desktop, 2, null, 0, out int needed);
                if (needed is < 2 or > 2048)
                {
                    throw DesktopStatusFailure();
                }
                var name = new StringBuilder(needed / 2);
                if (!NativeMethods.GetUserObjectInformation(desktop, 2, name, needed, out _))
                {
                    throw DesktopStatusFailure();
                }
                return string.Equals(name.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
            }
            finally
            {
                NativeMethods.CloseDesktop(desktop);
            }
        }
    }

    public uint Send(NativeMethods.Input[] inputs) =>
        NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>());

    private static DesktopOperationException DesktopStatusFailure() =>
        new("Windows could not determine whether the desktop is unlocked.",
            new Win32Exception(Marshal.GetLastWin32Error()));
}
