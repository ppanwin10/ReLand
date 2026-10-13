namespace ReLand.Windows.Core.Desktop;

public readonly record struct ScreenBounds(int X, int Y, int Width, int Height);

public static class DesktopGeometry
{
    public static (int Width, int Height) ScaledSize(int width, int height)
    {
        if (width <= 0 || height <= 0)
        {
            throw new DesktopOperationException("No usable primary display is available.");
        }
        double scale = Math.Min(1, 1920.0 / Math.Max(width, height));
        return (Math.Max(1, (int)Math.Round(width * scale)),
            Math.Max(1, (int)Math.Round(height * scale)));
    }

    public static (int X, int Y) AbsolutePointer(
        double x, double y, ScreenBounds display, ScreenBounds virtualDesktop)
    {
        if (!double.IsFinite(x) || !double.IsFinite(y)
            || x < 0 || x > 1 || y < 0 || y > 1
            || display.Width <= 0 || display.Height <= 0
            || virtualDesktop.Width <= 0 || virtualDesktop.Height <= 0)
        {
            throw new DesktopOperationException("The pointer coordinates or display bounds are invalid.");
        }
        double screenX = display.X + Math.Round(x * (display.Width - 1));
        double screenY = display.Y + Math.Round(y * (display.Height - 1));
        return (
            (int)Math.Clamp(Math.Round((screenX - virtualDesktop.X) * 65535
                / Math.Max(virtualDesktop.Width - 1, 1)), 0, 65535),
            (int)Math.Clamp(Math.Round((screenY - virtualDesktop.Y) * 65535
                / Math.Max(virtualDesktop.Height - 1, 1)), 0, 65535));
    }
}
