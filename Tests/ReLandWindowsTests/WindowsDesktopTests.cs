using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using ReLand.Windows.Core.Desktop;
using ReLand.Windows.Core.Input;
using ReLand.Windows.Host.Desktop;
using Xunit;

namespace ReLand.Windows.Tests;

public sealed class WindowsDesktopTests
{
    [Fact]
    public void NativeInputLayoutMatchesWindowsAbi()
    {
        Assert.Equal(IntPtr.Size == 8 ? 40 : 28, Marshal.SizeOf<NativeMethods.Input>());
        Assert.Equal(IntPtr.Size == 8 ? 8 : 4,
            Marshal.OffsetOf<NativeMethods.Input>(nameof(NativeMethods.Input.Data)).ToInt32());
    }

    [Theory]
    [InlineData(3840, 2160, 1920, 1080)]
    [InlineData(2160, 3840, 1080, 1920)]
    [InlineData(640, 480, 640, 480)]
    [InlineData(1, 1, 1, 1)]
    public void BoundsFramesTo1920PixelsWithoutUpscaling(int width, int height, int expectedWidth, int expectedHeight) =>
        Assert.Equal((expectedWidth, expectedHeight), DesktopGeometry.ScaledSize(width, height));

    [Fact]
    public void MapsAbsolutePointerToPrimaryDisplayInsideNegativeOriginVirtualDesktop()
    {
        var primary = new ScreenBounds(0, 0, 1920, 1080);
        var virtualDesktop = new ScreenBounds(-1920, 0, 3840, 1080);
        (int left, int top) = DesktopGeometry.AbsolutePointer(0, 0, primary, virtualDesktop);
        (int right, int bottom) = DesktopGeometry.AbsolutePointer(1, 1, primary, virtualDesktop);
        Assert.InRange(left, 32767, 32777);
        Assert.Equal(0, top);
        Assert.Equal(65535, right);
        Assert.Equal(65535, bottom);
        Assert.Equal((0, 0), DesktopGeometry.AbsolutePointer(0, 0,
            new(0, 0, 1, 1), new(0, 0, 1, 1)));
    }

    [Fact]
    public void NativePointerUsesVirtualDesktopAbsoluteFlags()
    {
        var backend = new TestInputBackend();
        var desktop = new WindowsDesktop(backend);
        desktop.Handle(new RemoteInput.PointerAbsolute(1, 1));
        NativeMethods.Input input = Assert.Single(Assert.Single(backend.Calls));
        Assert.Equal(65535, input.Data.Mouse.X);
        Assert.Equal(65535, input.Data.Mouse.Y);
        Assert.Equal(NativeMethods.MouseMove | NativeMethods.Absolute | NativeMethods.VirtualDesktop,
            input.Data.Mouse.Flags);
    }

    [Fact]
    public void DisconnectReleasesHeldMouseButtonsAndKeys()
    {
        var backend = new TestInputBackend();
        var desktop = new WindowsDesktop(backend);
        desktop.Handle(new RemoteInput.Key(8, true, WindowsKeyMap.Control));
        desktop.Handle(new RemoteInput.Button("left", true, 1));
        desktop.ReleaseInput();
        NativeMethods.Input[] released = backend.Calls.Last();
        Assert.Contains(released, input => input.Type == 1 && input.Data.Keyboard.VirtualKey == 0x43
            && (input.Data.Keyboard.Flags & NativeMethods.KeyUp) != 0);
        Assert.Contains(released, input => input.Type == 1 && input.Data.Keyboard.VirtualKey == 0xA2
            && (input.Data.Keyboard.Flags & NativeMethods.KeyUp) != 0);
        Assert.Contains(released, input => input.Type == 0 && input.Data.Mouse.Flags == NativeMethods.LeftUp);
    }

    [Fact]
    public void KeyUpReleasesModifiersAndExtendedKeyState()
    {
        var backend = new TestInputBackend();
        var desktop = new WindowsDesktop(backend);
        desktop.Handle(new RemoteInput.Key(8, true, WindowsKeyMap.Control));
        Assert.Equal(new ushort[] { 0xA2, 0x43 },
            backend.Calls.Last().Select(value => value.Data.Keyboard.VirtualKey));
        desktop.Handle(new RemoteInput.Key(8, false, WindowsKeyMap.Control));
        Assert.Equal(new ushort[] { 0x43, 0xA2 },
            backend.Calls.Last().Select(value => value.Data.Keyboard.VirtualKey));
        Assert.All(backend.Calls.Last(), value =>
            Assert.NotEqual(0U, value.Data.Keyboard.Flags & NativeMethods.KeyUp));

        desktop.Handle(new RemoteInput.Key(76, true, 0));
        desktop.ReleaseInput();
        NativeMethods.Input released = Assert.Single(backend.Calls.Last());
        Assert.Equal(NativeMethods.KeyUp | NativeMethods.KeyExtended, released.Data.Keyboard.Flags);
    }

