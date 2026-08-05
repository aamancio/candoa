# Releasing Candoa

Every merge to `main` ships automatically. There is no manual release step.

## What CI does on each merge

1. Derives the build number from the commit count (`git rev-list --count HEAD`).
   This is what Sparkle compares, so every merge is an update.
2. Bumps the marketing version from conventional commits since the last `v*` tag:
   - `feat:` → minor bump (0.1.4 → 0.2.0)
   - anything else → patch bump (0.1.4 → 0.1.5)
   - the major digit is **never** bumped automatically — 1.0 is a human decision,
     made by pushing a `v1.0.0` tag manually.
3. Builds, signs, and notarizes the Release app; packages the DMG.
4. Signs the appcast and publishes DMG + appcast to candoa.app via the
   candoa-cloud repo.
5. Tags the commit `vX.Y.Z` — the anchor for the next version bump.

## What users experience

Installed apps check the appcast every 6 hours. When the feed is ahead, a
"New Candoa Version Available" pill appears in the sidebar; hovering it offers
"Restart and Update". With automatic updates on (the default), Sparkle also
downloads and installs updates silently in the background.

## Testing an update locally

Install the current release build to `/Applications`, then merge anything to
`main`. To skip the 6-hour wait, quit Candoa and delete `SULastCheckTime` from
the container prefs, then relaunch:

```bash
/usr/libexec/PlistBuddy -c "Delete :SULastCheckTime" \
  ~/Library/Containers/app.candoa.browser/Data/Library/Preferences/app.candoa.browser.plist
```
