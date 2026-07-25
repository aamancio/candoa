# Candoa Browser

A lightweight browser workspace for macOS.

Candoa Browser is an open-source Mac browser workspace for people who live in tabs, move
between projects, and want browsing to stay native, quiet, and
battery-conscious.

[Website](https://candoa.app)

## Why Candoa Browser

Most modern browsers ship a whole cross-platform stack. Candoa Browser takes a simpler
Mac-first path: SwiftUI, AppKit where native behavior needs it, and Apple's
WebKit through `WKWebView`.

That means Candoa Browser can focus on the workflow:

- A sidebar-first browser surface
- Spaces for separating work, personal browsing, projects, and research
- Pinned tabs and vertical tabs
- Fast keyboard navigation
- Split view for two pages at once
- Local session restore and history
- Optional iCloud sync for workspace state
- Automatic updates through Sparkle

Candoa Browser is built independently with native Apple technologies and WebKit.

## Status

Candoa Browser is an early public prototype. The core shell, WebKit tab model, Spaces,
pinned tabs, split view, local persistence, Sparkle updates, and the first sync
hooks are in place.

Expect rough edges. The project is still shaping the daily browsing experience,
with battery efficiency and native macOS behavior treated as product features,
not implementation details.

## Download

Get the latest public build from the website:

[candoa.app](https://candoa.app)

## Related

- Website: [candoa.app](https://candoa.app)
- App source: [aamancio/candoa-browser](https://github.com/aamancio/candoa-browser)
- Website and cloud source: [aamancio/candoa-cloud](https://github.com/aamancio/candoa-cloud)

## Build From Source

Requirements:

- macOS 14 or newer
- Xcode

Open `Candoa.xcodeproj`, select the `Candoa` scheme, then build and run.

From Terminal:

```sh
cd ~/Projects/Candoa/CandoaBrowser
xcodebuild -project "Candoa.xcodeproj" -scheme "Candoa" -configuration Debug -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/Candoa.app"
```

## Project Principles

- Keep the app native to macOS.
- Use WebKit, not Chromium, Electron, CEF, or Firefox.
- Preserve familiar browser shortcuts for comparable features.
- Prefer native SwiftUI and AppKit controls over custom lookalikes.
- Keep background tabs cheap so idle browsing stays efficient.
- Avoid copying another browser's visual identity.

## Keyboard Shortcuts

Candoa reserves familiar macOS browser shortcuts for comparable features.

- `Cmd+T`: New tab / command surface
- `Cmd+W`: Close current tab
- `Cmd+L`: Focus address/search bar
- `Cmd+Shift+T`: Reopen last closed tab
- `Cmd+D`: Pin or unpin current tab
- `Cmd+Shift+C`: Copy current tab URL
- `Cmd+Shift+Option+C`: Copy current tab URL as Markdown
- `Cmd+S`: Show or hide sidebar
- `Cmd+Shift+K`: Clear unpinned tabs
- `Cmd+1`, `Cmd+2`, `Cmd+3`: Go directly to a tab
- `Control+1`, `Control+2`, `Control+3`: Focus a Space
- `Control+Tab`: Toggle between recent tabs
- `Cmd+Option+Up` / `Cmd+Option+Down`: Switch tabs
- `Cmd+Option+Left` / `Cmd+Option+Right`: Switch Spaces
- `Cmd+Left` or `Cmd+[`: Back
- `Cmd+Right` or `Cmd+]`: Forward
- `Cmd+R`: Reload
- `Cmd+F`: Find in page

## For Contributors

The app is organized around a small native browser core:

- `BrowserStore` owns browser state and user actions.
- `WebViewCoordinator` owns reusable `WKWebView` instances.
- `PersistenceService` stores Spaces, tabs, selection, and local history.
- `NavigationService` handles URL and search input.
- `FaviconService` fetches and caches page icons.

Important paths:

```text
Candoa/
  App/
  Models/
  Views/
  Services/
  Web/
  Resources/
Scripts/
Benchmarks/
```

Architecture decisions:

- [Sign in with Apple and Developer ID distribution](docs/sign-in-with-apple-distribution.md)

Contributions are welcome, especially around native Mac behavior,
keyboard-first browsing, WebKit lifecycle, and battery efficiency.

Please keep changes aligned with the project principles above. In particular,
do not introduce another browser engine, do not add idle polling, and do not
copy another browser's branding, icons, assets, or exact UI.

## Releases

Release builds are packaged as a drag-to-Applications DMG. The GitHub workflow
on `main` publishes the signed DMG, `latest.json`, and Sparkle `appcast.xml` to
the Candoa Cloud repository.

Because that DMG uses Developer ID distribution, account authentication must
follow the tracked [Sign in with Apple distribution decision](docs/sign-in-with-apple-distribution.md).

Local DMG packaging:

```sh
xcodebuild -project "Candoa.xcodeproj" -scheme "Candoa" -configuration Release -derivedDataPath build/DerivedData build
Scripts/package_dmg.sh \
  build/DerivedData/Build/Products/Release/Candoa.app \
  artifacts/Candoa.dmg
```

## License

Candoa is open source under the Mozilla Public License 2.0. See `LICENSE`.

## Trademark

The Candoa name, icon, and app identity are not covered by the source-code
license. Forks and modified builds should use a different name and identity.

See `TRADEMARKS.md` for the project trademark policy.
