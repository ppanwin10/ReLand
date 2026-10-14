# Contributing to ReLand

## Setup

```sh
brew install xcodegen tmux
cp Config/Local.xcconfig.example Config/Local.xcconfig
./Scripts/bootstrap
./Scripts/test-unit
```

Set your Apple team ID only in ignored `Config/Local.xcconfig`.

## Generated project

`ReLand.xcodeproj` is generated and ignored. Edit `project.yml`; do not commit
generated project changes.

## Source boundaries

- `Apps/ReLandClient` — iOS/iPadOS UI and state.
- `Apps/ReLandHost` — macOS UI and host composition.
- `Packages/ReLandCore/Sources/ReLandCore` — shared transport, protocol,
  security, and models.
- `Packages/ReLandCore/Sources/ReLandHostCore` — host capture, input,
  terminal, file, and server services.
- `Tests/ReLandE2EHost` / `Tests/ReLandUITests` — deterministic UI tests.
- `Apps/ReLandWindowsHost` — native Windows UI, desktop capture/input, and
  current-user protected credential storage.
- `Packages/ReLandWindowsCore` — Windows host protocol, TLS-PSK, pairing,
  private-network policy, and controller coordination.
- `Tests/ReLandWindowsTests` — Windows protocol/integration, storage, and
  native input-planning tests.
- `Tests/ReLandWindowsUiReview` — synthetic host-window review helper, run on
  a separate noninteractive Windows desktop by the Windows test suite.

Keep dependencies directed from apps to packages and from `ReLandHostCore` to
`ReLandCore`.
The Windows app depends on `ReLandWindowsCore`; its transport and models must
remain compatible with the shared Swift wire contract rather than changing
the Apple package manifests. Run the Windows checks with:

```powershell
dotnet test Tests\ReLandWindowsTests\ReLandWindowsTests.csproj
```

Windows tests use synthetic desktop/input services and loopback TLS sessions;
they must never inject input into the contributor's actual desktop or capture
personal screen content. Apple model/UI changes still require the Mac,
iPhone, and iPad review described below.

The deterministic Apple E2E executable uses its main port plus one for the
desktop-only Windows fixture and plus two for a loopback-only reconnect
control. Reconnect assertions keep the synthetic host offline until the test
explicitly restores its listener; no production app includes that control.

## Change workflow

1. Add a focused failing test.
2. Run it and confirm the intended RED result.
3. Implement the smallest correct change.
4. Run the targeted test and relevant integration/E2E suite.
5. Refactor only while tests remain green.

Do not add broad catches, silent fallbacks, unsafe force-casts, or destructive
cleanup that can cross an app-owned boundary.

## AI-assisted development

Project Agent Skills are committed under `.agents/skills/` and require no
separate installation in compatible tools. Read
[`docs/AI_WORKFLOW.md`](docs/AI_WORKFLOW.md) for discovery paths, explicit
invocation examples, the feature-development sequence, the pre-PR checklist,
and the review workflow.

Use:

- `reland-ui-ux` during user-facing implementation;
- `reland-e2e-review` after completing behavior changes;
- `code-review` before creating, approving, or merging a pull request.

AI review is advisory. Every external contribution still requires the human
approval, passing checks, latest-push approval, and resolved conversations
defined below.

## Review and merge

- Submit changes through a pull request; contributors cannot push to `main`.
- External workflow runs require maintainer approval.
- Resolve every review conversation and keep the required `verify` check green.
- Security-sensitive areas listed in `.github/CODEOWNERS` request maintainer
  review automatically.
- The required `Repository Policy` workflow loads scanners from the base branch
  and rejects pull-request changes to workflows, scripts, build/signing
  configuration, vendored dependencies, all SwiftPM manifests and lockfiles,
  privacy manifests, and security policies.
- Workflows may not request write tokens, secrets, OIDC, persisted checkout
  credentials, `pull_request_target`, third-party actions, or unpinned actions.
- External changes require one code-owner approval and re-approval after each
  new push. Owner-authored changes use the audited ruleset bypass while ReLand
  has only one maintainer.
- ReLand uses squash-only merges so `main` receives one verified signed commit.
- Never ask a maintainer to bypass a failed or missing required check.

When a second trusted maintainer is added, the repository will require one
independent code-owner approval and approval of the latest push.

## Protocol changes

Before adding a wire message:

- update `docs/PROTOCOL.md`;
- assign the message in the correct domain range;
- define typed request/response models;
- add codec and integration tests;
- preserve compatibility or bump the protocol deliberately;
- add a stable structured error code where applicable.

## UI changes

- support loading, empty, error, and retry states;
- use 44-point minimum targets;
- verify VoiceOver, Dynamic Type, light/dark mode, Reduce Motion, iPhone, and
  iPad layouts;
- avoid user-visible strings in test-only fixtures;
- capture only redacted screenshots.

## Security and privacy

Never commit:

- credentials, tokens, private keys, pairing payloads, or signing files;
- personal screenshots or recordings;
- private hostnames, addresses, paths, or terminal output;
- production diagnostics without redaction.

Security-sensitive reports belong in the private security reporting flow.
