---
name: reland-e2e-review
description: Runs the required post-feature ReLand review with the macOS host, iPhone and iPad simulators, focused XCUITests, and redacted screenshots or recordings. Use automatically after implementing any feature or user-visible behavior change and before claiming completion, especially for SwiftUI, terminal, files, pairing, capture, protocol, or host changes.
license: Apache-2.0
compatibility: ReLand repository on macOS with Xcode, XcodeGen, tmux, and available iPhone and iPad simulators.
metadata:
  author: ppanwin10
  version: "1.0"
---

# ReLand E2E Feature Review

Treat running-app review as part of implementation, not an optional final
check. A user-visible feature is not complete until the changed behavior has
been exercised through the real client/host boundary and visually inspected.

## Completion gate

Use this skill after the implementation is functionally complete and before
reporting success.

| Change | Required review |
| --- | --- |
| Shared model, protocol, terminal, file, pairing, or capture behavior | Focused core/integration test, host build, and deterministic simulator E2E |
| iPhone or iPad UI | Focused XCUITest, iPhone and iPad coverage, and screenshots |
| Animation, transition, scrolling, gesture, material, or layout behavior | Running simulator review plus a short recording or before/after screenshots |
| ReLand Host UI | ReLandHost build, running Mac app review, and a redacted host-window screenshot |
| Documentation only | No runtime review unless the documentation claims changed behavior |

Do not substitute a successful compile, unit test, snapshot of source code, or
static reasoning for observing a user-facing change in the running app.

## Workflow

Run every command from an isolated review workspace:

```sh
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
ARTIFACT_ROOT=$(mktemp -d \
  "${TMPDIR:-/tmp}/reland-e2e-review.XXXXXX")
export ARTIFACT_ROOT
```

Use a dedicated simulator when possible. Do not erase, reset, or repurpose a
simulator that contains unrelated user work.

### 1. Define the user scenario

Before running commands, write down:

- the user goal;
- the starting state;
- the exact interaction sequence;
- the expected visible result;
- one important failure, empty, reconnect, or cancellation path.

Review the relevant existing tests in `Tests/ReLandUITests/ReLandUITests.swift`
and host fixtures in `Tests/ReLandE2EHost/main.swift`. Extend an existing flow
when it owns the scenario; add a focused test when the behavior needs isolated
regression coverage.

### 2. Protect the environment

- Keep evidence outside the repository, such as a session-artifact directory
  or a specifically named directory under `${TMPDIR:-/tmp}`.
- Never capture pairing codes, credentials, private addresses, personal
  hostnames, real terminal output, unrelated windows, or user files.
- Prefer the deterministic E2E host and synthetic fixtures.
- Synthetic fixture names must be neutral and clearly fake. Treat
  personal-looking names as sensitive even when they came from test data.
- Never stop, replace, or reinstall the user's running ReLand apps, and never
  kill live tmux sessions, unless the user explicitly requested deployment.
- Do not modify protected workflows, scripts, signing files, package manifests,
  vendored code, or security policy merely to make a review command easier.

### 3. Confirm regression coverage

For a bug or changed behavior:

1. Confirm the implementation includes the smallest test that expresses the
   user contract.
2. If coverage is missing, add it before completing the review.
3. Confirm the regression detects the prior behavior when practical.
4. Run the focused test against the completed implementation.

Use stable accessibility identifiers for controls. Wait for observable state;
do not add arbitrary sleeps when an element, label, callback, or network
response can be awaited.

### 4. Run the project checks

Start with the smallest relevant Swift test:

```sh
cd Packages/ReLandCore
swift test --filter RelevantTestName
```

Before completion, run the repository unit/security entrypoint:

```sh
cd "$REPO_ROOT"
./Scripts/test-unit
```

Regenerate the ignored Xcode project through the repository entrypoint:

```sh
cd "$REPO_ROOT"
./Scripts/bootstrap
```

Build the real Mac host:

```sh
xcodebuild \
  -project ReLand.xcodeproj \
  -scheme ReLandHost \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ARTIFACT_ROOT/HostDerived" \
  build \
  -quiet
```

Run the canonical deterministic iPhone and iPad suite:

```sh
unset RELAND_E2E_USE_TMUX
RELAND_IOS_DERIVED_DATA="$ARTIFACT_ROOT/IOSDerived" \
RELAND_E2E_DERIVED_DATA="$ARTIFACT_ROOT/E2EHostDerived" \
./Scripts/test-e2e-simulator
```

