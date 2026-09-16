# Release process

## Current public beta

- **iPhone and iPad:** ReLand 1.0 (5) is available through
  [TestFlight][testflight-beta].
- **Mac companion:** Download the notarized
  [ReLand Host 1.0 Beta 2][host-beta].

Install both apps, open ReLand Host on the Mac, grant the requested macOS
permissions, and pair the phone or tablet using the one-time QR code. The
TestFlight invitation remains subject to Apple's availability and tester
capacity.

## Required checks

```sh
./Scripts/test-unit
./Scripts/test-e2e-simulator
./Scripts/check-release-security
```

Also complete:

- iOS and macOS Debug builds;
- iOS and macOS Release builds;
- release-binary scan for deterministic E2E credentials;
- real-device pairing, Screen Mode, App Mode, terminal, artifact, file, and
  permission flows;
- license/notice review;
- secret and personal-data scan.

## Signing configuration

Copy `Config/Local.xcconfig.example` to ignored
`Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`.

Never commit certificates, private keys, provisioning profiles, App Store
Connect keys, or notarization credentials.

## macOS

1. Archive ReLand Host with Developer ID Application signing.
2. Verify Hardened Runtime and final entitlements.
3. Confirm Release has no `get-task-allow`, DYLD, unsigned-memory, or
   library-validation exceptions unless explicitly reviewed.
4. Package the app.
5. Submit with `notarytool`.
6. Staple the ticket.
7. Verify with `codesign`, `spctl`, and a clean macOS account.
8. Publish checksum, prerequisites, permission steps, and uninstall steps.

## iOS TestFlight

1. Archive with the ReLand bundle ID.
2. Validate required-reason API and privacy-manifest declarations.
3. Complete privacy nutrition and encryption export-compliance questions.
4. Upload to App Store Connect.
5. Test internally before requesting external beta review.
6. After approval, verify the public invitation on a non-admin Apple ID and
   update the Current public beta links above.

Current required-reason audit: the iOS target uses UserDefaults for ReLand
preferences and declares `NSPrivacyAccessedAPICategoryUserDefaults` with
reason `CA92.1`. Re-run this audit whenever dependencies or system APIs change.

## GitHub

Do not publish until the ReLand/security/legal baseline is complete. Squash
local checkpoint history into a clean initial public history, then enable
protected `main`, required CI, secret scanning, dependency alerts, issue/PR
templates, and private vulnerability reporting.

Release tags are owner-controlled by repository rules. GitHub release
immutability is enabled: once a release is published, its assets and associated
tag cannot be replaced or moved. Keep a release in draft until every asset,
signature, checksum, and note is final.

Repository workflows cannot request secrets or write permissions. Future
automated publishing must be introduced as a separately reviewed policy change
with a protected GitHub environment, narrowly scoped credentials, and an
updated trusted workflow ruleset.

[testflight-beta]: https://testflight.apple.com/join/vQqhuAdC
[host-beta]: https://github.com/ppanwin10/ReLand/releases/tag/v1.0.0-beta.2
