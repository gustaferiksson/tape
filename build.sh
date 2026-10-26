#!/usr/bin/env bash
# Build Tape.app into ./dist. Ad-hoc signed unless .env sets a team identity.
# Requires: Xcode, xcodegen (brew install xcodegen), rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env ]]; then
  set -a
  source ./.env
  set +a
fi

SIGN_ID="${CODE_SIGN_IDENTITY:--}"
SIGN_ARGS=( "CODE_SIGN_IDENTITY=${SIGN_ID}" )
if [[ "$SIGN_ID" != "-" ]]; then
  SIGN_ARGS+=( "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM in .env}" "OTHER_CODE_SIGN_FLAGS=--timestamp" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO" )
fi

MARKETING_VERSION="${MARKETING_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)-local}"
SIGN_ARGS+=( "MARKETING_VERSION=${MARKETING_VERSION}" )
[[ -n "${CURRENT_PROJECT_VERSION:-}" ]] && SIGN_ARGS+=( "CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}" )

echo "▸ Generating app icon…"
./icon/generate-icons.sh

echo "▸ Generating Xcode project…"
xcodegen generate

echo "▸ Building (Release)…  signing identity: ${SIGN_ID}"
xcodebuild \
  -project Tape.xcodeproj \
  -scheme Tape \
  -configuration Release \
  -derivedDataPath .build \
  "${SIGN_ARGS[@]}" \
  build

mkdir -p dist
rm -rf dist/Tape.app
cp -R .build/Build/Products/Release/Tape.app dist/Tape.app

echo "✅ Built dist/Tape.app"
[[ "$SIGN_ID" != "-" ]] && echo "   Notarize: ./notarize.sh"
echo "   Launch: open dist/Tape.app"
echo "   Test:   swift test --package-path Packages/TapeCore"
