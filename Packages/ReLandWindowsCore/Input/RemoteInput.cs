using System.Text.Json;

namespace ReLand.Windows.Core.Input;

public abstract record RemoteInput
{
    public sealed record PointerDelta(double X, double Y) : RemoteInput;
    public sealed record PointerAbsolute(double X, double Y) : RemoteInput;
    public sealed record Button(string MouseButton, bool IsDown, int ClickCount) : RemoteInput;
    public sealed record Scroll(double X, double Y) : RemoteInput;
    public sealed record Text(string Value) : RemoteInput;
    public sealed record Key(ushort Code, bool IsDown, ulong Modifiers) : RemoteInput;

    public static RemoteInput Parse(byte[] payload)
    {
        using var document = JsonDocument.Parse(payload, new() { MaxDepth = 4 });
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 1)
        {
            throw new InvalidDataException("Exactly one input event is required.");
        }

        JsonProperty property = root.EnumerateObject().Single();
        JsonElement value = property.Value;
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("The input event is invalid.");
        }

        try
        {
            return property.Name switch
            {
                "pointerDelta" => new PointerDelta(
                    Number(value, "x", -8192, 8192), Number(value, "y", -8192, 8192)),
                "pointerAbsolute" => new PointerAbsolute(
                    Number(value, "x", 0, 1), Number(value, "y", 0, 1)),
                "scroll" => new Scroll(
                    Number(value, "x", -32767, 32767), Number(value, "y", -32767, 32767)),
                "button" => ParseButton(value),
                "text" => ParseText(value),
                "key" => ParseKey(value),
                _ => throw new InvalidDataException("The input event is not supported."),
            };
        }
        catch (Exception error) when (error is KeyNotFoundException or InvalidOperationException
            or FormatException or OverflowException)
        {
            throw new InvalidDataException("The input event is invalid.", error);
        }
    }

    private static double Number(JsonElement value, string name, double minimum, double maximum)
    {
        double number = value.GetProperty(name).GetDouble();
        if (!double.IsFinite(number) || number < minimum || number > maximum)
        {
            throw new InvalidDataException("The input coordinates are out of range.");
        }
        return number;
    }

    private static Button ParseButton(JsonElement value)
    {
        string? button = value.GetProperty("button").GetString();
        int count = value.GetProperty("clickCount").GetInt32();
        if (button is not "left" and not "right" || count is < 1 or > 3)
        {
            throw new InvalidDataException("The mouse button is invalid.");
        }
        return new(button, value.GetProperty("isDown").GetBoolean(), count);
    }

    private static Text ParseText(JsonElement value)
    {
        string? text = value.GetProperty("_0").GetString();
        if (string.IsNullOrEmpty(text) || text.Length > 4096 || text.Contains('\0'))
        {
            throw new InvalidDataException("Text must contain between 1 and 4096 characters without null characters.");
        }
        return new(text);
    }

    private static Key ParseKey(JsonElement value)
    {
        ushort code = value.GetProperty("code").GetUInt16();
        ulong modifiers = value.GetProperty("modifiers").GetUInt64();
        if (!WindowsKeyMap.TryTranslate(code, out _) || (modifiers & ~WindowsKeyMap.AllowedModifiers) != 0)
        {
            throw new InvalidDataException("The key or keyboard modifiers are not supported.");
        }
        return new(code, value.GetProperty("isDown").GetBoolean(), modifiers);
    }
}
