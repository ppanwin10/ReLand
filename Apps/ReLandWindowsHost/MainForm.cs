using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using QRCoder;
using ReLand.Windows.Core.Desktop;
using ReLand.Windows.Core.Hosting;
using ReLand.Windows.Core.Protocol;
using ReLand.Windows.Core.Security;
using ReLand.Windows.Host.Desktop;

namespace ReLand.Windows.Host;

internal sealed class MainForm : Form
{
    private readonly CredentialRegistry credentials;
    private readonly RemoteHostServer server;
    private readonly Func<IEnumerable<(string Name, IPAddress Address)>> networkAddresses;
    private readonly ComboBox addresses = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly Button refreshAddresses = new() { Text = "Refresh addresses", AutoSize = true };
    private readonly Button startStop = new() { Text = "Start Host", AutoSize = true };
    private readonly Button createCode = new() { Text = "Create one-time code", AutoSize = true };
    private readonly Button forgetDevice = new() { Text = "Forget selected device", AutoSize = true };
    private readonly Label status = new() { Text = "Stopped", AutoSize = true };
    private readonly Label networkStatus = new() { AutoSize = true, MaximumSize = new(540, 0) };
    private readonly Label pairingStatus = new() { AutoSize = true, MaximumSize = new(540, 0) };
    private readonly Label errorStatus = new() { AutoSize = true, MaximumSize = new(540, 0) };
    private readonly PictureBox qr = new()
    {
        Size = new(360, 360), SizeMode = PictureBoxSizeMode.Zoom, TabStop = false, Visible = false,
    };
    private readonly ListBox devices = new() { Dock = DockStyle.Fill, Height = 100 };
    private readonly System.Windows.Forms.Timer expiryTimer = new() { Interval = 1000 };
    private bool windowProtected;
    private bool busy;
    private volatile bool closing;
    private bool allowClose;

