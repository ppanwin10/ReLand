# Changelog

All notable user-visible changes will be documented here.

## Unreleased

## 1.0 Beta 2 - 2026-07-26

- Published ReLand 1.0 (5) through TestFlight and the notarized
  [ReLand Host 1.0 Beta 2][host-beta].
- Made terminal creation collision-safe without reusing retained session
  storage.
- Added approved project-folder history and session workspace selection.
- Added a labeled terminal More sheet for files, Mac opening, display-name
  editing, and stopping sessions.
- Preserved terminal attachments and grid sizing across reconnects.
- Added protocol 8 terminal creation correlation and rename support while
  retaining protocol 7 compatibility.

## 1.0 Beta 1 - 2026-07-25

- Opened the ReLand 1.0 public beta through
  [TestFlight][testflight-beta], with [ReLand Host 1.0 Beta 1][host-beta]
  available as the required Mac companion.
- Renamed the product, applications, modules, storage, and protocol service
  from LandRemote to ReLand.
- Added ReLand AI (`reland-ai`) with a `landai` developer alias.
- New terminal sessions start in their app-owned ReLand workspace.
- Removed the separate AI File Setup sheet; empty Artifacts now offers
  explicit Send to AI and Copy prompt actions.
- Added three-finger horizontal App Mode switching with tested MRU ordering,
  haptic feedback, and a transient native window strip.
- Added first-run purpose/prerequisite onboarding and real iOS/macOS Settings
  surfaces for controls, privacy, network guidance, and bounded cleanup.
- Added the original navy/teal ReLand portal and return-path icon.
- Added live Mac Screen Recording, Accessibility, and lock-state recovery with
  Open Mac Screen and Retry actions.
- Fixed Screen Mode absolute pointer mapping so the physical bottom edge can
  reveal the auto-hidden macOS Dock.
- Replaced the hidden horizontal remote-control scroller with a fixed labeled
  action dock, a More menu, gesture guide, and disconnect confirmation.
- Added secure project-folder selection for new terminals. Only ReLand storage
  and folders approved in ReLand Host can become a tmux working directory.
- Added explicitly named ReLand AI launch profiles. Permission-bypass flags
  remain off unless the user selects a named risky profile.
- Replaced secret-bearing pairing links with expiring, one-time QR payloads
  that require explicit confirmation.
- Added client-side private-network enforcement.
- Removed release access to deterministic E2E credentials.

[testflight-beta]: https://testflight.apple.com/join/vQqhuAdC
[host-beta]: https://github.com/ppanwin10/ReLand/releases/tag/v1.0.0-beta.2
