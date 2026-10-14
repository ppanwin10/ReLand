# Windows host preview

The source-built Windows host lets an iPhone or iPad pair with a Windows PC,
view its primary screen, and send mouse and keyboard input over a trusted LAN
or private Tailscale network.

This is an experimental implementation, not a signed Windows release.
Apple TLS interoperability, iPhone/iPad running-app review, and Mac regression
checks must be completed on a Mac before treating it as release-ready. Use an
Apple client built from the same revision for platform-aware controls; older
beta clients may still display Mac-only actions.

## Requirements

- Windows 10 version 2004 (build 19041) or later, or Windows 11.
- An unlocked interactive Windows session with a primary display.
- .NET 8 SDK or a newer SDK capable of building .NET 8, for source builds.
- ReLand on iPhone/iPad running iOS/iPadOS 18 or later.
- A trusted private LAN, or Tailscale running on both devices.

Run the host as your normal Windows user, **not as administrator**. Elevated
apps, UAC/system prompts, the Windows login screen, terminals, AI CLI sessions,
files, app-window selection, and secondary-display selection are not supported
by this preview.

## Build and run

From the repository root in PowerShell:

```powershell
dotnet run --project Apps\ReLandWindowsHost\ReLandWindowsHost.csproj
```

To build a self-contained x64 folder:

```powershell
dotnet publish Apps\ReLandWindowsHost\ReLandWindowsHost.csproj `
  --configuration Release --runtime win-x64 --self-contained true `
  --output build\windows-host
```

Run `build\windows-host\ReLandWindowsHost.exe`. The host does not start sharing
automatically.

## Pair and control

1. Select the PC's private IPv4 LAN or Tailscale address and choose **Start Host**.
2. Choose **Create one-time code** while physically at the PC.
3. In ReLand on your iPhone/iPad, choose **Add computer**, scan the QR, confirm
   the computer name and private address, and choose **Pair**.
4. Use **Screen** for the desktop, **Keys** for text and shortcuts, and **More**
   for pointer modes, dragging, right click, scrolling, and the gesture guide.

The QR expires after ten minutes and can be used once. It is never copied to
the clipboard or saved to disk. The host window is excluded from screen
capture; if Windows cannot protect it, QR generation stays disabled. A new
code cannot be generated while a device is controlling the PC.

Only one paired device controls the PC at a time. Another device must confirm
**Take Over** in the client; reconnecting the same device replaces its stale
connection. Idle controllers lose their lease. **Stop Host** or closing the
host disconnects devices. **Forget selected device** removes that device's
credential and requires pairing again.

## Network and permissions

The host uses TCP port `45454` on the selected private address. It does not
listen on every interface or accept public peer addresses. If Windows Defender
Firewall asks, allow the host only on the trusted **Private** profile. Do not
enable public access, configure router port forwarding, or expose the port on
the public internet.

For Tailscale, select the PC's `100.x` address and ensure the iPhone/iPad is
connected to the same private tailnet. For LAN pairing, select the address
reachable from the phone's trusted Wi-Fi network. Refresh addresses and restart
the host after changing networks. Allow ReLand's Local Network permission on
the iPhone/iPad.

The phone cannot unlock the PC or approve a secure system prompt. Unlock or
dismiss the prompt **locally**, then use **Retry**. Input into elevated apps is
blocked by Windows; do not elevate ReLand to bypass that boundary.

## Storage and privacy

Host identity and paired credentials live in
`%LOCALAPPDATA%\ReLand\WindowsHost\credentials.dat`, protected by Windows DPAPI
for the current user and replaced atomically. Pairing secrets and screen
frames are not persisted. Corrupt or inaccessible credential storage fails
explicitly; it is never silently replaced with a fresh identity.

Screen frames are JPEG, limited to a 1920-pixel longest edge and ten frames per
second, with a captured pointer overlay. Absolute touch coordinates continue
to map to the full primary display. Text is injected as Unicode; the clipboard
is not modified. Keyboard modifiers are **Win**, **Alt**, **Ctrl**, and **Shift**.
The host releases injected keys/buttons when control ends, retrying after
local unlock if the secure desktop temporarily blocks release.

There is no ReLand cloud relay, account service, diagnostics upload, screen
recording, terminal service, or remote file service in this host.

## Developer checks

```powershell
dotnet test Tests\ReLandWindowsTests\ReLandWindowsTests.csproj
```

The suite uses loopback TLS and synthetic desktop/input fixtures. It covers
framing limits, protocol 7/8, TLS 1.2/1.3 PSKs, one-time/expiring pairing,
credential protection and rollback, private-address restrictions, negotiation,
controller takeover/reconnect, lock/revocation behavior, native input layout,
key translation, Unicode, pointer coordinates, and bounded JPEG encoding.
It must not send actual desktop input or capture personal content.

PSK sessions do not advertise certificate-status (OCSP) extensions because
they do not use a certificate. The host integration suite covers clients
that request OCSP, including the request Apple's Network.framework sends.
Rebuild older Windows preview hosts before testing the updated Apple client.

On a Mac, run the repository unit and simulator entrypoints, build the real
Mac host, and review both iPhone and iPad. Exercise the Windows host through
the actual Apple client over a private test network, including QR pairing,
screen viewing, input, disconnect/reconnect, lock/retry, and takeover. Use only
a clean synthetic Windows test account/desktop and redact all pairing codes,
credentials, addresses, and hostnames from screenshots.
