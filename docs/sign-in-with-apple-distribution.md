# Sign in with Apple and Developer ID Distribution

Status: accepted  
Last verified: July 22, 2026

## Decision

Candoa's public website download is a Developer ID-signed, notarized DMG. It must use
Sign in with Apple for the web, initiated with `ASWebAuthenticationSession`, rather than
the native `ASAuthorizationAppleIDProvider` flow.

Apple's current [supported capabilities for macOS](https://developer.apple.com/help/account/reference/supported-capabilities-macos)
list Sign in with Apple for Apple Developer Program distribution but not for Developer ID.
Consequently, the public DMG must not contain the `com.apple.developer.applesignin`
entitlement.

## Why the native development test is misleading

An Apple Development provisioning profile can include Sign in with Apple and successfully
present Apple's native authorization sheet. That proves only that the development build and
developer account are configured. It does not prove that the capability can be included in a
Developer ID-signed release distributed outside the Mac App Store.

Do not treat any of these as release verification:

- A Debug build that presents the native Apple sheet.
- A successful native sign-in while signed with `Apple Development`.
- Unit tests of the identity-token exchange endpoint.
- An unsigned or ad hoc-signed local Release build.

## Required public-DMG architecture

1. Candoa creates a PKCE verifier and starts `ASWebAuthenticationSession` against
   `GET https://api.candoa.app/v1/auth/apple/web/start`.
2. CandoaCloud redirects to Apple using the configured Apple Services ID.
3. Apple returns to the registered HTTPS callback at
   `POST https://api.candoa.app/v1/auth/apple/web/callback`.
4. CandoaCloud sends a short-lived, PKCE-bound handoff to
   `candoa-auth://apple/callback`.
5. Candoa exchanges it through `POST /v1/auth/apple/web/exchange` and stores only the
   resulting Candoa session in Keychain.

The system dialog saying that Candoa wants to use the Cloud domain to sign in is expected
`ASWebAuthenticationSession` security UI. Do not attempt to suppress it, imitate it, or move
the Apple flow into an embedded `WKWebView`.

Debug builds may use `http://127.0.0.1:8787/v1` for ordinary Cloud APIs, but Apple web
authentication must still start on the deployed registered HTTPS endpoint. A separately
registered HTTPS development endpoint may be supplied explicitly; localhost and loopback
callbacks are not valid production substitutes.

## Changes that are prohibited for the current DMG

- Adding `com.apple.developer.applesignin` to `Candoa.entitlements`.
- Enabling the Xcode Sign in with Apple capability for the public target.
- Replacing the public flow with `ASAuthorizationAppleIDProvider` because it worked locally.
- Pointing Apple web authorization at `127.0.0.1` or `localhost`.
- Calling authentication complete before the deployed callback and a signed public DMG have
  both been tested.

## Release verification

Before shipping or closing an authentication issue:

1. Confirm the deployed web start route redirects to `appleid.apple.com`.
2. Complete a real Apple authorization, HTTPS callback, app handoff, and PKCE exchange.
3. Confirm account restoration works after relaunch and cancellation returns without an error.
4. Inspect the actual public app with `codesign` and confirm the signing identity is
   `Developer ID Application`.
5. Inspect the same artifact's entitlements and confirm
   `com.apple.developer.applesignin` is absent.
6. Notarize, staple, and test the packaged DMG on a clean macOS account.

## When this decision may change

The native flow may replace the web flow only if either:

- Candoa explicitly changes to a compatible distribution channel such as the Mac App Store; or
- Apple's current capability documentation and an actual Developer ID-signed release prove
  that native Sign in with Apple has become supported.

Re-check Apple's capability matrix at that time and update this document in the same change.
