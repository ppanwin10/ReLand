# ReLand wire protocol

## Framing

Each packet is:

```text
uint32 bodyLength (big endian)
uint8  messageKind
bytes  payload
```

`bodyLength` includes the kind byte. JSON encodes typed payloads. Video and
terminal bytes use their defined binary payload fields.

## Authentication

- TLS-PSK transport.
- Random challenge.
- HMAC-SHA256 response.
- Constant-time authentication-code comparison.
- Pairing credentials are expiring and one-time.

## Compatibility negotiation

The current supported range is `7...8`.

The host challenge advertises:

- its supported protocol range;
- available feature capabilities.

The client chooses the highest common version and returns the capability
intersection in its authentication response. The host echoes the negotiated
version and capabilities in `SessionReady`. A connection fails before session
activation when no common version exists.

An authenticated client may set `requestsControllerTakeover` only after
explicit user confirmation. The host revokes the current controller with the
`sessionTakenOver` error before activating the replacement.

Current capabilities are screen, input, terminal, artifacts, approved files,
capture-target selection, and host status. The Windows desktop preview
advertises only `screen`, `input`, and `hostStatus`. A host must not execute
input unless the client negotiated the `input` capability.

## Host platform metadata

`PairDeviceAccepted`, `SessionReady`, the v2 pairing payload, and saved
`RemoteDevice` records may carry `hostPlatform` (`macOS` or `windows`).
`PairDeviceAccepted`, pairing payloads, and saved devices may also carry a
`capabilities` snapshot for presenting supported actions before reconnecting.
The authenticated `SessionReady` negotiation remains authoritative.

These are additive JSON fields: the supported range remains `7...8` and the
pairing payload prefix remains `reland-pair:v2:`. Updated decoders default
missing platform metadata to `macOS`; existing Mac device records with no
snapshot preserve their actions. Unknown platform/capability values are not
silently accepted. Older decoders ignore the added fields, although their UI
may continue to show unsupported Mac-specific controls for Windows.

Input enum JSON remains Swift's synthesized representation, for example:

```json
{"pointerAbsolute":{"x":0.25,"y":0.75}}
{"button":{"button":"left","isDown":true,"clickCount":1}}
{"text":{"_0":"Example text"}}
{"key":{"code":53,"isDown":true,"modifiers":0}}
```

Absolute pointer coordinates are normalized to the shared display. Key codes
and modifier bits retain their macOS wire meaning on both platforms; Windows
translates Command to the Windows key, Option to Alt, and the remaining keys
to their Windows equivalents. Video frames remain raw JPEG packet payloads.

## Message ranges

- `1...12` — authentication/session/heartbeat/error.
- `13...24` — terminal lifecycle and I/O.
- `25...28` — terminal artifacts.
- `29...32` — approved remote files.
- `33...36` — capture-target listing and selection.
- `37...38` — host permission/lock status.
- `39` — terminal display-name updates.
- `40...127` — reserved for future core protocol messages; unknown values are
  rejected.
- `128...255` — optional extension messages; an older decoder skips the
  complete framed body when it does not recognize the kind.

Do not reuse an assigned value. Add request/response models and integration
tests with every new message.

## Error context

`RemoteErrorMessage` includes optional `requestKind` and `requestID` fields.
Hosts set them when an error is caused by a specific request so clients can
route concurrent terminal, file, and capture errors to the correct UI.
Unsolicited session and frame-source errors omit them. Older payloads without
these fields remain valid.

`TerminalCreateRequest` carries a client-generated `requestID`.
`TerminalSessionList` echoes it as `createdRequestID` alongside the optional
`createdSessionID`. This lets the client attach the exact session created for
the current attempt instead of inferring it from timestamps or list order.
Protocol 7 hosts omit those fields; the client first refreshes the host's
session list, then matches exactly one newly returned session ID.

`TerminalRenameRequest` updates app-owned display metadata without changing
the stable tmux session ID or its session-files directory. It requires
negotiated protocol version 8; version 7 peers retain all earlier terminal
features and do not expose the rename action.

## Limits

- Maximum packet: 8 MiB.
- Windows inbound command body: 64 KiB; text input: 4096 UTF-16 code units.
- Windows host: at most eight pending/active connections, twelve seconds for
  TLS plus application authentication, and a twenty-second controller lease.
- Artifact chunk: 256 KiB.
- Maximum artifact: 512 MiB.

The host must reject malformed lengths, oversized payloads, invalid offsets,
unsafe paths, and unauthenticated active-session messages.
