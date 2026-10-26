#!/usr/bin/env bash
# Notarize and staple dist/Tape.app after a Developer ID signed ./build.sh.
# Credentials: NOTARY_PROFILE (a notarytool keychain profile), or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER, in .env.
set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] && { set -a; source ./.env; set +a; }

NOTARY_AUTH=()
if [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
  NOTARY_AUTH=( --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" )
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_AUTH=( --keychain-profile "$NOTARY_PROFILE" )
else
  echo "✗ No notarytool credentials. Set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER (see SHIPPING.md)."; exit 1
fi

APP="dist/Tape.app"
[[ -d "$APP" ]] || { echo "✗ $APP not found, run a signed ./build.sh first."; exit 1; }
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
ZIP="dist/Tape-${VERSION}.zip"

if codesign -dvv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "✗ $APP is ad-hoc signed. Set a Developer ID identity in .env and rebuild."; exit 1
fi

echo "▸ Zipping for submission…"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ Submitting to the Apple notary service (waits for the result)…"
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait

echo "▸ Stapling the ticket onto the app…"
xcrun stapler staple "$APP"

echo "▸ Verifying…"
xcrun stapler validate "$APP"
codesign --verify --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "82K3YC8HVF" and identifier "dev.gustaf.tape"' "$APP"

echo "▸ Repackaging the stapled app…"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "✅ Notarized & stapled: $APP"
echo "   Release asset: $ZIP"
