#!/usr/bin/env bash
# Build, sign, notarize and package a release, and generate the Sparkle appcast.
# Invoked through `make release`; see docs/releasing.md for one-time setup.
#
# Required environment:
#   VERSION            marketing version, e.g. 2.1.0 (tag will be v$VERSION)
#   DEVELOPER_ID       codesign identity, e.g. "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE     notarytool keychain profile (xcrun notarytool store-credentials)
# Optional:
#   SPARKLE_PUBLIC_KEY EdDSA public key of the update key (default: Tools/release.env,
#                      written by Tools/setup-release-secrets.sh)
#   SPARKLE_ACCOUNT    keychain account of the update key (default nvmodern; never the
#                      default "ed25519" account, which other apps on the Mac may use)
#   SPARKLE_PRIVATE_KEY the update key itself (generate_keys -x output), used instead of
#                      the keychain; the release workflow sets it from a secret
#   NOTARY_KEYCHAIN    keychain holding NOTARY_PROFILE when it isn't the login keychain
#                      (the release workflow makes a temporary one)
#   GITHUB_REPO        owner/name used for download URLs (default pier20-ai/nvmodern)
#   OUT_DIR            output directory (default dist/release)
#
# This script never publishes anything. It prints the `gh release create`
# command to run once you have checked the artifacts.
set -euo pipefail

# The update key's public half is committed here, not in project.yml, so source
# builds stay without a key (and silent); only release builds get it.
if [ -z "${SPARKLE_PUBLIC_KEY:-}" ] && [ -f Tools/release.env ]; then
  # shellcheck disable=SC1091
  . Tools/release.env
fi

: "${VERSION:?set VERSION, e.g. VERSION=2.1.0}"
: "${DEVELOPER_ID:?set DEVELOPER_ID to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
: "${SPARKLE_PUBLIC_KEY:?no update key: run Tools/setup-release-secrets.sh, or set SPARKLE_PUBLIC_KEY}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-nvmodern}"
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
[ -n "${NOTARY_KEYCHAIN:-}" ] && NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")

GITHUB_REPO="${GITHUB_REPO:-pier20-ai/nvmodern}"
OUT_DIR="${OUT_DIR:-dist/release}"
APP_NAME="nvModern"
CLI_NAME="nv3"
PROJECT="NVModern.xcodeproj"
SCHEME="NVModern"
LOG_DIR="${LOG_DIR:-/tmp/nvmodern}"

# Sparkle compares CFBundleVersion, so it must increase with every release.
# A timestamp does, and does not depend on git history length. UTC, so local
# and CI builds count on the same clock.
BUILD_NUMBER="${BUILD_NUMBER:-$(TZ=UTC date +%y%m%d%H%M)}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]; then
  echo "❌ VERSION '$VERSION' is not like 2.1.0" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID"; then
  echo "❌ Signing identity not found in keychain: $DEVELOPER_ID" >&2
  exit 1
fi
# `make release` runs XcodeGen first, which rewrites these tracked, generated files.
if [ -n "$(git status --porcelain -- . ':!NVModern.xcodeproj' ':!NVModern/Info.plist')" ]; then
  echo "❌ Working tree is not clean; commit or stash before releasing." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/upload"
DERIVED="$OUT_DIR/DerivedData"
BUILD_LOG="$LOG_DIR/release-build-$(date +%Y%m%d-%H%M%S).log"

echo "🔨 Building $APP_NAME $VERSION (build $BUILD_NUMBER), unsigned..."
# Signing happens below, inside-out, after nv3 is embedded. Letting Xcode sign
# first would be invalidated by copying nv3 into the bundle.
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS,arch=arm64' ARCHS=arm64 \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_KEY" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
    build > "$BUILD_LOG" 2>&1; then
  echo "❌ Build failed. Log: $BUILD_LOG" >&2
  exit 1
fi

PRODUCTS="$DERIVED/Build/Products/Release"
APP="$OUT_DIR/$APP_NAME.app"
cp -R "$PRODUCTS/$APP_NAME.app" "$APP"
[ -x "$PRODUCTS/$CLI_NAME" ] && cp "$PRODUCTS/$CLI_NAME" "$APP/Contents/MacOS/$CLI_NAME"

echo "🔏 Signing with hardened runtime..."
sign() { codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  B="$SPARKLE/Versions/B"
  for xpc in "$B"/XPCServices/*.xpc; do [ -e "$xpc" ] && sign "$xpc"; done
  [ -e "$B/Autoupdate" ] && sign "$B/Autoupdate"
  [ -e "$B/Updater.app" ] && sign "$B/Updater.app"
  sign "$SPARKLE"
fi
[ -x "$APP/Contents/MacOS/$CLI_NAME" ] && sign "$APP/Contents/MacOS/$CLI_NAME"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "📮 Notarizing the app (this can take several minutes)..."
# Stapling the app itself (not only the DMG) lets it pass Gatekeeper offline,
# including when Sparkle installs it from the DMG.
APP_ZIP="$OUT_DIR/$APP_NAME-notarize.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$APP"
rm -f "$APP_ZIP"

echo "💿 Creating DMG..."
STAGE="$OUT_DIR/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT_DIR/upload/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG" > /dev/null
sign "$DMG"

echo "📮 Notarizing the DMG..."
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true

echo "📰 Generating appcast..."
GEN="$(find "$DERIVED/SourcePackages/artifacts" -type f -name generate_appcast -perm -u+x 2>/dev/null | head -n 1)"
if [ -z "$GEN" ]; then
  echo "❌ Could not find Sparkle's generate_appcast under $DERIVED" >&2
  exit 1
fi
# The private EdDSA key: $SPARKLE_PRIVATE_KEY (CI), else the login keychain item
# for account $SPARKLE_ACCOUNT (made by Tools/setup-release-secrets.sh).
KEY_ARGS=(--account "$SPARKLE_ACCOUNT")
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  KEY_FILE="$(mktemp)"
  trap 'rm -f "$KEY_FILE"' EXIT
  (umask 077; printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE")
  KEY_ARGS=(--ed-key-file "$KEY_FILE")
fi
"$GEN" "${KEY_ARGS[@]}" \
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/" \
  -o "$OUT_DIR/upload/appcast.xml" "$OUT_DIR/upload"
[ -n "${KEY_FILE:-}" ] && rm -f "$KEY_FILE"
grep -q 'sparkle:edSignature=' "$OUT_DIR/upload/appcast.xml" \
  || { echo "❌ appcast.xml has no EdDSA signature" >&2; exit 1; }

# A stable-named copy gives README and website a permanent download link:
# https://github.com/$GITHUB_REPO/releases/latest/download/nvModern.dmg
# Made after generate_appcast so the feed lists only the versioned DMG.
cp "$DMG" "$OUT_DIR/upload/$APP_NAME.dmg"
( cd "$OUT_DIR/upload" && shasum -a 256 "$APP_NAME-$VERSION.dmg" "$APP_NAME.dmg" > "$APP_NAME-$VERSION.sha256" )

rm -rf "$STAGE"
echo
echo "✅ Release artifacts are in $OUT_DIR/upload:"
ls -1 "$OUT_DIR/upload"
echo
echo "Review them, then publish (drafts first is safest):"
echo "  gh release create v$VERSION $OUT_DIR/upload/$APP_NAME-$VERSION.dmg $OUT_DIR/upload/$APP_NAME.dmg \\"
echo "    $OUT_DIR/upload/$APP_NAME-$VERSION.sha256 $OUT_DIR/upload/appcast.xml \\"
echo "    --repo $GITHUB_REPO --title \"$APP_NAME $VERSION\" --generate-notes --draft"
