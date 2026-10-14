# Architecture

## Components

```text
ReLand client
  -> ReLandCore (TLS-PSK, wire protocol, shared models)
  -> private LAN or Tailscale
  -> ReLand Host
       -> ReLandHostCore
            -> ScreenCaptureKit
            -> Accessibility / CGEvent
            -> tmux / Terminal / AI CLIs
            -> app-owned artifacts
            -> approved read-only folders
```

## Dependency direction

```text
ReLandClient -> ReLandCore
ReLandHost -> ReLandCore + ReLandHostCore
ReLandHostCore -> ReLandCore
```

Shared code must not depend on app targets.

## Windows host preview

```text
ReLand client
  -> the same protocol 7/8 and one-time QR pairing
  -> private LAN or Tailscale
  -> ReLand Windows Host (.NET / Windows Forms)
       -> ReLandWindowsCore
            -> Bouncy Castle TLS-PSK and HMAC-SHA256 authentication
            -> one authenticated controller, lease, and consented takeover
       -> Windows GDI primary-screen capture / bounded JPEG encoding
       -> Win32 SendInput (mouse, Unicode text, translated key codes)
       -> current-user DPAPI credential store
```

The Windows host advertises only `screen`, `input`, and `hostStatus`. The client
persists the host platform and capability snapshot after pairing/negotiation,
and hides unavailable app, terminal, and file actions. Missing metadata on
existing Mac peers and saved devices preserves their previous behavior.

Windows key events retain the protocol's macOS virtual key codes. The Windows
input adapter translates them and maps Command to the Windows key and Option
to Alt. Text uses Unicode input, not clipboard replacement. Injected keys and
mouse buttons are tracked and released on disconnect/takeover; releases
blocked by the secure desktop are retried after local unlock.

The listener binds one explicitly selected private address and rejects public
peers before TLS. Pending handshakes and commands have bounded sizes, connection
counts, and deadlines. Pairing credentials remain in memory, expire after ten
minutes even if the wall clock moves backward, and are consumed only after the
new device credential is durably protected. The host window is excluded from
capture, and generating a new pairing code is forbidden while a controller is
active.

Windows currently has no app-window selection, terminal, artifact, or file
service. It does not elevate itself, bypass system prompts, or install public
firewall rules. See [Windows host setup](WINDOWS_HOST.md) for build and review
requirements.

## Persistence

App state depends on `SettingsStoring` and `CredentialStoring`, with
UserDefaults and Keychain adapters provided by ReLandCore. App models and
device/host stores accept these dependencies through initializers so tests and
future cleanup tools do not need to mutate real user state.

## Connection lifecycle

1. The client opens a Network.framework TLS-PSK connection.
2. The host sends a random challenge and protocol version.
3. The client authenticates with HMAC-SHA256.
4. During pairing, the host accepts one expiring pairing credential and
   provisions a fresh device credential.
5. Active sessions exchange framed typed packets.
6. Heartbeats detect dead connections.

`SessionReady` also includes current Screen Recording, Accessibility, and Mac
lock state. The client can refresh this state with the host-status request and
show explicit Open Mac Screen/Retry recovery actions.

## Capture and input

- Screen Mode captures the display.
- App Mode uses a desktop-independent ScreenCaptureKit window filter.
- Absolute input is mapped to current display/window bounds.
- Accessibility focuses and raises a selected app window before input.
- App-window capture does not reliably include the macOS cursor, so the client
  renders a virtual cursor.

The selected capture target is currently host-global, so v0.1 permits one
active authenticated controller. A second controller receives `hostBusy`.
Active clients refresh a bounded host-side lease through normal traffic and
heartbeats; stale connections are evicted. A confirmed authenticated takeover
revokes the previous controller before the new one becomes active. Per-client
capture contexts are future work.

## Terminal and artifacts

ReLand Host manages `rl-*` tmux sessions. Each session receives an app-owned
workspace with Artifacts, Instructions, and helper binaries. Raw AI commands
are unmodified; ReLand AI injects tool-specific artifact instructions.
Internal session IDs are lowercase and are not reused while their retained
workspace exists, so a new terminal cannot inherit an older session's files.

## File access

Remote browsing is read-only and limited to:

- ReLand application storage;
- folders explicitly approved in ReLand Host.

Hidden components, traversal, and symlinks are rejected on the host.

Terminal working-directory requests use the same virtual approved-folder
paths. ReLand Host resolves and validates the directory before passing a local
URL to tmux; the client never supplies an arbitrary filesystem path.

## Concurrency

Several transport/service types use serial queue confinement and are marked
`@unchecked Sendable`. All mutable state in those types must remain on the
documented queue. Convert incrementally to actors only with characterization
tests.

## Distribution boundary

ReLand Host is not App-Sandboxed because it must post global input and launch
tmux, Terminal, shells, and local AI CLIs. Release hardening relies on
Hardened Runtime, notarization, TCC consent, private-network restrictions,
authenticated commands, and narrow file roots.
