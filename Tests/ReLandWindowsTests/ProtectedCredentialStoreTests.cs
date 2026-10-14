using System.Security.Cryptography;
using System.Text;
using ReLand.Windows.Core.Protocol;
using ReLand.Windows.Host.Storage;
using Xunit;

namespace ReLand.Windows.Tests;

public sealed class ProtectedCredentialStoreTests
{
    [Fact]
    public void PersistsIdentityAndCredentialsAsCurrentUserEncryptedData()
    {
        string directory = Path.Combine(Environment.CurrentDirectory, "TestResults", $"windows-store-{Guid.NewGuid():N}");
        var store = new ProtectedCredentialStore(directory);
        PskCredential credential = PskCredential.Generate("Test Phone");
        var state = new HostState(Guid.NewGuid().ToString("D"), "Test Windows PC", [credential]);
        string path = Path.Combine(directory, "credentials.dat");
        try
        {
            store.Save(state);
            byte[] encrypted = File.ReadAllBytes(path);
            Assert.True(encrypted.AsSpan().IndexOf(Encoding.UTF8.GetBytes("Test Windows PC")) < 0);
            Assert.True(encrypted.AsSpan().IndexOf(credential.Key) < 0);
            HostState loaded = store.Load();
            Assert.Equal(state.HostId, loaded.HostId);
            Assert.Equal(state.HostName, loaded.HostName);
            Assert.Equal(credential.Key, Assert.Single(loaded.Credentials).Key);

            store.Save(state with { Credentials = [] });
            Assert.Empty(store.Load().Credentials);
            Assert.Single(Directory.GetFiles(directory));
        }
        finally
        {
            File.Delete(path);
            Directory.Delete(directory);
        }
    }

    [Fact]
    public void CorruptStoreFailsWithoutResettingOrOverwritingIt()
    {
        string directory = Path.Combine(Environment.CurrentDirectory, "TestResults", $"windows-store-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "credentials.dat");
        byte[] corrupt = [0xDE, 0xAD, 0xBE, 0xEF];
        File.WriteAllBytes(path, corrupt);
        try
        {
            Assert.Throws<CryptographicException>(() => new ProtectedCredentialStore(directory).Load());
            Assert.Equal(corrupt, File.ReadAllBytes(path));
        }
        finally
        {
            File.Delete(path);
            Directory.Delete(directory);
        }
    }
}
