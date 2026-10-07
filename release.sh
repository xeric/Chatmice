#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Chatmice.xcodeproj}"
SCHEME="${SCHEME:-Chatmice}"
CONFIGURATION="${CONFIGURATION:-Release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
ARCHS="${ARCHS:-arm64 x86_64}"
SKIP_CODE_SIGNING="${SKIP_CODE_SIGNING:-0}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application: Juan Zhang (KJ5KHP7B96)}"
RELEASE_ENTITLEMENTS="${RELEASE_ENTITLEMENTS:-$ROOT_DIR/Chatmice/Chatmice-no-icloud.entitlements}"
DMG_BACKGROUND="${DMG_BACKGROUND:-$ROOT_DIR/Chatmice/Resources/DMGBackground.png}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
NOTARIZE="${NOTARIZE:-ask}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-15m}"
SIGN_RETRIES="${SIGN_RETRIES:-5}"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
REQUIRE_SPARKLE_SIGNATURE="${REQUIRE_SPARKLE_SIGNATURE:-0}"
KEEP_WORK_DIR_ON_FAILURE="${KEEP_WORK_DIR_ON_FAILURE:-1}"

LOCAL_RELEASE=0

usage() {
    cat <<'EOF'
Usage: ./release.sh [--local] [--help]

  --local  Build a Release archive, sign it with Developer ID, and notarize it.
           Notarization uses NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER_ID when set,
           otherwise the keychain profile named by NOTARY_PROFILE.
  --help   Show this help text.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --local)
            LOCAL_RELEASE=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ "$LOCAL_RELEASE" == "1" ]]; then
    CONFIGURATION=Release
    SKIP_CODE_SIGNING=0
    NOTARIZE=1
    echo "==> Local release mode: Developer ID signing and notarization enabled"
fi

for command in xcodebuild ditto hdiutil plutil shasum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "error: required command not found: $command" >&2
        exit 1
    fi
done

case "$NOTARIZE" in
    ask)
        SHOULD_NOTARIZE=0
        if [[ -t 0 ]]; then
            read -r -p "Notarize this release? (y/n) " -n 1 notarize_reply
            echo
            [[ "$notarize_reply" =~ ^[Yy]$ ]] && SHOULD_NOTARIZE=1
        fi
        ;;
    auto)
        SHOULD_NOTARIZE=1
        ;;
    0|1)
        SHOULD_NOTARIZE="$NOTARIZE"
        ;;
    *)
        echo "error: NOTARIZE must be 'ask', 'auto', '0', or '1'" >&2
        exit 1
        ;;
esac