    [Fact]
    public void PartialNativeSendIsReportedAndOnlyAcceptedKeysAreReleased()
    {
        var backend = new TestInputBackend { AcceptedCount = 1 };
        var desktop = new WindowsDesktop(backend);
        Assert.Throws<DesktopOperationException>(() =>
            desktop.Handle(new RemoteInput.Key(8, true, WindowsKeyMap.Control)));
        backend.AcceptedCount = null;
        desktop.ReleaseInput();
        NativeMethods.Input released = Assert.Single(backend.Calls.Last());
        Assert.Equal(0xA2, released.Data.Keyboard.VirtualKey);
        Assert.NotEqual(0U, released.Data.Keyboard.Flags & NativeMethods.KeyUp);
    }

    [Fact]
    public void SecureDesktopBlocksInputAndDefersReleasingUntilUnlock()
    {
        var backend = new TestInputBackend();
        var desktop = new WindowsDesktop(backend);
        desktop.Handle(new RemoteInput.Key(8, true, WindowsKeyMap.Control));
        backend.Unlocked = false;
        int before = backend.Calls.Count;
        Assert.Throws<DesktopOperationException>(() => desktop.Handle(new RemoteInput.Text("blocked")));
        desktop.ReleaseInput();
        Assert.Equal(before, backend.Calls.Count);
        Assert.False(desktop.PermissionState.SessionUnlocked);

        backend.Unlocked = true;
        desktop.Handle(new RemoteInput.Key(53, true, 0));
        Assert.All(backend.Calls[before], value =>
            Assert.NotEqual(0U, value.Data.Keyboard.Flags & NativeMethods.KeyUp));
        Assert.Equal(0x1B, Assert.Single(backend.Calls.Last()).Data.Keyboard.VirtualKey);
    }

    [Fact]
    public void UnicodeTextUsesUtf16PacketsWithoutClipboardAndBoundedBatches()
    {
        var backend = new TestInputBackend();
        var desktop = new WindowsDesktop(backend);
        string text = "Test \uD83D\uDC4B";
        desktop.Handle(new RemoteInput.Text(text));
        NativeMethods.Input[] inputs = backend.Calls.SelectMany(value => value).ToArray();
        Assert.All(inputs, value => Assert.NotEqual(0U, value.Data.Keyboard.Flags & NativeMethods.KeyUnicode));
        char[] characters = inputs.Where(value => (value.Data.Keyboard.Flags & NativeMethods.KeyUp) == 0)
            .Select(value => (char)value.Data.Keyboard.ScanCode).ToArray();
        Assert.Equal(text, new string(characters));

        backend.Calls.Clear();
        desktop.Handle(new RemoteInput.Text(new string('a', 4096)));
        Assert.All(backend.Calls, value => Assert.InRange(value.Length, 1, 128));
        Assert.Equal(8192, backend.Calls.Sum(value => value.Length));
    }

    [Fact]
    public void DoubleClickProducesTwoCompleteClicks()
    {
        var backend = new TestInputBackend();
        var desktop = new WindowsDesktop(backend);
        desktop.Handle(new RemoteInput.Button("left", true, 2));
        desktop.Handle(new RemoteInput.Button("left", false, 2));
        Assert.Equal(new[]
        {
            NativeMethods.LeftDown, NativeMethods.LeftUp,
            NativeMethods.LeftDown, NativeMethods.LeftUp,
        }, backend.Calls.SelectMany(value => value).Select(value => value.Data.Mouse.Flags));
    }

    [Fact]
    public void EncodesSyntheticJpegWithAdvertisedDimensions()
    {
        using var bitmap = new Bitmap(640, 480, PixelFormat.Format24bppRgb);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.DarkSlateGray);
            graphics.FillRectangle(Brushes.White, 100, 100, 150, 100);
        }
        using var stream = new MemoryStream(WindowsDesktop.EncodeJpeg(bitmap));
        using Image decoded = Image.FromStream(stream);
        Assert.Equal(ImageFormat.Jpeg.Guid, decoded.RawFormat.Guid);
        Assert.Equal(640, decoded.Width);
        Assert.Equal(480, decoded.Height);
        Assert.True(stream.Length < 8 * 1024 * 1024);
    }

    private sealed class TestInputBackend : IWindowsInputBackend
    {
        public bool Unlocked { get; set; } = true;
        public bool IsInteractiveDesktop => Unlocked;
        public uint? AcceptedCount { get; set; }
        public Rectangle PrimaryBounds => new(0, 0, 1920, 1080);
        public Rectangle VirtualBounds => new(-1920, 0, 3840, 1080);
        public NativeMethods.Point CursorPosition => new() { X = 500, Y = 500 };
        public List<NativeMethods.Input[]> Calls { get; } = [];

        public uint Send(NativeMethods.Input[] inputs)
        {
            Calls.Add([.. inputs]);
            return AcceptedCount ?? (uint)inputs.Length;
        }
    }
}
