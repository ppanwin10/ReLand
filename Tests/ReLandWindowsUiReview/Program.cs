using System.Drawing.Imaging;
using ReLand.Windows.Core.Desktop;
using ReLand.Windows.Core.Input;
using ReLand.Windows.Core.Protocol;
using ReLand.Windows.Core.Security;
using ReLand.Windows.Host;

namespace ReLand.Windows.UiReview;

internal static class Program
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var deadline = new System.Threading.Timer(_ => Environment.Exit(1),
            null, TimeSpan.FromSeconds(10), Timeout.InfiniteTimeSpan);
        var service = new ReviewDesktop();
        var registry = new CredentialRegistry(new ReviewCredentialStore());
        using var form = new MainForm(registry, service, () => []);
        int result = 1;
        form.Shown += (_, _) =>
        {
            TaskScheduler scheduler = TaskScheduler.FromCurrentSynchronizationContext();
            Task review = Task.Factory.StartNew(() => Review(form, service,
                arguments.FirstOrDefault()), CancellationToken.None, TaskCreationOptions.None, scheduler);
            _ = review.ContinueWith(completed =>
            {
                result = completed.IsFaulted ? 1 : 0;
                if (completed.IsFaulted && arguments.FirstOrDefault() is { Length: > 0 } artifacts)
                {
                    Directory.CreateDirectory(artifacts);
                    File.WriteAllText(Path.Combine(artifacts, "windows-ui-review-error.log"),
                        completed.Exception!.GetBaseException().Message);
                }
                form.Close();
            }, CancellationToken.None, TaskContinuationOptions.None, scheduler);
        };
        Application.Run(form);
        return result;
    }

    private static void Review(MainForm form, ReviewDesktop service, string? artifacts)
    {
        Control[] controls = Descendants(form).ToArray();
        Require(form.Text == "ReLand Host", "The host window title is incorrect.");
        Require(!controls.OfType<Button>().Single(button => button.Text == "Start Host").Enabled,
            "The host must not start when there is no private network address.");
        Require(!controls.OfType<Button>().Single(button => button.Text == "Create one-time code").Enabled,
            "Pairing must be disabled while the host is stopped.");
        Require(controls.OfType<Label>().Any(label => label.Text == "Stopped"),
            "The stopped state is missing.");
        Require(controls.OfType<Label>().Any(label => label.Text.Contains(
            "Connect to a private LAN", StringComparison.Ordinal)), "The empty network guidance is missing.");
        Require(controls.OfType<ListBox>().Single().Items[0]?.ToString() == "Example paired phone",
            "The paired-device list is missing.");
        Require(controls.OfType<PictureBox>().Single().Image is null, "A stopped host must not show a pairing QR.");
        Require(!controls.OfType<PictureBox>().Single().Visible, "The empty QR area must not hide device or error controls.");
        Require(service.CaptureCount == 0 && service.InputCount == 0, "The stopped host must not capture or inject input.");

        using var bitmap = new Bitmap(form.Width, form.Height);
        form.DrawToBitmap(bitmap, new(Point.Empty, form.Size));
        if (!string.IsNullOrEmpty(artifacts))
        {
            Directory.CreateDirectory(artifacts);
            bitmap.Save(Path.Combine(artifacts, "windows-host-empty-network.png"), ImageFormat.Png);
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control child in parent.Controls)
        {
            yield return child;
            foreach (Control descendant in Descendants(child))
            {
                yield return descendant;
            }
        }
    }

    private sealed class ReviewCredentialStore : IHostCredentialStore
    {
        private HostState state = new(Guid.NewGuid().ToString("D"), "Example Windows PC",
            [PskCredential.Generate("Example paired phone")]);
        public HostState Load() => state;
        public void Save(HostState value) => state = value;
    }

    private sealed class ReviewDesktop : IRemoteDesktop
    {
        public int CaptureCount { get; private set; }
        public int InputCount { get; private set; }
        public DisplayInformation DisplayInformation => new(640, 480);
        public HostPermissionState PermissionState => HostPermissionState.Granted;
        public DesktopFrame Capture()
        {
            CaptureCount++;
            return new(DisplayInformation, []);
        }
        public string Handle(RemoteInput input)
        {
            InputCount++;
            return "Synthetic input";
        }
        public void ReleaseInput() {}
    }
}
