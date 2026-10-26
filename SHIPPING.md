# Shipping Tape locally

The normal path is a tagged release through GitHub Actions ([`docs/RELEASING.md`](docs/RELEASING.md)). This is the
manual fallback, for example to test a notarized build or the self-updater before tagging.

## One-time setup

1. Create an app-specific password: appleid.apple.com → Sign-In & Security → App-Specific Passwords.
2. Store a notarytool profile named `Tape`:

   ```sh
   xcrun notarytool store-credentials "Tape" \
     --apple-id "YOUR_APPLE_ID_EMAIL" --team-id 82K3YC8HVF --password "xxxx-xxxx-xxxx-xxxx"
   ```

3. Copy `.env.example` to `.env` and set `DEVELOPMENT_TEAM=82K3YC8HVF`.

## Build, notarize, package

```sh
MARKETING_VERSION=0.1 ./build.sh   # Developer ID signed; omit the version for a "-local" build
./notarize.sh                       # notarytool submit --wait → staple → verify → dist/Tape-<version>.zip
```

`dist/Tape-<version>.zip` is exactly what the updater downloads, so attaching it to a `v<version>` GitHub
Release by hand is equivalent to a CI release (bump the Homebrew cask yourself).

## Testing the updater

Build an older signed version (`MARKETING_VERSION=0.9 ./build.sh`), run it from `dist/`, and use
"Check for Updates…" against a published release. It downloads, verifies and offers "Install Tape <version> and
Relaunch".

## If notarization fails

```sh
xcrun notarytool log <submission-id> --keychain-profile "Tape"
```

Usual causes: missing hardened runtime, no secure timestamp, or a `get-task-allow` entitlement; `build.sh` handles
all three for a Developer ID build.