notary_args=()
if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
    if [[ "$SKIP_CODE_SIGNING" == "1" ]]; then
        echo "error: notarization requires code signing" >&2
        exit 1
    fi
    if [[ -n "$NOTARY_KEY" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER_ID" ]]; then
        if [[ -z "$NOTARY_KEY" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" ]]; then
            echo "error: NOTARY_KEY, NOTARY_KEY_ID, and NOTARY_ISSUER_ID must all be set" >&2
            exit 1
        fi
        if [[ ! -f "$NOTARY_KEY" ]]; then
            echo "error: notarization key not found: $NOTARY_KEY" >&2
            exit 1
        fi
        notary_args=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    else
        notary_args=(--keychain-profile "$NOTARY_PROFILE")
    fi
    if ! notary_check_output="$(xcrun notarytool history "${notary_args[@]}" 2>&1)"; then
        echo "error: notarization credentials are invalid" >&2
        printf '%s\n' "$notary_check_output" >&2
        exit 1
    fi
    for command in xcrun codesign; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo "error: notarization command not found: $command" >&2
            exit 1
        fi
    done
fi

if [[ "$SKIP_CODE_SIGNING" != "1" ]] && ! command -v codesign >/dev/null 2>&1; then
    echo "error: required command not found: codesign" >&2
    exit 1
fi

if [[ "$SKIP_CODE_SIGNING" != "1" && ! -f "$RELEASE_ENTITLEMENTS" ]]; then
    echo "error: release entitlements not found: $RELEASE_ENTITLEMENTS" >&2
    exit 1
fi

if [[ ! -f "$DMG_BACKGROUND" ]]; then
    echo "error: DMG background not found: $DMG_BACKGROUND" >&2
    exit 1
fi

sign_with_retry() {
    local target="$1"
    local attempt=1
    while (( attempt <= SIGN_RETRIES )); do
        if codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp \
            --preserve-metadata=identifier,entitlements,flags,requirements "$target"; then
            return 0
        fi
        if (( attempt == SIGN_RETRIES )); then
            echo "error: failed to sign after $SIGN_RETRIES attempts: $target" >&2
            return 1
        fi
        echo "warning: timestamp service unavailable; retrying signature ($attempt/$SIGN_RETRIES)" >&2
        sleep 5
        ((attempt += 1))
    done
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chatmice-release.XXXXXX")"
ARCHIVE_PATH="$WORK_DIR/Chatmice.xcarchive"
DERIVED_DATA_PATH="$WORK_DIR/DerivedData"
DMG_ROOT="$WORK_DIR/dmg-root"
DMG_RW_IMAGE="$WORK_DIR/Chatmice-rw.dmg"
DMG_MOUNT_POINT="$WORK_DIR/dmg-mount"
NOTARY_ZIP="$WORK_DIR/notarization.zip"

cleanup() {
    local status=$?
    if [[ -d "$DMG_MOUNT_POINT" ]]; then
        hdiutil detach "$DMG_MOUNT_POINT" -quiet -force >/dev/null 2>&1 || true
    fi
    if [[ "$status" != "0" && "$KEEP_WORK_DIR_ON_FAILURE" == "1" ]]; then
        echo "error: release workspace retained for diagnostics: $WORK_DIR" >&2
        return
    fi
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
    "CODE_SIGN_ENTITLEMENTS=$RELEASE_ENTITLEMENTS"
)

if [[ "$SKIP_CODE_SIGNING" == "1" ]]; then
    build_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
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
    echo "==> Applying trusted timestamps"
    SPARKLE_ROOT="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/Current"
    for target in \
        "$SPARKLE_ROOT/Autoupdate" \
        "$SPARKLE_ROOT/XPCServices/Downloader.xpc" \
        "$SPARKLE_ROOT/XPCServices/Installer.xpc" \
        "$SPARKLE_ROOT/Updater.app" \
        "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
        "$APP_PATH"; do
        [[ -e "$target" ]] && sign_with_retry "$target"
    done

    echo "==> Verifying Developer ID signature"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
    echo "==> Notarizing application"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" "${notary_args[@]}" --wait --timeout "$NOTARY_TIMEOUT"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

echo "==> Creating Sparkle ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Creating styled DMG"
mkdir -p "$DMG_ROOT" "$DMG_MOUNT_POINT"
ditto "$APP_PATH" "$DMG_ROOT/Chatmice.app"
ln -s /Applications "$DMG_ROOT/Applications"

for mounted_volume in "/Volumes/Chatmice $VERSION" "/Volumes/Chatmice $VERSION "*; do
    if [[ -d "$mounted_volume" ]]; then
        hdiutil detach "$mounted_volume" -quiet -force
    fi
done

hdiutil create -quiet \
    -volname "Chatmice $VERSION" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    "$DMG_RW_IMAGE"

hdiutil attach "$DMG_RW_IMAGE" -quiet -readwrite -noverify -noautoopen -mountpoint "$DMG_MOUNT_POINT"

osascript - "$DMG_MOUNT_POINT" <<'APPLESCRIPT'
on run argv
    set mountPoint to item 1 of argv
    set backgroundFile to POSIX file (mountPoint & "/Chatmice.app/Contents/Resources/DMGBackground.png") as alias
    tell application "Finder"
        set diskFolder to POSIX file mountPoint as alias
        open diskFolder
        delay 1
        set theWindow to container window of diskFolder
        set current view of theWindow to icon view
        tell theWindow
            try
                set toolbar visible to false
            end try
            try
                set statusbar visible to false
            end try
            try
                set pathbar visible to false
            end try
        end tell
        set bounds of theWindow to {120, 120, 888, 632}
        set theViewOptions to icon view options of theWindow
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set text size of theViewOptions to 14
        set background picture of theViewOptions to backgroundFile
        set position of item "Chatmice.app" of diskFolder to {190, 260}
        set position of item "Applications" of diskFolder to {578, 260}
        update diskFolder without registering applications
        delay 3
        try
            close theWindow
        end try
        delay 1
    end tell
end run
APPLESCRIPT

if [[ ! -s "$DMG_MOUNT_POINT/.DS_Store" ]]; then
    echo "error: Finder did not persist the DMG window layout" >&2
    exit 1
fi

rm -rf "$DMG_MOUNT_POINT/.fseventsd" "$DMG_MOUNT_POINT/.Trashes"
sync
hdiutil detach "$DMG_MOUNT_POINT" -quiet
rm -rf "$DMG_MOUNT_POINT"
hdiutil convert "$DMG_RW_IMAGE" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"

if [[ "$SKIP_CODE_SIGNING" != "1" ]]; then
    echo "==> Signing DMG"
    codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

hdiutil verify "$DMG_PATH"


if [[ -z "$SPARKLE_SIGN_UPDATE" ]] && command -v sign_update >/dev/null 2>&1; then
    SPARKLE_SIGN_UPDATE="$(command -v sign_update)"
fi

if [[ -n "$SPARKLE_SIGN_UPDATE" ]]; then
    if [[ ! -x "$SPARKLE_SIGN_UPDATE" ]]; then
        echo "error: SPARKLE_SIGN_UPDATE is not executable: $SPARKLE_SIGN_UPDATE" >&2
        exit 1
    fi
    echo "==> Signing Sparkle update"
    sparkle_sign_args=()
    [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]] && sparkle_sign_args+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
    "$SPARKLE_SIGN_UPDATE" "${sparkle_sign_args[@]}" "$ZIP_PATH" | tee "$DIST_DIR/$ZIP_NAME.sparkle-signature.txt"
elif [[ "$REQUIRE_SPARKLE_SIGNATURE" == "1" ]]; then
    echo "error: sign_update not found; set SPARKLE_SIGN_UPDATE to Sparkle's sign_update binary" >&2
    exit 1
else
    echo "note: sign_update not found; ZIP created without Sparkle signature metadata" >&2
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
notarized=$([[ "$SHOULD_NOTARIZE" == "1" ]] && echo true || echo false)
local_release=$([[ "$LOCAL_RELEASE" == "1" ]] && echo true || echo false)
EOF

printf '\nRelease artifacts:\n'
printf '  %s\n' "$ZIP_PATH" "$DMG_PATH" "$DIST_DIR/SHA256SUMS" "$DIST_DIR/release-info.txt"
