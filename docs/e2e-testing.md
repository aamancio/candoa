# E2E Testing: the Manual Native macOS Lane

How the `CandoaUITests` XCTest UI suite runs in CI, and the environment
quirks that make tests pass locally but fail on runners (or vice versa).
Issue #85 tracks the lane's hardening history.

## Running the lane

- **CI**: the `Manual Native macOS E2E` job in `.github/workflows/ci.yml`
  runs on manual `workflow_dispatch` and on a nightly schedule (09:00 UTC)
  so regressions surface without anyone remembering to dispatch it.
- **Targeted reruns**: dispatch with the `only_testing` input set to
  comma-separated specs (e.g.
  `CandoaUITests/CandoaUITests/testName`). Targeted dispatches skip the
  quality and build jobs to keep the iteration loop tight.
- **Locally**: `Scripts/e2e-test.sh`, with `CANDOA_E2E_ONLY_TESTING` for a
  subset. Note it terminates any running Candoa instance, including an
  Xcode debug session.
- **Failure diagnosis**: `Scripts/e2e-failure-summary.sh` prints every
  failure with its message at the end of the CI job log, because tail-based
  log fetching can't reach mid-run failures. The `.xcresult` bundle is also
  uploaded as the `candoa-e2e-xcresult` artifact.

## Signing on CI

Ad-hoc-signed apps carrying restricted entitlements (iCloud, associated
domains) are killed by macOS at launch. The CI lane sets
`CANDOA_E2E_ADHOC_SIGNING=1`, which signs the app against the stripped
`CandoaCITesting.entitlements` via the `CANDOA_APP_ENTITLEMENTS`
indirection — overriding `CODE_SIGN_ENTITLEMENTS` directly would also
sandbox the UI test runner and break XCUITest automation.

## Environment quirks

Things that behave differently on CI runners than on a development Mac.
When a test passes locally and fails on CI (or the reverse), check here
first.

- **AX identifiers can vanish on runners.** The
  `account-onboarding-description` accessibility identifier is never
  exposed on CI runners (a macOS/Xcode AX difference); the test matches by
  content instead (PR #77). Any identifier-based assertion can hit this
  class of issue — when an element exists locally but not on CI, try
  matching by content or value before assuming the UI is broken.
- **First synthesized ⌘T races window key status.** Right after launch, a
  synthesized keystroke regularly lands before the window is key on CI.
  New tests must open tabs through the `openNewTabPalette`/`openFixtureTab`
  helpers, which verify the palette actually opened and retry.
- **Outside network.** `testWebsiteAppearanceRendersYouTubeInDarkMode`
  depends on reaching youtube.com from the runner. Everything else uses
  `https://fixture.candoa.test/...` pages served from
  `CANDOA_UI_TESTING_PAGE_HTML`, which need no network.
- **Native drag tests are timing-sensitive.** Drags drive a real
  `NSDraggingSession` from synthesized events; press duration, drag
  velocity, and drop-zone settle all matter, and
  `NSEvent.pressedMouseButtons` does not reflect synthesized drags (the
  app uses the `draggingSession(_:endedAt:)` callback instead, PR #84).
  Watch `testDraggingSidebarTabOntoPageEdgeCreatesSplit` for repeat flakes
  before assuming a change caused a failure.
- **Screenshots and drags don't mix.** Event synthesis blocks the test
  thread, so nothing — screenshots, notifications, queries — can run
  mid-drag. Sample or assert before and after the drag instead.

## Visual (pixel) assertions

XCUITest asserts state and AX presence, not what's composited on screen —
chrome can exist in the view hierarchy but render *behind* the
AppKit-hosted WKWebViews and every state assertion still passes (this
shipped two real bugs: the pane-reorder ghost and target ring, PR #84).

For layering-sensitive chrome, use the `windowPixelColors(at:in:)` helper
(PR #109): it samples real window-server pixels from a runner-side
`XCUIElement.screenshot()`, which sees the out-of-process WKWebView layers
an in-process snapshot cannot. `testSplitFocusRingCompositesAboveWebContent`
is the reference pattern:

- Load the solid-green `split-view-pixels` fixture so web content has an
  unmistakable baseline, and assert a pane-center pixel is green (proves
  the capture isn't blank).
- Assert **differentially** — the same physical points across two app
  states — never against absolute colors: display color-profile conversion
  shifts channels (`#00ff00` captures as anything from `[2,255,0]` to
  `[62,254,55]`).
- An in-app capture hook is not an option: `CGWindowListCreateImage` is
  removed from the current macOS SDK, and ScreenCaptureKit requires
  screen-recording consent even for a process's own windows — a
  non-starter headless. The runner-side screenshot needs no consent.
