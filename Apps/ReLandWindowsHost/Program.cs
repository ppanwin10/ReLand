using System.Security.Cryptography;
using System.Security.Principal;
using ReLand.Windows.Core.Desktop;
using ReLand.Windows.Core.Security;
using ReLand.Windows.Host.Desktop;
using ReLand.Windows.Host.Storage;

namespace ReLand.Windows.Host;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            MessageBox.Show("ReLand Host requires Windows 10 version 2004 or later, or Windows 11.",
                "ReLand Host", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
        {
            MessageBox.Show(
                "Run ReLand Host without administrator privileges. Elevated apps and system prompts are not supported.",
                "ReLand Host", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        try
        {
            var registry = new CredentialRegistry(new ProtectedCredentialStore());
            Application.Run(new MainForm(registry, new WindowsDesktop()));
            return 0;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException
            or CryptographicException or DesktopOperationException)
        {
            MessageBox.Show(
                "ReLand Host could not open its local configuration or desktop. "
                    + "Use the Windows account that paired this PC, check storage permissions, and restart the app.",
                "ReLand Host", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
