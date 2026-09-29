#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Chatmice.xcodeproj}"
SCHEME="${SCHEME:-Chatmice}"
CONFIGURATION="${CONFIGURATION:-Release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
ARCHS="${ARCHS:-arm64 x86_64}"
SKIP_CODE_SIGNING="${SKIP_CODE_SIGNING:-0}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-KJ5KHP7B96}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
REQUIRE_SPARKLE_SIGNATURE="${REQUIRE_SPARKLE_SIGNATURE:-0}"

for command in xcodebuild ditto hdiutil plutil shasum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "error: required command not found: $command" >&2
        exit 1
    fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chatmice-release.XXXXXX")"
ARCHIVE_PATH="$WORK_DIR/Chatmice.xcarchive"
DERIVED_DATA_PATH="$WORK_DIR/DerivedData"
DMG_ROOT="$WORK_DIR/dmg-root"
NOTARY_ZIP="$WORK_DIR/notarization.zip"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

build_args=(
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=macOS"
    -archivePath "$ARCHIVE_PATH"
    -derivedDataPath "$DERIVED_DATA_PATH"
    archive
    ONLY_ACTIVE_ARCH=NO
    "ARCHS=$ARCHS"
)

if [[ "$SKIP_CODE_SIGNING" == "1" ]]; then
    build_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
else
    build_args+=(
        "CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
        "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
        CODE_SIGN_STYLE=Manual
    )
fi

echo "==> Archiving Chatmice ($CONFIGURATION, $ARCHS)"
xcodebuild "${build_args[@]}"

APP_PATH="$ARCHIVE_PATH/Products/Applications/Chatmice.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: archive did not contain Chatmice.app" >&2
    exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
BASE_NAME="Chatmice-$VERSION"
ZIP_NAME="$BASE_NAME.zip"
DMG_NAME="$BASE_NAME.dmg"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
DMG_PATH="$DIST_DIR/$DMG_NAME"

if [[ "$SKIP_CODE_SIGNING" != "1" ]]; then
    echo "==> Verifying Developer ID signature"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> Notarizing application"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

echo "==> Creating Sparkle ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Creating DMG"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/Chatmice.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
    -volname "Chatmice $VERSION" \
    -srcfolder "$DMG_ROOT" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> Notarizing DMG"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

if [[ -z "$SPARKLE_SIGN_UPDATE" ]] && command -v sign_update >/dev/null 2>&1; then
    SPARKLE_SIGN_UPDATE="$(command -v sign_update)"
fi

if [[ -n "$SPARKLE_SIGN_UPDATE" ]]; then
    if [[ ! -x "$SPARKLE_SIGN_UPDATE" ]]; then
        echo "error: SPARKLE_SIGN_UPDATE is not executable: $SPARKLE_SIGN_UPDATE" >&2
        exit 1
    fi
    echo "==> Signing Sparkle update"
    "$SPARKLE_SIGN_UPDATE" "$ZIP_PATH" | tee "$DIST_DIR/$ZIP_NAME.sparkle-signature.txt"
elif [[ "$REQUIRE_SPARKLE_SIGNATURE" == "1" ]]; then
    echo "error: sign_update not found; set SPARKLE_SIGN_UPDATE to Sparkle's sign_update binary" >&2
    exit 1
else
    echo "warning: sign_update not found; ZIP created without Sparkle signature metadata" >&2
fi

(
    cd "$DIST_DIR"
    shasum -a 256 "$ZIP_NAME" "$DMG_NAME" > SHA256SUMS
)

cat > "$DIST_DIR/release-info.txt" <<EOF
product=Chatmice
version=$VERSION
build=$BUILD_NUMBER
configuration=$CONFIGURATION
architectures=$ARCHS
code_signed=$([[ "$SKIP_CODE_SIGNING" == "1" ]] && echo false || echo true)
notarized=$([[ -n "$NOTARY_PROFILE" ]] && echo true || echo false)
EOF

printf '\nRelease artifacts:\n'
printf '  %s\n' "$ZIP_PATH" "$DMG_PATH" "$DIST_DIR/SHA256SUMS" "$DIST_DIR/release-info.txt"
