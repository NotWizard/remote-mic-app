#!/bin/zsh
set -euo pipefail

# Builds the driver-only DMG: the MiRemoteV 2ch install and uninstall packages,
# nothing else. The app ships from its own drag-install DMG (build-dmg.sh). Keeping
# the app out of this pkg is what prevents bundle relocation from ever deleting a
# user's installed Remote Mic.app during a driver install.

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
OUTPUT_DIR="$RELEASE_OUTPUT_DIR"
DISPLAY_NAME="MiRemoteV 2ch Driver"
PLIST="$ROOT/Resources/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
DMG_BASENAME="MiRemoteV2ch-Driver-$VERSION$RELEASE_ASSET_SUFFIX.dmg"
DMG="$OUTPUT_DIR/$DMG_BASENAME"
INSTALL_PACKAGE="$RELEASE_INSTALL_PACKAGE_NAME"
UNINSTALL_PACKAGE="$RELEASE_UNINSTALL_PACKAGE_NAME"
BUILD_COMPONENTS="${BUILD_COMPONENTS:-1}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"

case "$BUILD_COMPONENTS" in
  0|1) ;;
  *) print -u2 "BUILD_COMPONENTS must be 0 or 1"; exit 1 ;;
esac

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.driver-dmg-work.XXXXXX")"
STAGING="$WORK_DIR/dmg"

cleanup() {
  case "$WORK_DIR" in
    "$OUTPUT_DIR/.driver-dmg-work."*) rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

mkdir -p "$STAGING"

if [[ "$BUILD_COMPONENTS" == "1" ]]; then
  "$ROOT/scripts/build-doubao-driver.sh"
  "$ROOT/scripts/build-doubao-driver-pkg.sh"
fi

"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$OUTPUT_DIR/$INSTALL_PACKAGE" install
"$ROOT/scripts/verify-doubao-driver-pkg.sh" "$OUTPUT_DIR/$UNINSTALL_PACKAGE" uninstall

ditto --norsrc --noqtn --noacl "$OUTPUT_DIR/$INSTALL_PACKAGE" "$STAGING/$INSTALL_PACKAGE"
ditto --norsrc --noqtn --noacl "$OUTPUT_DIR/$UNINSTALL_PACKAGE" "$STAGING/$UNINSTALL_PACKAGE"

hdiutil create \
  -volname "$DISPLAY_NAME $VERSION $RELEASE_LABEL" \
  -srcfolder "$STAGING" \
  -fs "HFS+" \
  -format UDZO \
  -ov \
  "$DMG"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
fi

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_BASENAME" > "$DMG_BASENAME.sha256"
)

print "DRIVER DMG: $DMG"
print "SHA256: $DMG.sha256"
print "VERSION: $VERSION ($BUILD)"
print "RELEASE VARIANT: $RELEASE_VARIANT"
