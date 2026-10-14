using System.Text;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;
using ReLand.Windows.Core.Security;

namespace ReLand.Windows.Core.Transport;

internal sealed class PskTlsTransport(CredentialRegistry credentials)
    : PskTlsServer(new BcTlsCrypto(), new IdentityManager(credentials))
{
    private readonly CredentialRegistry credentials = credentials;

    public string? CredentialId { get; private set; }

    protected override ProtocolVersion[] GetSupportedVersions() =>
        [ProtocolVersion.TLSv13, ProtocolVersion.TLSv12];

    protected override int[] GetSupportedCipherSuites() =>
        TlsUtilities.GetSupportedCipherSuites(Crypto,
        [
            CipherSuite.TLS_AES_128_GCM_SHA256,
            CipherSuite.TLS_CHACHA20_POLY1305_SHA256,
            CipherSuite.TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256,
            CipherSuite.TLS_DHE_PSK_WITH_AES_128_GCM_SHA256,
            CipherSuite.TLS_DHE_PSK_WITH_AES_256_GCM_SHA384,
            CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256,
            CipherSuite.TLS_PSK_WITH_AES_256_GCM_SHA384,
        ]);

    protected override bool PreferLocalCipherSuites() => true;

    // PSK authentication has no certificate for an OCSP status response.
    protected override bool AllowCertificateStatus() => false;

    public override TlsPskExternal? GetExternalPsk(IList<PskIdentity> identities)
    {
        if (identities.Count > 16)
        {
            throw new TlsFatalAlert(AlertDescription.illegal_parameter);
        }

        foreach (PskIdentity identity in identities)
        {
            string? id = DecodeIdentity(identity.Identity);
            if (id is not null && credentials.Find(id) is { } credential)
            {
                CredentialId = id;
                return new BasicTlsPskExternal(identity.Identity, Crypto.CreateSecret(credential.Key));
            }
        }
        return null;
    }

    public override TlsPskIdentityManager GetPskIdentityManager() =>
        new IdentityManager(credentials, identity => CredentialId = identity);

    private static string? DecodeIdentity(byte[] identity)
    {
        if (identity.Length is < 1 or > 128 || identity.Any(value => value > 127))
        {
            return null;
        }
        return Encoding.ASCII.GetString(identity);
    }

    private sealed class IdentityManager(
        CredentialRegistry credentials,
        Action<string>? selected = null) : TlsPskIdentityManager
    {
        public byte[]? GetHint() => null;

        public byte[]? GetPsk(byte[] identity)
        {
            string? id = DecodeIdentity(identity);
            if (id is null || credentials.Find(id) is not { } credential)
            {
                return null;
            }
            selected?.Invoke(id);
            return credential.Key;
        }
    }
}
