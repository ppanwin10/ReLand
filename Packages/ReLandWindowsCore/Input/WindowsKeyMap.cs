namespace ReLand.Windows.Core.Input;

public static class WindowsKeyMap
{
    public const ulong Shift = 0x0002_0000;
    public const ulong Control = 0x0004_0000;
    public const ulong Alt = 0x0008_0000;
    public const ulong Windows = 0x0010_0000;
    public const ulong AllowedModifiers = Shift | Control | Alt | Windows;

    // Protocol 7/8 key events use macOS virtual key codes on every host platform.
    private static readonly IReadOnlyDictionary<ushort, ushort> Keys = new Dictionary<ushort, ushort>
    {
        [0] = 0x41, [1] = 0x53, [2] = 0x44, [3] = 0x46, [4] = 0x48, [5] = 0x47,
        [6] = 0x5A, [7] = 0x58, [8] = 0x43, [9] = 0x56, [11] = 0x42, [12] = 0x51,
        [13] = 0x57, [14] = 0x45, [15] = 0x52, [16] = 0x59, [17] = 0x54,
        [18] = 0x31, [19] = 0x32, [20] = 0x33, [21] = 0x34, [22] = 0x36, [23] = 0x35,
        [24] = 0xBB, [25] = 0x39, [26] = 0x37, [27] = 0xBD, [28] = 0x38, [29] = 0x30,
        [30] = 0xDD, [31] = 0x4F, [32] = 0x55, [33] = 0xDB, [34] = 0x49, [35] = 0x50,
        [36] = 0x0D, [37] = 0x4C, [38] = 0x4A, [39] = 0xDE, [40] = 0x4B, [41] = 0xBA,
        [42] = 0xDC, [43] = 0xBC, [44] = 0xBF, [45] = 0x4E, [46] = 0x4D, [47] = 0xBE,
        [48] = 0x09, [49] = 0x20, [50] = 0xC0, [51] = 0x08, [53] = 0x1B,
        [55] = 0x5B, [56] = 0xA0, [57] = 0x14, [58] = 0xA4, [59] = 0xA2,
        [60] = 0xA1, [61] = 0xA5, [62] = 0xA3,
        [64] = 0x80, [65] = 0x6E, [67] = 0x6A, [69] = 0x6B, [71] = 0x0C,
        [75] = 0x6F, [76] = 0x0D, [78] = 0x6D, [79] = 0x81, [80] = 0x82,
        [81] = 0xBB, [82] = 0x60, [83] = 0x61, [84] = 0x62, [85] = 0x63,
        [86] = 0x64, [87] = 0x65, [88] = 0x66, [89] = 0x67, [90] = 0x83,
        [91] = 0x68, [92] = 0x69, [96] = 0x74, [97] = 0x75, [98] = 0x76,
        [99] = 0x72, [100] = 0x77, [101] = 0x78, [103] = 0x7A, [105] = 0x7C,
        [106] = 0x7F, [107] = 0x7D, [109] = 0x79, [111] = 0x7B, [113] = 0x7E,
        [114] = 0x2D, [115] = 0x24, [116] = 0x21, [117] = 0x2E, [118] = 0x73,
        [119] = 0x23, [120] = 0x71, [121] = 0x22, [122] = 0x70,
        [123] = 0x25, [124] = 0x27, [125] = 0x28, [126] = 0x26,
    };

    public static bool TryTranslate(ushort code, out ushort virtualKey) => Keys.TryGetValue(code, out virtualKey);

    public static bool IsExtended(ushort key) =>
        key is >= 0x21 and <= 0x28 or 0x2D or 0x2E or 0x5B or 0x5C or 0xA3 or 0xA5;

    public static ushort[] Modifiers(ulong flags) =>
    [
        .. ((flags & Shift) != 0 ? new ushort[] { 0xA0 } : []),
        .. ((flags & Control) != 0 ? new ushort[] { 0xA2 } : []),
        .. ((flags & Alt) != 0 ? new ushort[] { 0xA4 } : []),
        .. ((flags & Windows) != 0 ? new ushort[] { 0x5B } : []),
    ];
}