Before an adaptive or user-interface completion review, inspect
`xcrun simctl list devices available` and ensure both an iPhone and an iPad are
available. Use dedicated ReLand review simulators and set
`RELAND_IPHONE_UDID` and `RELAND_IPAD_UDID` explicitly. Do not rely on automatic
simulator selection for a visual review. The script can skip iPad when none is
available; that is an incomplete UI review and must be reported, not treated as
iPad coverage.

The script performs a best-effort local-network privacy grant that some
simulator runtimes do not support. Do not treat that command as evidence.
Require the app's observable `Connected` state and completed scenario.

During iteration, a focused `xcodebuild test-without-building
-only-testing:...` run is encouraged, but do not edit the protected E2E script
just to select a test. The canonical suite remains the completion gate for a
cross-device feature.

### 5. Review the running Mac host

When host UI or host composition changed, inspect the built
`ReLandHost.app`, not only `ReLandE2EHost`.

- Check whether port `45454` is already owned before launching another host.
- Do not terminate the installed host without explicit permission.
- `RELAND_SYNTHETIC=1` replaces capture/input behavior only. It does not
  isolate Keychain credentials, approved folders, tmux sessions, storage,
  hostname, or network address.
- Review host UI from a dedicated macOS test account when screenshots or
  recordings could expose persisted state. Otherwise build the host and use
  `ReLandE2EHost` for the cross-device behavior without capturing the real host
  window.
- Verify the exact host state involved: permissions, connection count,
  terminal list, approved folders, error state, or recovery behavior.

For host-service changes without host UI, the real host build plus deterministic
client/host E2E may be sufficient. State that scope explicitly.

### 6. Capture visual evidence

Prefer XCTest attachments for stable states:

```swift
let screenshot = XCTAttachment(
    screenshot: XCUIScreen.main.screenshot()
)
screenshot.name = "Feature state"
screenshot.lifetime = .keepAlways
add(screenshot)
```

The repository already has `attachScreenshot(named:)` in
`Tests/ReLandUITests/ReLandUITests.swift`; reuse it.

For a simulator screenshot:

```sh
xcrun simctl io "$UDID" screenshot "$ARTIFACT_ROOT/feature.png"
```

For animation, scrolling, gesture, or transition review:

```sh
xcrun simctl io "$UDID" recordVideo \
  --codec=h264 \
  "$ARTIFACT_ROOT/feature.mov"
```

Run the recorder in a tracked background process, perform only the focused
scenario, then send SIGINT to that exact recorder process so the movie is
finalized. Do not use `pkill` or `killall`.

For a Mac host window, prefer a window-only capture:

```sh
screencapture -x -l "$WINDOW_ID" "$ARTIFACT_ROOT/host.png"
```

Use Mac screen recording only on a clean synthetic desktop:

```sh
screencapture -v -V8 -D1 "$ARTIFACT_ROOT/host.mov"
```

Review every artifact before sharing it. Keep personal or unredacted captures
out of git.

### 7. Inspect behavior, not only pixels

Check:

- the intended control is discoverable and has a 44-point target;
- loading, empty, error, retry, cancellation, and reconnect states;
- iPhone and iPad layouts, portrait and relevant landscape behavior;
- light and dark appearance;
- VoiceOver labels, Dynamic Type, and Reduce Motion;
- keyboard focus where applicable;
- destructive confirmation and rollback behavior;
- stable colors and materials before, during, and after scrolling;
- animation start/end states, interruption, and reduced-motion behavior;
- no stale data, duplicate requests, or sandbox/production response mismatch.

For animation, watch the recording at normal speed. Look for flashes, theme
changes, content jumps, clipped frames, delayed touch response, and controls
moving under the user's finger.

## Failure handling

- If the changed scenario fails, fix it and repeat the focused review.
- If the full suite exposes contamination between tests, restore fixture state
  inside the test rather than relying on test order.
- If infrastructure blocks the run, try a focused simulator and host build,
  preserve the failure evidence, and report the exact gap. Do not claim full
  E2E completion.
- Do not dismiss a visual defect because assertions pass.

## Completion report

Report only evidence relevant to the feature:

- scenario exercised;
- simulator/device and OS generation;
- host used (`ReLandE2EHost` or real `ReLandHost`);
- focused and canonical commands;
- whether both iPhone and iPad actually ran;
- screenshot or recording location outside the repository;
- any unreviewed state or limitation.

After this skill passes, the temporary evidence may be removed unless the user
asked to retain it.
