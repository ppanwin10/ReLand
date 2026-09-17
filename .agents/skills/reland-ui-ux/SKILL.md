---
name: reland-ui-ux
description: Applies ReLand's user-centered Apple-platform UI and UX standards. Use automatically for every SwiftUI view, navigation, sheet, menu, control, copy, theme, layout, animation, accessibility, or other user-facing change so new work preserves the existing design instead of introducing generic or inconsistent UI.
license: Apache-2.0
compatibility: ReLand SwiftUI client and host applications targeting iOS, iPadOS, and macOS.
metadata:
  author: ppanwin10
  version: "1.0"
---

# ReLand UI/UX

Design from the user's task outward. Prefer native Apple behavior and the
existing ReLand design language over novel decoration, generic generated
design systems, or implementation-driven layouts.

## Source-of-truth order

Resolve design decisions in this order:

1. The user's goal, mental model, safety, and expected terminology.
2. Apple platform conventions and native SwiftUI behavior.
3. Existing nearby ReLand screens and interaction patterns.
4. Client design tokens in `Apps/ReLandClient/App/ReLandTheme.swift`, or
   existing `HostCard` and semantic system-color patterns for ReLand Host.
5. Visual polish that does not weaken the first four priorities.

Do not import web typography, arbitrary palettes, emoji icons, or a new visual
style into one feature. ReLand uses system typography, SF Symbols, semantic
system colors, and established app-specific patterns.

## Before editing

Read:

- the complete containing view and its presentation context;
- adjacent views that solve a similar interaction;
- `Apps/ReLandClient/App/ReLandTheme.swift` for client work, or nearby
  `Apps/ReLandHost` views and `HostCard` usage for host work;
- the corresponding `ClientAppModel` or `HostAppModel` state and error flow;
- existing accessibility identifiers and XCUITests;
- the UI and privacy rules in `CONTRIBUTING.md`.

Write down the user task, primary action, secondary actions, destructive
actions, and states before choosing a component.

## Information hierarchy

- Give every screen or sheet one clear subject.
- Use the object's name as the title when the context is object-specific.
- Do not repeat the same identity in both the navigation title and a leading
  summary card unless the card adds actionable information.
- Prefer direct content over decorative cards.
- Put the primary action where the user expects it; place secondary utilities
  under a clearly labeled `More` action or contextual sheet.
- Use progressive disclosure. Do not crowd a row with several unexplained
  icons.
- Keep section names task-oriented and short: `Open`, `Files`, `Manage`.
- Preserve the user's location and state when presenting or dismissing sheets.

## Controls and interaction

- Use native `Button`, `List`, `Form`, `NavigationStack`, `Menu`, `sheet`,
  `confirmationDialog`, and system search/navigation patterns before custom
  controls.
- Every touch target must be at least 44 by 44 points.
- Icon-only controls require an unambiguous standard symbol and an
  accessibility label. If users may not recognize the icon, show text such as
  `More`.
- Do not hide the only destructive action behind a swipe gesture. A contextual
  action sheet may also offer it with confirmation.
- Disable or show progress for submitting actions; prevent duplicate requests.
- Keep cancel/done behavior predictable and use `@Environment(\.dismiss)`.
- Never silently ignore invalid input. Show an actionable error near the task
  or through the established model alert path.

## Sheets, scrolling, and materials

- Name an object-specific sheet with the object name, not a generic title such
  as `Options`.
- Avoid a redundant identity card directly below that title.
- Choose detents for the amount of content; content may scroll, but the
  hierarchy must remain understandable at every detent.
- System scroll-edge material may transition from transparent to opaque when a
  list crosses a threshold. If that reads as an unintended theme change, pin
  the list, presentation, and toolbar to the same dynamic background:

```swift
.scrollContentBackground(.hidden)
.background(ReLandTheme.canvas)
.toolbarBackground(ReLandTheme.canvas, for: .navigationBar)
.toolbarBackground(.visible, for: .navigationBar)
.presentationBackground(ReLandTheme.canvas)
```

- Use dynamic semantic colors so the same surface remains correct in light and
  dark mode.
- Do not create color or material changes that are triggered accidentally by
  scrolling, detent expansion, focus, or keyboard appearance.

## ReLand visual language

