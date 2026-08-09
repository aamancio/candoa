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

## Keyboard Shortcut Policy

Default shortcuts copy **Safari's mapping**, not Arc/Dia/Zen conventions. When assigning or changing a default:

1. Check Safari's actual binding for the equivalent feature and use it. Verify against Safari's live menu bar (System Events `AXMenuItemCmdChar`), not from memory — several "free" keys turn out bound to invisible commands (e.g. ⌘E Use Selection for Find, ⌘J Jump to Selection).
2. For features Safari doesn't have, never take keys common web apps rely on (⌘B/⌘I/⌘U formatting, ⌘K palettes and link insertion) — a browser-level binding swallows the key before the page sees it. Prefer the least-conflicted key; shifted variants (e.g. ⇧⌘E) are acceptable when nothing plain is clean.
3. Defaults live in `ShortcutDefinition.defaultShortcut`; menu items bind through `currentKeyboardShortcut` so user rebinds stay in sync. Update the README shortcut table and any affected UI tests alongside.

## Pull Request Expectations

Before requesting review, verify the app builds and manually check the changed workflow. For changes touching web view lifecycle, injected scripts, timers, media playback, hibernation, or content blocking, include an energy or idle-resource sanity check in the PR notes.
