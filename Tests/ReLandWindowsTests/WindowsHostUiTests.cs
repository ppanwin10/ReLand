using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Xunit;

namespace ReLand.Windows.Tests;

public sealed class WindowsHostUiTests
{
    [Fact]
    public async Task NativeHostShowsStoppedAndEmptyNetworkStatesWithoutSharing()
    {
        string desktopName = $"ReLandReview-{Guid.NewGuid():N}";
        IntPtr desktop = CreateDesktop(desktopName, IntPtr.Zero, IntPtr.Zero, 0, 0x01FF, IntPtr.Zero);
        if (desktop == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        ProcessInformation process = default;
        try
        {
            string executable = Path.Combine(AppContext.BaseDirectory, "UiReview", "ReLandWindowsUiReview.exe");
            string? artifacts = Environment.GetEnvironmentVariable("RELAND_REVIEW_ARTIFACTS");
            var command = new StringBuilder($"\"{executable}\" \"{artifacts ?? ""}\"");
            var startup = new StartupInformation
            {
                Size = (uint)Marshal.SizeOf<StartupInformation>(),
                Desktop = desktopName,
            };
            if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0,
                IntPtr.Zero, Path.GetDirectoryName(executable), ref startup, out process))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            uint waited = await Task.Run(() => WaitForSingleObject(process.Process, 15_000));
            Assert.Equal(0U, waited);
            Assert.True(GetExitCodeProcess(process.Process, out uint exitCode));
            Assert.Equal(0U, exitCode);
        }
        finally
        {
            if (process.Thread != IntPtr.Zero)
            {
                CloseHandle(process.Thread);
            }
            if (process.Process != IntPtr.Zero)
            {
                CloseHandle(process.Process);
            }
            Assert.True(CloseDesktop(desktop));
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInformation
    {
        internal uint Size;
        internal string? Reserved;
        internal string? Desktop;
        internal string? Title;
        internal uint X;
        internal uint Y;
        internal uint Width;
        internal uint Height;
        internal uint XCharacters;
        internal uint YCharacters;
        internal uint FillAttribute;
        internal uint Flags;
        internal ushort ShowWindow;
        internal ushort ReservedSize;
        internal IntPtr ReservedBytes;
        internal IntPtr StandardInput;
        internal IntPtr StandardOutput;
        internal IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        internal IntPtr Process;
        internal IntPtr Thread;
        internal uint ProcessId;
        internal uint ThreadId;
    }

    [DllImport("user32.dll", EntryPoint = "CreateDesktopW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode,
        uint flags, uint access, IntPtr security);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseDesktop(IntPtr desktop);

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(string application, StringBuilder commandLine,
        IntPtr processSecurity, IntPtr threadSecurity, [MarshalAs(UnmanagedType.Bool)] bool inherit,
        uint flags, IntPtr environment, string? directory,
        ref StartupInformation startup, out ProcessInformation process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
}
