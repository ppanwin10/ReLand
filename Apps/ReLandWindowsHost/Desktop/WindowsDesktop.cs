using System.ComponentModel;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using ReLand.Windows.Core.Desktop;
using ReLand.Windows.Core.Input;
using ReLand.Windows.Core.Protocol;

namespace ReLand.Windows.Host.Desktop;

public sealed class WindowsDesktop : IRemoteDesktop
{
    private readonly object gate = new();
    private readonly IWindowsInputBackend inputBackend;
    private readonly Dictionary<ushort, bool> pressedKeys = [];
    private readonly HashSet<string> pressedButtons = [];
    private bool releasePending;

    public WindowsDesktop() : this(new WindowsInputBackend()) {}

    internal WindowsDesktop(IWindowsInputBackend inputBackend)
    {
        this.inputBackend = inputBackend;
    }

    public DisplayInformation DisplayInformation
    {
        get
        {
            Rectangle bounds = inputBackend.PrimaryBounds;
            (int width, int height) = DesktopGeometry.ScaledSize(bounds.Width, bounds.Height);
            return new(width, height);
        }
    }

    public HostPermissionState PermissionState => new(true, true, inputBackend.IsInteractiveDesktop);

    public DesktopFrame? Capture()
    {
        lock (gate)
        {
            if (!inputBackend.IsInteractiveDesktop)
            {
                return null;
            }
            if (releasePending)
            {
                ReleaseInputOnDesktop();
            }
            Rectangle bounds = inputBackend.PrimaryBounds;
            (int width, int height) = DesktopGeometry.ScaledSize(bounds.Width, bounds.Height);
            try
            {
                using var bitmap = new Bitmap(width, height, PixelFormat.Format24bppRgb);
                using (Graphics graphics = Graphics.FromImage(bitmap))
                {
                    IntPtr destination = graphics.GetHdc();
                    IntPtr source = NativeMethods.GetDC(IntPtr.Zero);
                    try
                    {
                        if (source == IntPtr.Zero
                            || NativeMethods.SetStretchBltMode(destination, 4) == 0
                            || !NativeMethods.StretchBlt(destination, 0, 0, width, height,
                                source, bounds.Left, bounds.Top, bounds.Width, bounds.Height, 0x40CC0020))
                        {
                            throw NativeFailure("Windows could not capture the primary screen.");
                        }
                    }
                    finally
                    {
                        if (source != IntPtr.Zero)
                        {
                            NativeMethods.ReleaseDC(IntPtr.Zero, source);
                        }
                        graphics.ReleaseHdc(destination);
                    }
                    DrawCursor(graphics, bounds, width, height);
                }
                byte[] bytes = EncodeJpeg(bitmap);
                if (!inputBackend.IsInteractiveDesktop)
                {
                    return null;
                }
                return new(new(width, height), bytes);
            }
            catch (ExternalException error)
            {
                throw new DesktopOperationException("Windows could not capture the primary screen. Reconnect and retry.", error);
            }
        }
    }

    public string Handle(RemoteInput input)
    {
        lock (gate)
        {
            if (!inputBackend.IsInteractiveDesktop)
            {
                throw new DesktopOperationException(
                    "Unlock the PC or dismiss the system prompt locally before sending input.");
            }
            if (releasePending)
            {
                ReleaseInputOnDesktop();
            }
            switch (input)
            {
                case RemoteInput.PointerAbsolute pointer:
                    MovePointer(pointer.X, pointer.Y);
                    return "absolute pointer";
                case RemoteInput.PointerDelta pointer:
                    NativeMethods.Point current = inputBackend.CursorPosition;
                    Rectangle bounds = inputBackend.PrimaryBounds;
                    MovePointer(
                        Math.Clamp((current.X + pointer.X - bounds.Left) / Math.Max(bounds.Width - 1, 1), 0, 1),
                        Math.Clamp((current.Y + pointer.Y - bounds.Top) / Math.Max(bounds.Height - 1, 1), 0, 1));
                    return $"move {(int)pointer.X},{(int)pointer.Y}";
                case RemoteInput.Button button:
                    SendButton(button);
                    return $"{button.MouseButton} {(button.IsDown ? "down" : "up")}";
                case RemoteInput.Scroll scroll:
                    var wheels = new List<NativeMethods.Input>();
                    if (scroll.Y != 0)
                    {
                        wheels.Add(Mouse(NativeMethods.Wheel, data: unchecked((uint)(int)Math.Round(scroll.Y))));
                    }
                    if (scroll.X != 0)
                    {
                        wheels.Add(Mouse(NativeMethods.HorizontalWheel, data: unchecked((uint)(int)Math.Round(scroll.X))));
                    }
                    Send(wheels.ToArray());
                    return "scroll";
                case RemoteInput.Text text:
                    SendText(text.Value);
                    return $"text {text.Value.Length} characters";
                case RemoteInput.Key key:
                    SendKey(key);
                    return $"key {key.Code} {(key.IsDown ? "down" : "up")}";
                default:
                    throw new DesktopOperationException("The input event is not supported.");
            }
        }
    }