- In the iPhone/iPad client, reuse `ReLandTheme.accent`,
  `controlBackground`, `chromeBackground`, `canvas`, `surface`, `strongText`,
  and `mutedText`.
- In ReLand Host, reuse `HostCard`, standard macOS controls, and semantic
  SwiftUI colors from nearby host views. Do not import the UIKit-backed
  `ReLandTheme` into the macOS target.
- Add a new token only when the meaning is reusable across multiple surfaces.
- Use SF Symbols consistently. Decorative icons are hidden from accessibility;
  meaningful controls expose labels and hints.
- Use system font styles (`headline`, `body`, `caption`) so Dynamic Type works.
- Keep spacing regular and restrained. Dense terminal controls may be compact,
  but their hit targets remain 44 points.
- Avoid one-off shadows, gradients, glows, custom fonts, and colors that do not
  already belong to ReLand.

## Copy and terminology

- Write from the user's perspective, in sentence case, with concrete verbs.
- Prefer `Open Terminal`, `Open on Mac`, `Session Files`, and `Stop Terminal`
  over implementation jargon.
- Use `Stop` when the tmux session ends but files remain. Use `Delete` only when
  data is actually removed.
- Explain trust boundaries plainly: approved folders, read-only Mac files,
  local network, and actions performed as the user's macOS account.
- Never expose raw internal paths, IDs, protocol names, or error dumps when a
  user-facing explanation exists.
- Keep labels concise; put consequences or guidance in secondary text.

## Terminal-specific invariants

- A terminal's session ID is stable identity. Rename display metadata without
  renaming the tmux session or moving its files.
- Session files and approved Mac files are distinct concepts and must remain
  labeled as such.
- Reconnect and attachment states must be visible; do not show a ready-looking
  terminal before attachment confirmation.
- Preserve terminal content and viewport state where the established model
  supports it.
- Destructive session actions must state whether files remain.

## Required states

Every user-facing flow must cover the states that apply:

- initial/loading;
- empty;
- success;
- validation error;
- host/service error;
- retry;
- disconnected/reconnecting;
- cancellation;
- destructive confirmation;
- completion feedback.

Do not leave stale content visible as if it belongs to a newly selected device,
folder, terminal, or capture target.

## Accessibility and adaptation

- Add meaningful VoiceOver labels and hints; combine related row content.
- Do not encode state only by color.
- Support Dynamic Type without clipping important labels or actions.
- Respect Reduce Motion. Essential state changes remain understandable without
  animation.
- Review light and dark appearance.
- Review iPhone and iPad. Use size classes and native adaptive layouts rather
  than hard-coded device checks.
- Avoid horizontal scrolling for ordinary app content. Terminal viewport
  scrolling is an intentional exception and must have clear controls.
- Preserve keyboard navigation and focus where relevant on iPad and macOS.

## Animation

- Animate only to explain continuity, hierarchy, or direct manipulation.
- Typical micro-interactions should complete in roughly 150 to 300 ms.
- Prefer opacity and transform changes over layout-changing width or height
  animation.
- Avoid spring overshoot for security, destructive, or precision actions.
- Define the interrupted and reduced-motion behavior.
- Validate animation with a recording, not a single screenshot.

## Security and privacy

- Never weaken pairing, folder approval, external-link confirmation,
  clipboard policy, or destructive confirmation for convenience.
- Screenshots and recordings must use synthetic/redacted data.
- Do not commit personal screenshots, recordings, addresses, hostnames,
  terminal output, paths, credentials, or pairing material.
- Test-only fixtures must not leak user-visible debug strings into production
  UI.

## Design review checklist

Before finishing a UI change, ask:

- Can a first-time user identify the primary action without guessing an icon?
- Does the title describe the current object or task?
- Is any visible information duplicated without adding value?
- Are labels and consequences accurate?
- Are scrolling, navigation bars, sheets, and materials visually stable?
- Are all controls at least 44 points and accessible?
- Do loading, empty, error, retry, reconnect, and cancellation states work?
- Does the view adapt to iPhone, iPad, light/dark, Dynamic Type, VoiceOver, and
  Reduce Motion?
- Did the change reuse existing tokens and patterns?
- Did the implementation avoid unrelated redesign?

After the design and implementation checklist passes, activate
`reland-e2e-review` for runtime validation. Keep detailed test execution and
evidence handling in that skill rather than duplicating it here.
