# Contributing to Candoa

Candoa is a native macOS, WebKit-based browser project. Keep changes small, scoped, and aligned with the repository's product guardrails.

## Workflow

1. Start with a GitHub issue unless the change is very small.
2. Use Discussions for open-ended questions, product direction, or rough feature ideas.
3. Maintainers triage issues with labels, priority, status, and a release milestone.
4. Open a pull request that links the issue with `Closes #123`.
5. Keep each PR focused on one behavior or fix.

## Labels

- `type: bug`, `type: feature`, `type: polish`, `type: docs`, `type: maintenance`
- `area: ui`, `area: sidebar`, `area: webkit`, `area: battery`, `area: keyboard`, `area: release`
- `priority: p0`, `priority: p1`, `priority: p2`, `priority: p3`
- `status: needs triage`, `status: ready`, `status: blocked`, `status: needs design`, `status: needs verification`
- `release-blocker`, `good first issue`, `help wanted`

## Product Guardrails

- Prefer native SwiftUI/AppKit controls and SF Symbols.
- Do not reimplement standard macOS controls when the system control can be configured.
- Keep motion restrained. Native feel comes from geometry, responsiveness, and quiet state changes.
- Do not add steady-state battery, memory, WebKit process, timer, observer, or cross-process messaging costs.
- Preserve WKWebView lifecycle separation from SwiftUI view state.
- Every user-facing string must go through a localization API (`Text`, `Label`, `String(localized:)`, and friends — never a plain `String` literal handed to the UI) and must have an entry in `Candoa/Resources/Localizable.xcstrings`. After adding or changing user-facing copy, run the Debug build and then `Scripts/check-localization.py --fix` to sync the catalog; CI fails on uncataloged strings.
- The MVP ships localized in Spanish, French, German, Japanese, Simplified Chinese, and Brazilian Portuguese (English is the source language). New user-facing strings need translations for all six locales in the catalog before merging — CI fails on untranslated MVP-locale entries. Counts use catalog plural variations, never `count == 1` ternaries; brand names stay verbatim.

## Pull Request Expectations

Before requesting review, verify the app builds and manually check the changed workflow. For changes touching web view lifecycle, injected scripts, timers, media playback, hibernation, or content blocking, include an energy or idle-resource sanity check in the PR notes.