    public void ReleaseInput()
    {
        lock (gate)
        {
            if (pressedKeys.Count == 0 && pressedButtons.Count == 0)
            {
                releasePending = false;
                return;
            }
            releasePending = true;
            if (inputBackend.IsInteractiveDesktop)
            {
                ReleaseInputOnDesktop();
            }
        }
    }

    internal static byte[] EncodeJpeg(Bitmap bitmap)
    {
        ImageCodecInfo encoder = ImageCodecInfo.GetImageEncoders().Single(value => value.FormatID == ImageFormat.Jpeg.Guid);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 65L);
        using var stream = new MemoryStream();
        bitmap.Save(stream, encoder, parameters);
        if (stream.Length >= WireCodec.MaximumPacketSize)
        {
            throw new DesktopOperationException("The captured frame exceeds the streaming limit.");
        }
        return stream.ToArray();
    }

    private static ScreenBounds Bounds(Rectangle rectangle) =>
        new(rectangle.X, rectangle.Y, rectangle.Width, rectangle.Height);

    private void MovePointer(double x, double y)
    {
        (int absoluteX, int absoluteY) = DesktopGeometry.AbsolutePointer(
            x, y, Bounds(inputBackend.PrimaryBounds), Bounds(inputBackend.VirtualBounds));
        Send([Mouse(NativeMethods.MouseMove | NativeMethods.Absolute | NativeMethods.VirtualDesktop,
            absoluteX, absoluteY)]);
    }

    private void SendButton(RemoteInput.Button button)
    {
        uint down = button.MouseButton == "left" ? NativeMethods.LeftDown : NativeMethods.RightDown;
        uint up = button.MouseButton == "left" ? NativeMethods.LeftUp : NativeMethods.RightUp;
        var inputs = new List<NativeMethods.Input>();
        if (button.IsDown && !pressedButtons.Contains(button.MouseButton))
        {
            for (int count = 1; count < button.ClickCount; count++)
            {
                inputs.Add(Mouse(down));
                inputs.Add(Mouse(up));
            }
            inputs.Add(Mouse(down));
        }
        else if (!button.IsDown && pressedButtons.Contains(button.MouseButton))
        {
            inputs.Add(Mouse(up));
        }
        Send(inputs.ToArray());
    }

    private void SendKey(RemoteInput.Key key)
    {
        if (!WindowsKeyMap.TryTranslate(key.Code, out ushort virtualKey))
        {
            throw new DesktopOperationException("This key is not supported on Windows.");
        }
        var inputs = new List<NativeMethods.Input>();
        if (key.IsDown)
        {
            foreach (ushort modifier in WindowsKeyMap.Modifiers(key.Modifiers))
            {
                if (!pressedKeys.ContainsKey(modifier))
                {
                    inputs.Add(Keyboard(modifier, isUp: false));
                }
            }
            inputs.Add(Keyboard(virtualKey, isUp: false, extended: key.Code == 76));
        }
        else
        {
            if (pressedKeys.ContainsKey(virtualKey))
            {
                inputs.Add(Keyboard(virtualKey, isUp: true, extended: key.Code == 76));
            }
            if (!pressedKeys.Keys.Any(value => value != virtualKey && !IsModifier(value)))
            {
                inputs.AddRange(pressedKeys.Keys.Where(value => value != virtualKey && IsModifier(value))
                    .Reverse().Select(value => Keyboard(value, isUp: true)));
            }
        }
        Send(inputs.ToArray());
    }

    private void SendText(string text)
    {
        ReleaseInputOnDesktop();
        var inputs = new List<NativeMethods.Input>(128);
        foreach (Rune rune in text.EnumerateRunes())
        {
            string characters = rune.ToString();
            if (inputs.Count + characters.Length * 2 > 128)
            {
                Send(inputs.ToArray());
                inputs.Clear();
            }
            foreach (char character in characters)
            {
                inputs.Add(Unicode(character, isUp: false));
                inputs.Add(Unicode(character, isUp: true));
            }
        }
        Send(inputs.ToArray());
    }

    private void ReleaseInputOnDesktop()
    {
        var inputs = pressedKeys.Select(value =>
            Keyboard(value.Key, isUp: true, extended: value.Value)).ToList();
        inputs.AddRange(pressedButtons.Select(value =>
            Mouse(value == "left" ? NativeMethods.LeftUp : NativeMethods.RightUp)));
        Send(inputs.ToArray());
        releasePending = false;
    }

    private void Send(NativeMethods.Input[] inputs)
    {
        if (inputs.Length == 0)
        {
            return;
        }
        uint sent = inputBackend.Send(inputs);
        for (int index = 0; index < Math.Min(sent, inputs.Length); index++)
        {
            NativeMethods.Input input = inputs[index];
            if (input.Type == 1 && (input.Data.Keyboard.Flags & NativeMethods.KeyUnicode) == 0)
            {
                if ((input.Data.Keyboard.Flags & NativeMethods.KeyUp) == 0)
                {
                    pressedKeys[input.Data.Keyboard.VirtualKey] =
                        (input.Data.Keyboard.Flags & NativeMethods.KeyExtended) != 0;
                }
                else
                {
                    pressedKeys.Remove(input.Data.Keyboard.VirtualKey);
                }
            }
            if (input.Type == 0)
            {
                TrackButton(input.Data.Mouse.Flags, "left", NativeMethods.LeftDown, NativeMethods.LeftUp);
                TrackButton(input.Data.Mouse.Flags, "right", NativeMethods.RightDown, NativeMethods.RightUp);
            }
        }
        if (sent != inputs.Length)
        {
            releasePending = true;
            throw NativeFailure(
                "Windows blocked remote input. Dismiss system prompts locally and use apps at the same permission level.");
        }
    }

    private void TrackButton(uint flags, string button, uint down, uint up)
    {
        if ((flags & down) != 0)
        {
            pressedButtons.Add(button);
        }
        if ((flags & up) != 0)
        {
            pressedButtons.Remove(button);
        }
    }

    private static bool IsModifier(ushort key) => key is 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5 or 0x5B or 0x5C;

    private static NativeMethods.Input Mouse(uint flags, int x = 0, int y = 0, uint data = 0) =>
        new() { Type = 0, Data = new() { Mouse = new() { X = x, Y = y, Data = data, Flags = flags } } };

    private static NativeMethods.Input Keyboard(ushort key, bool isUp, bool extended = false) =>
        new()
        {
            Type = 1,
            Data = new()
            {
                Keyboard = new()
                {
                    VirtualKey = key,
                    Flags = (isUp ? NativeMethods.KeyUp : 0)
                        | (extended || WindowsKeyMap.IsExtended(key) ? NativeMethods.KeyExtended : 0),
                },
            },
        };

    private static NativeMethods.Input Unicode(char character, bool isUp) =>
        new()
        {
            Type = 1,
            Data = new()
            {
                Keyboard = new()
                {
                    ScanCode = character,
                    Flags = NativeMethods.KeyUnicode | (isUp ? NativeMethods.KeyUp : 0),
                },
            },
        };

    private static DesktopOperationException NativeFailure(string message) =>
        new(message, new Win32Exception(Marshal.GetLastWin32Error()));

    private static void DrawCursor(Graphics graphics, Rectangle bounds, int width, int height)
    {
        var cursor = new NativeMethods.CursorInfo { Size = Marshal.SizeOf<NativeMethods.CursorInfo>() };
        if (!NativeMethods.GetCursorInfo(ref cursor))
        {
            throw NativeFailure("Windows could not capture the pointer.");
        }
        if ((cursor.Flags & 1) == 0)
        {
            return;
        }
        if (!NativeMethods.GetIconInfo(cursor.Cursor, out NativeMethods.IconInfo info))
        {
            throw NativeFailure("Windows could not capture the pointer.");
        }
        try
        {
            using Icon icon = Icon.FromHandle(cursor.Cursor);
            double scaleX = (double)width / bounds.Width;
            double scaleY = (double)height / bounds.Height;
            var destination = new Rectangle(
                (int)Math.Round((cursor.Position.X - bounds.Left - info.HotspotX) * scaleX),
                (int)Math.Round((cursor.Position.Y - bounds.Top - info.HotspotY) * scaleY),
                Math.Max(1, (int)Math.Round(icon.Width * scaleX)),
                Math.Max(1, (int)Math.Round(icon.Height * scaleY)));
            graphics.DrawIcon(icon, destination);
        }
        finally
        {
            if (info.MaskBitmap != IntPtr.Zero)
            {
                NativeMethods.DeleteObject(info.MaskBitmap);
            }
            if (info.ColorBitmap != IntPtr.Zero)
            {
                NativeMethods.DeleteObject(info.ColorBitmap);
            }
        }
    }
}