    public MainForm(
        CredentialRegistry credentials,
        IRemoteDesktop desktop,
        Func<IEnumerable<(string Name, IPAddress Address)>>? networkAddresses = null)
    {
        this.credentials = credentials;
        this.networkAddresses = networkAddresses ?? AvailableAddresses;
        server = new(credentials, desktop);
        Text = "ReLand Host";
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new(620, 840);
        MinimumSize = new(580, 600);
        StartPosition = FormStartPosition.CenterScreen;
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, AutoScroll = true, ColumnCount = 1,
            Padding = new(20), AutoSize = false,
        };
        layout.ColumnStyles.Add(new(SizeType.Percent, 100));
        Add(layout, new Label { Text = "Share your Windows PC", AutoSize = true, Font = new(Font, FontStyle.Bold) });
        Add(layout, new Label
        {
            Text = "Pair your iPhone or iPad to view the primary screen and control mouse and keyboard.",
            AutoSize = true, MaximumSize = new(540, 0),
        });
        Add(layout, status);
        Add(layout, new Label { Text = "Private LAN or Tailscale address", AutoSize = true });
        Add(layout, addresses);
        Add(layout, networkStatus);
        Add(layout, refreshAddresses);
        Add(layout, startStop);
        Add(layout, new Label
        {
            Text = "Keep this app running. Public internet access, the Windows login screen, "
                + "system prompts, terminals, and files are not supported.",
            AutoSize = true, MaximumSize = new(540, 0),
        });
        Add(layout, createCode);
        Add(layout, pairingStatus);
        Add(layout, qr);
        Add(layout, new Label { Text = "Paired devices", AutoSize = true });
        Add(layout, devices);
        Add(layout, forgetDevice);
        Add(layout, errorStatus);
        Controls.Add(layout);
        AcceptButton = startStop;
        addresses.AccessibleName = "Private network address";
        qr.AccessibleName = "One-time ReLand pairing QR code";
        qr.AccessibleDescription = "Scan this code with the ReLand app on your iPhone or iPad.";
        devices.AccessibleName = "Paired devices";
        startStop.Click += async (_, _) => await ChangeHostState();
        createCode.Click += (_, _) => CreatePairingCode();
        refreshAddresses.Click += (_, _) => LoadAddresses();
        forgetDevice.Click += (_, _) => ForgetDevice();
        devices.SelectedIndexChanged += (_, _) => RefreshButtons();
        expiryTimer.Tick += (_, _) =>
        {
            server.RefreshIdleInput();
            UpdatePairingStatus();
        };
        server.StateChanged += ServerChanged;
        server.PairingAccepted += ServerChanged;
        server.ErrorOccurred += ServerError;
        LoadAddresses();
        RefreshState();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        windowProtected = NativeMethods.SetWindowDisplayAffinity(Handle, 0x11);
        if (!windowProtected)
        {
            ShowError("Windows could not protect the pairing window from screen capture. "
                + "Pairing is disabled; restart ReLand Host and retry.");
        }
        RefreshButtons();
        expiryTimer.Start();
    }

    protected override async void OnFormClosing(FormClosingEventArgs e)
    {
        if (allowClose)
        {
            base.OnFormClosing(e);
            return;
        }
        e.Cancel = true;
        base.OnFormClosing(e);
        if (closing)
        {
            return;
        }
        if (server.HasController && MessageBox.Show(
            "Close ReLand Host and disconnect the controlling device?", "Stop sharing this PC?",
            MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
        {
            return;
        }
        closing = true;
        expiryTimer.Stop();
        server.StateChanged -= ServerChanged;
        server.PairingAccepted -= ServerChanged;
        server.ErrorOccurred -= ServerError;
        await server.StopAsync();
        ClearQr();
        expiryTimer.Dispose();
        allowClose = true;
        Close();
    }

    private static void Add(TableLayoutPanel layout, Control control)
    {
        int row = layout.RowCount++;
        layout.RowStyles.Add(new(SizeType.AutoSize));
        control.Margin = new(0, 0, 0, 12);
        layout.Controls.Add(control, 0, row);
    }

    private void LoadAddresses()
    {
        addresses.Items.Clear();
        networkStatus.Text = "";
        try
        {
            foreach ((string name, IPAddress address) in networkAddresses())
            {
                addresses.Items.Add(new AddressChoice(name, address));
            }
            if (addresses.Items.Count > 0)
            {
                addresses.SelectedIndex = 0;
            }
            else
            {
                networkStatus.Text = "Connect to a private LAN or sign into Tailscale, then refresh addresses.";
            }
        }
        catch (NetworkInformationException)
        {
            networkStatus.Text = "Windows could not list private network addresses. Check your connection and refresh.";
        }
        RefreshButtons();
    }

    private static IEnumerable<(string Name, IPAddress Address)> AvailableAddresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(network => network.OperationalStatus == OperationalStatus.Up
                && network.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(network => network.GetIPProperties().UnicastAddresses
                .Where(address => address.Address.AddressFamily == AddressFamily.InterNetwork
                    && PrivateNetworkPolicy.Allows(address.Address))
                .Select(address => (Name: network.Name, Address: address.Address)))
            .DistinctBy(value => value.Address)
            .OrderBy(value => value.Address.GetAddressBytes()[0] == 100);

    private async Task ChangeHostState()
    {
        if (busy)
        {
            return;
        }
        if (server.IsRunning && server.HasController && MessageBox.Show(
            "The controlling device will disconnect.", "Stop sharing this PC?",
            MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
        {
            return;
        }
        busy = true;
        errorStatus.Text = "";
        RefreshButtons();
        try
        {
            if (server.IsRunning)
            {
                await server.StopAsync();
                ClearQr();
            }
            else if (addresses.SelectedItem is AddressChoice choice)
            {
                await server.StopAsync();
                server.Start(choice.Address);
            }
            else
            {
                ShowError("Select a private network address before starting the host.");
            }
        }
        catch (SocketException)
        {
            ShowError("ReLand could not listen on this address. Refresh addresses, close any other ReLand Host, and retry.");
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException)
        {
            ShowError(error.Message);
        }
        finally
        {
            busy = false;
            RefreshState();
        }
    }

    private void CreatePairingCode()
    {
        try
        {
            string payload = server.CreatePairingCode();
            using var generator = new QRCodeGenerator();
            using QRCodeData data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.Q);
            using var code = new PngByteQRCode(data);
            using var stream = new MemoryStream(code.GetGraphic(6));
            using Image image = Image.FromStream(stream);
            ClearQr();
            qr.Image = new Bitmap(image);
            qr.Visible = true;
            errorStatus.Text = "";
            UpdatePairingStatus();
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException)
        {
            credentials.CancelPairing();
            ClearQr();
            ShowError(error.Message);
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            credentials.CancelPairing();
            ClearQr();
            ShowError("The pairing code could not be created. Check the host status and try again.");
        }
    }

    private void ForgetDevice()
    {
        if (devices.SelectedItem is not DeviceChoice device)
        {
            return;
        }
        if (MessageBox.Show($"Remove access for {device.Name}? The device will need to pair again.",
            "Forget this device?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2) != DialogResult.Yes)
        {
            return;
        }
        try
        {
            credentials.Remove(device.Id);
            server.DisconnectDevice(device.Id);
            errorStatus.Text = "";
            RefreshState();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            ShowError("The device could not be removed from local storage. Check storage permissions and retry.");
        }
    }

    private void RefreshState()
    {
        status.Text = server.HasController ? "A paired device is controlling this PC"
            : server.IsRunning ? "Ready for a paired device" : "Stopped";
        string? selectedId = (devices.SelectedItem as DeviceChoice)?.Id;
        devices.Items.Clear();
        foreach (PskCredential credential in credentials.State.Credentials)
        {
            var choice = new DeviceChoice(credential.Id, credential.Name);
            devices.Items.Add(choice);
            if (choice.Id == selectedId)
            {
                devices.SelectedItem = choice;
            }
        }
        UpdatePairingStatus();
        RefreshButtons();
    }

    private void RefreshButtons()
    {
        startStop.Text = server.IsRunning ? "Stop Host" : "Start Host";
        startStop.Enabled = !busy && (server.IsRunning || addresses.SelectedItem is AddressChoice);
        addresses.Enabled = !busy && !server.IsRunning;
        refreshAddresses.Enabled = !busy && !server.IsRunning;
        createCode.Enabled = !busy && windowProtected && server.IsRunning && !server.HasController;
        forgetDevice.Enabled = !busy && devices.SelectedItem is DeviceChoice;
    }

    private void UpdatePairingStatus()
    {
        if (credentials.PendingPairing is { } pairing && qr.Image is not null)
        {
            TimeSpan remaining = pairing.ExpiresAt - DateTimeOffset.UtcNow;
            pairingStatus.Text = $"Scan with ReLand on your iPhone or iPad. Expires in {remaining.Minutes:00}:{remaining.Seconds:00}.";
        }
        else
        {
            bool hadCode = qr.Image is not null;
            ClearQr();
            pairingStatus.Text = hadCode && !server.HasController
                ? "The code expired or was used. Create a new one to pair another device."
                : "Initial pairing requires physical access to this PC.";
        }
    }

    private void ClearQr()
    {
        Image? image = qr.Image;
        qr.Image = null;
        qr.Visible = false;
        image?.Dispose();
    }

    private void ShowError(string message) => errorStatus.Text = "Error: " + message;
    private void ServerChanged() => Dispatch(RefreshState);
    private void ServerError(string message) => Dispatch(() => ShowError(message));

    private void Dispatch(Action action)
    {
        if (closing || IsDisposed || !IsHandleCreated)
        {
            return;
        }
        BeginInvoke(() =>
        {
            if (!closing && !IsDisposed)
            {
                action();
            }
        });
    }

    private sealed record AddressChoice(string InterfaceName, IPAddress Address)
    {
        public override string ToString() => $"{InterfaceName} - {Address}";
    }

    private sealed record DeviceChoice(string Id, string Name)
    {
        public override string ToString() => Name;
    }
}
