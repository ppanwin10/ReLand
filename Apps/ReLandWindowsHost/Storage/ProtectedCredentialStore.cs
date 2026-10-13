using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ReLand.Windows.Core.Protocol;
using ReLand.Windows.Core.Security;

namespace ReLand.Windows.Host.Storage;

public sealed class ProtectedCredentialStore : IHostCredentialStore
{
    private const int MaximumStoreSize = 1024 * 1024;
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("ReLand Windows host credentials v1");
    private readonly string directory;
    private readonly string path;

    public ProtectedCredentialStore(string? directory = null)
    {
        this.directory = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ReLand", "WindowsHost");
        path = Path.Combine(this.directory, "credentials.dat");
    }

    public HostState Load()
    {
        if (!File.Exists(path))
        {
            var created = new HostState(Guid.NewGuid().ToString("D"), Environment.MachineName, []);
            Save(created);
            return created;
        }
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is < 1 or > MaximumStoreSize)
        {
            throw new InvalidDataException("The protected credential store is invalid.");
        }
        byte[] encrypted = new byte[(int)file.Length];
        file.ReadExactly(encrypted);
        byte[] clear = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
        try
        {
            return WireJson.Decode<HostState>(clear);
        }
        catch (JsonException error)
        {
            throw new InvalidDataException("The protected credential store is invalid.", error);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clear);
        }
    }

    public void Save(HostState state)
    {
        byte[] clear = WireJson.Encode(state);
        byte[] encrypted;
        try
        {
            encrypted = ProtectedData.Protect(clear, Entropy, DataProtectionScope.CurrentUser);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clear);
        }
        Directory.CreateDirectory(directory);
        string temporary = Path.Combine(directory, $"credentials-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 4096, FileOptions.WriteThrough))
            {
                file.Write(encrypted);
                file.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }
}
