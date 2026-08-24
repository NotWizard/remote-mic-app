#!/bin/zsh
set -euo pipefail
umask 022

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
source "$ROOT/scripts/release-signing-mode.sh"
OUTPUT_DIR="$RELEASE_OUTPUT_DIR"
PLIST="$ROOT/Resources/Info.plist"
DISPLAY_NAME="Remote Mic"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST")"
RELEASE_TAG="${RELEASE_TAG:-v$VERSION}"
APP="$OUTPUT_DIR/$DISPLAY_NAME.app"
INSTALL_PACKAGE="$OUTPUT_DIR/$RELEASE_INSTALL_PACKAGE_NAME"
UNINSTALL_PACKAGE="$OUTPUT_DIR/$RELEASE_UNINSTALL_PACKAGE_NAME"
DMG="$OUTPUT_DIR/Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.dmg"
UPDATE_ZIP="$OUTPUT_DIR/Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.zip"
APPCAST="$OUTPUT_DIR/$RELEASE_APPCAST_NAME"
ZH_RELEASE_NOTES="$OUTPUT_DIR/Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.zh.txt"
EN_RELEASE_NOTES="$OUTPUT_DIR/Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.en.txt"
PUBLISHED_ZH_NOTES_BASENAME="Remote-Mic-$VERSION.zh.txt"
PUBLISHED_EN_NOTES_BASENAME="Remote-Mic-$VERSION.en.txt"
ZIP_BASENAME="${UPDATE_ZIP:t}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-$RELEASE_MODE_DEFAULT_SIGNING_IDENTITY}"
INSTALLER_SIGNING_IDENTITY="${INSTALLER_SIGNING_IDENTITY:-$RELEASE_MODE_DEFAULT_SIGNING_IDENTITY}"
GENERATE_SPARKLE_UPDATE="${GENERATE_SPARKLE_UPDATE:-1}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
# Read tolerantly so a plist with no key reaches the descriptive refusal in
# require_sparkle_signing_key_matches_app below, instead of aborting here with a
# raw plutil error before any release gate has run. verify-app.sh asserts the
# key is present in the built app independently.
APP_SPARKLE_PUBLIC_ED_KEY="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$PLIST" 2>/dev/null || true)"
NOTARY_PROFILE="${NOTARY_PROFILE:-RemoteMic-notary}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-$RELEASE_MODE_DEFAULT_DEVELOPER_TEAM_ID}"
PARALLEL_PACKAGE_NOTARIZATION="${PARALLEL_PACKAGE_NOTARIZATION:-0}"
RELEASE_STAGE_TIMEOUTS="${RELEASE_STAGE_TIMEOUTS:-0}"
RELEASE_NOTARY_TIMEOUT_SECONDS="${RELEASE_NOTARY_TIMEOUT_SECONDS:-120}"
RELEASE_STAPLE_TIMEOUT_SECONDS="${RELEASE_STAPLE_TIMEOUT_SECONDS:-45}"
RELEASE_VERIFY_TIMEOUT_SECONDS="${RELEASE_VERIFY_TIMEOUT_SECONDS:-60}"
RELEASE_STAGE_RUNNER="$ROOT/scripts/run-release-stage.sh"
PRIVATE_PRODUCTION_ENV="$ROOT/Apps/MobileWeb/.private/production.env"
CDN_DOWNLOAD_PREFIX="${RELEASE_DOWNLOAD_PREFIX:-https://download.sayall.app/mac/releases/$RELEASE_TAG/}"
RELEASE_PAGE="${RELEASE_PAGE_URL:-https://github.com/NotWizard/remote-mic-app/releases/tag/$RELEASE_TAG}"
DEFAULT_RELEASE_BUILD_SCRATCH_PATH="/private/tmp/remote-mic-swiftpm/$VERSION-$BUILD/$RELEASE_VARIANT-sayall-ai-macro-platform"
DEFAULT_RELEASE_BUILD_CACHE_PATH="/private/tmp/remote-mic-swiftpm-cache/$VERSION-$BUILD/$RELEASE_VARIANT-sayall-ai-macro-platform"
RELEASE_BUILD_SCRATCH_PATH="${REMOTE_MIC_BUILD_SCRATCH_PATH:-$DEFAULT_RELEASE_BUILD_SCRATCH_PATH}"
RELEASE_BUILD_CACHE_PATH="${REMOTE_MIC_BUILD_CACHE_PATH:-$DEFAULT_RELEASE_BUILD_CACHE_PATH}"
GENERATE_APPCAST="$RELEASE_BUILD_SCRATCH_PATH/artifacts/sparkle/Sparkle/bin/generate_appcast"
SIGN_UPDATE="$RELEASE_BUILD_SCRATCH_PATH/artifacts/sparkle/Sparkle/bin/sign_update"
GENERATE_KEYS="${SPARKLE_GENERATE_KEYS:-$RELEASE_BUILD_SCRATCH_PATH/artifacts/sparkle/Sparkle/bin/generate_keys}"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: CODE_SIGN_IDENTITY=... INSTALLER_SIGNING_IDENTITY=... SPARKLE_PRIVATE_KEY_FILE=... $0"
  exit 1
fi
require_release_developer_team "$EXPECTED_DEVELOPER_TEAM_ID"
# Printed before the build so the waiver is at the top of the run that produced
# the artifacts, not buried after twenty minutes of output.
release_signing_mode_report
if [[ "$RELEASE_SIGNING_MODE" == "adhoc" ]]; then
  # There is nothing to notarize, so there is nothing to run in parallel; the
  # parallel branch exists only to overlap two notarytool submissions.
  PARALLEL_PACKAGE_NOTARIZATION=0
fi
case "$PARALLEL_PACKAGE_NOTARIZATION" in
  0|1) ;;
  *) print -u2 "PARALLEL_PACKAGE_NOTARIZATION must be 0 or 1"; exit 1 ;;
esac
case "$GENERATE_SPARKLE_UPDATE" in
  0|1) ;;
  *) print -u2 "GENERATE_SPARKLE_UPDATE must be 0 or 1"; exit 1 ;;
esac
case "$RELEASE_STAGE_TIMEOUTS" in
  0|1) ;;
  *) print -u2 "RELEASE_STAGE_TIMEOUTS must be 0 or 1"; exit 1 ;;
esac
if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" && ! -x "$RELEASE_STAGE_RUNNER" ]]; then
  print -u2 "release stage runner is unavailable"
  exit 1
fi
if ! print -r -- "$RELEASE_TAG" | rg -q '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  print -u2 "RELEASE_TAG must be a version tag such as v1.5.0 or v1.5.0-rc.1"
  exit 1
fi
# The Sparkle notes and the appcast below are `$VERSION`'s bullets, signed into
# artifacts an updater will show. Version numbers here are prefixes of one
# another, so a `$VERSION` that is not the release the history file describes
# hands the updater a different release's notes — and the only downstream gate is
# `rg -q '^- '`, which any non-empty entry satisfies. Checked before the build so
# the refusal costs seconds instead of a full signed run.
if [[ "$GENERATE_SPARKLE_UPDATE" == "1" ]]; then
  for release_history in \
    "$ROOT/Resources/zh-Hans.lproj/ReleaseHistory.md" \
    "$ROOT/Resources/en.lproj/ReleaseHistory.md"; do
    newest_release_version="$("$ROOT/scripts/extract-release-notes.sh" \
      --newest-version "$release_history")"
    if [[ "$newest_release_version" != "$VERSION" ]]; then
      print -u2 "refusing to release: $VERSION is not the newest release-history entry"
      print -u2 "  version looked for: $VERSION (from Resources/Info.plist CFBundleShortVersionString)"
      print -u2 "  release history file: ${release_history#$ROOT/}"
      print -u2 "  newest entry present: ${newest_release_version:-<none>}"
      exit 1
    fi
  done
fi
require_release_signing_identity "$CODE_SIGN_IDENTITY" "$INSTALLER_SIGNING_IDENTITY"
if [[ "$GENERATE_SPARKLE_UPDATE" == "1" ]]; then
  # The key may live in a file or in the login keychain — the fork's own key is
  # in the keychain, so an unreadable file is only fatal when it was named.
  if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" && ! -r "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    print -u2 "SPARKLE_PRIVATE_KEY_FILE is not readable"
    exit 1
  fi
  if [[ -z "$SPARKLE_PRIVATE_KEY_FILE" && ! -x "$GENERATE_KEYS" ]]; then
    print -u2 "no Sparkle signing key is available"
    print -u2 "  set SPARKLE_PRIVATE_KEY_FILE, or make generate_keys available so the Keychain key can be looked up"
    exit 1
  fi
fi
if [[ "$RELEASE_MODE_REQUIRE_PRIVATE_SERVICES" == "1" ]]; then
  if [[ -z "${REMOTE_WEB_RELAY_URL:-}" && -r "$PRIVATE_PRODUCTION_ENV" ]]; then
    REMOTE_WEB_RELAY_URL="$(/usr/bin/sed -n 's/^REMOTE_WEB_RELAY_URL=//p' \
      "$PRIVATE_PRODUCTION_ENV" | /usr/bin/tail -n 1)"
  fi
  if [[ -z "${EARLY_ACCESS_SERVICE_URL:-}" && -r "$PRIVATE_PRODUCTION_ENV" ]]; then
    EARLY_ACCESS_SERVICE_URL="$(/usr/bin/sed -n 's/^EARLY_ACCESS_SERVICE_URL=//p' \
      "$PRIVATE_PRODUCTION_ENV" | /usr/bin/tail -n 1)"
  fi
  if [[ "${REMOTE_WEB_RELAY_URL:-}" != wss://?*/ws ]]; then
    print -u2 "REMOTE_WEB_RELAY_URL must be a production wss:// URL ending in /ws"
    exit 1
  fi
  if ! print -r -- "${EARLY_ACCESS_SERVICE_URL:-}" | rg -q '^https://[^/?#]+/?$'; then
    print -u2 "EARLY_ACCESS_SERVICE_URL must be a production root HTTPS URL"
    exit 1
  fi
fi
for command in codesign ditto security xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command"
    exit 1
  }
done
NOTARY_KEYCHAIN_ARGS=()
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
  test -f "$NOTARY_KEYCHAIN"
  NOTARY_KEYCHAIN_ARGS=(--keychain "$NOTARY_KEYCHAIN")
fi
if [[ "$RELEASE_MODE_REQUIRE_DEVELOPER_ID_SIGNING" == "1" ]]; then
  if ! security find-identity -v -p codesigning | rg -Fq "\"$CODE_SIGN_IDENTITY\""; then
    print -u2 "Developer ID Application identity is unavailable in the local keychain"
    exit 1
  fi
  if ! security find-identity -v -p basic | rg -Fq "\"$INSTALLER_SIGNING_IDENTITY\""; then
    print -u2 "Developer ID Installer identity is unavailable in the local keychain"
    exit 1
  fi
fi

WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-notarize-release.XXXXXX)"
APP_NOTARY_ZIP="$WORK_DIR/Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX-notarization.zip"
SPARKLE_ARCHIVES="$WORK_DIR/sparkle-archives"
ZH_NOTES_BASENAME="${ZH_RELEASE_NOTES:t}"
EN_NOTES_BASENAME="${EN_RELEASE_NOTES:t}"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-notarize-release.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected notarization work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

run_release_stage() {
  local stage="$1"
  local timeout_seconds="$2"
  shift 2
  if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" ]]; then
    "$RELEASE_STAGE_RUNNER" "$RELEASE_VARIANT" "$stage" "$timeout_seconds" -- "$@"
  else
    "$@"
  fi
}

notarize() {
  local stage="$1"
  local artifact="$2"
  if [[ "$RELEASE_MODE_REQUIRE_NOTARIZATION" != "1" ]]; then
    print "NOTARIZATION SKIPPED (ad-hoc mode): stage=$stage artifact=${artifact:t}"
    return 0
  fi
  run_release_stage "$stage" "$RELEASE_NOTARY_TIMEOUT_SECONDS" \
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" \
      "${NOTARY_KEYCHAIN_ARGS[@]}" \
      --wait
}

staple_and_validate() {
  local stage_prefix="$1"
  local artifact="$2"
  if [[ "$RELEASE_MODE_REQUIRE_NOTARIZATION" != "1" ]]; then
    print "STAPLE SKIPPED (ad-hoc mode): stage=$stage_prefix artifact=${artifact:t}"
    return 0
  fi
  run_release_stage "$stage_prefix-staple" "$RELEASE_STAPLE_TIMEOUT_SECONDS" \
    xcrun stapler staple "$artifact"
  run_release_stage "$stage_prefix-staple-validate" "$RELEASE_STAPLE_TIMEOUT_SECONDS" \
    xcrun stapler validate "$artifact"
}

start_notarize() {
  local stage="$1"
  local artifact="$2"
  if [[ "$RELEASE_STAGE_TIMEOUTS" == "1" ]]; then
    "$RELEASE_STAGE_RUNNER" "$RELEASE_VARIANT" "$stage" \
      "$RELEASE_NOTARY_TIMEOUT_SECONDS" -- \
      xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARY_PROFILE" \
        "${NOTARY_KEYCHAIN_ARGS[@]}" \
        --wait &
  else
    notarize "$stage" "$artifact" &
  fi
  REPLY=$!
}

process_finished() {
  local target_pid="$1"
  local process_state
  if ! /bin/kill -0 "$target_pid" 2>/dev/null; then
    return 0
  fi
  process_state="$(/bin/ps -o stat= -p "$target_pid" 2>/dev/null | /usr/bin/tr -d ' ' || true)"
  [[ -z "$process_state" || "$process_state" == Z* ]]
}

collect_parallel_descendants() {
  local parent_pid="$1"
  local child_pid
  while IFS= read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    collect_parallel_descendants "$child_pid"
    PARALLEL_DESCENDANT_PIDS+=("$child_pid")
  done < <(/usr/bin/pgrep -P "$parent_pid" 2>/dev/null || true)
}

stop_parallel_job() {
  local target_pid="$1"
  local stage="$2"
  local process_id
  local attempt
  print -u2 "RELEASE PARALLEL CANCEL lane=$RELEASE_VARIANT stage=$stage"
  typeset -ga PARALLEL_DESCENDANT_PIDS=()
  collect_parallel_descendants "$target_pid"
  for process_id in "${PARALLEL_DESCENDANT_PIDS[@]}" "$target_pid"; do
    /bin/kill -TERM "$process_id" 2>/dev/null || true
  done
  for attempt in {1..30}; do
    /bin/kill -0 "$target_pid" 2>/dev/null || break
    /bin/sleep 0.1
  done
  PARALLEL_DESCENDANT_PIDS=()
  collect_parallel_descendants "$target_pid"
  for process_id in "${PARALLEL_DESCENDANT_PIDS[@]}" "$target_pid"; do
    /bin/kill -KILL "$process_id" 2>/dev/null || true
  done
  wait "$target_pid" 2>/dev/null || true
}

extract_release_notes() {
  local source_file="$1"
  local destination_file="$2"
  # The Sparkle notes are plain text, so only the list items are kept. The
  # extraction itself is shared with the GitHub body instead of copied: the copy
  # that used to live here matched before it exited, so `1.8.25` pulled every
  # `1.8.25-fork.*` entry into one update note, and it also stopped at the
  # `## ⚠️ / 🎉 / ✨ / 🐛` sections inside a single entry.
  "$ROOT/scripts/extract-release-notes.sh" \
    "$VERSION" "$source_file" --bullets-only > "$destination_file"
  rg -q '^- ' "$destination_file"
}

export CODE_SIGN_IDENTITY
export INSTALLER_SIGNING_IDENTITY
export EXPECTED_DEVELOPER_TEAM_ID
export REQUIRE_DEVELOPER_ID_SIGNING="$RELEASE_MODE_REQUIRE_DEVELOPER_ID_SIGNING"
export REQUIRE_WEB_REMOTE_CONFIGURATION="$RELEASE_MODE_REQUIRE_PRIVATE_SERVICES"
export REQUIRE_EARLY_ACCESS_CONFIGURATION="$RELEASE_MODE_REQUIRE_PRIVATE_SERVICES"
export REQUIRE_SAYALL_AI_PACKAGE="$RELEASE_MODE_REQUIRE_PRIVATE_SERVICES"
export REQUIRE_SAYALL_MACRO_PLATFORM="$RELEASE_MODE_REQUIRE_PRIVATE_SERVICES"
export REMOTE_WEB_RELAY_URL
export EARLY_ACCESS_SERVICE_URL
export REQUIRE_NOTARIZATION=0
export REMOTE_MIC_BUILD_SCRATCH_PATH="$RELEASE_BUILD_SCRATCH_PATH"
export REMOTE_MIC_BUILD_CACHE_PATH="$RELEASE_BUILD_CACHE_PATH"
export RELEASE_STAGE_TIMEOUTS

run_release_stage app-build 240 "$ROOT/scripts/build-app.sh"
run_release_stage app-verify-pre-notary "$RELEASE_VERIFY_TIMEOUT_SECONDS" \
  "$ROOT/scripts/verify-app.sh" "$APP"
if [[ "$GENERATE_SPARKLE_UPDATE" == "1" ]]; then
  test -x "$GENERATE_APPCAST"
  test -x "$SIGN_UPDATE"
  # Checked before the first signature, because signing with the wrong key
  # produces a release every already-installed copy refuses, and
  # `sign_update --verify` cannot see it: it validates the signature against
  # whatever key just produced it, so any key passes.
  require_sparkle_signing_key_matches_app \
    "$APP_SPARKLE_PUBLIC_ED_KEY" "$GENERATE_KEYS" "$SPARKLE_PRIVATE_KEY_FILE"
fi

run_release_stage app-notary-archive 60 \
  /usr/bin/ditto -c -k --keepParent "$APP" "$APP_NOTARY_ZIP"
notarize app-notary "$APP_NOTARY_ZIP"
staple_and_validate app "$APP"
run_release_stage app-verify-notarized "$RELEASE_VERIFY_TIMEOUT_SECONDS" \
  env REQUIRE_NOTARIZATION="$RELEASE_MODE_REQUIRE_NOTARIZATION" \
  "$ROOT/scripts/verify-app.sh" "$APP"

run_release_stage driver-build 180 "$ROOT/scripts/build-doubao-driver.sh"
run_release_stage driver-package-build 180 "$ROOT/scripts/build-doubao-driver-pkg.sh"

if [[ "$PARALLEL_PACKAGE_NOTARIZATION" == "1" ]]; then
  start_notarize installer-pkg-notary "$INSTALL_PACKAGE"
  install_notary_pid="$REPLY"
  start_notarize uninstaller-pkg-notary "$UNINSTALL_PACKAGE"
  uninstall_notary_pid="$REPLY"
  install_notary_done=0
  uninstall_notary_done=0
  while (( install_notary_done == 0 || uninstall_notary_done == 0 )); do
    if (( install_notary_done == 0 )) && process_finished "$install_notary_pid"; then
      if wait "$install_notary_pid"; then install_notary_status=0; else install_notary_status=$?; fi
      install_notary_done=1
      if (( install_notary_status != 0 )); then
        (( uninstall_notary_done == 0 )) && \
          stop_parallel_job "$uninstall_notary_pid" uninstaller-pkg-notary
        print -u2 "parallel package notarization failed: installer exit=$install_notary_status"
        exit 1
      fi
    fi
    if (( uninstall_notary_done == 0 )) && process_finished "$uninstall_notary_pid"; then
      if wait "$uninstall_notary_pid"; then uninstall_notary_status=0; else uninstall_notary_status=$?; fi
      uninstall_notary_done=1
      if (( uninstall_notary_status != 0 )); then
        (( install_notary_done == 0 )) && \
          stop_parallel_job "$install_notary_pid" installer-pkg-notary
        print -u2 "parallel package notarization failed: uninstaller exit=$uninstall_notary_status"
        exit 1
      fi
    fi
    (( install_notary_done != 0 && uninstall_notary_done != 0 )) || /bin/sleep 0.2
  done
else
  notarize installer-pkg-notary "$INSTALL_PACKAGE"
  notarize uninstaller-pkg-notary "$UNINSTALL_PACKAGE"
fi

staple_and_validate installer-pkg "$INSTALL_PACKAGE"
run_release_stage installer-pkg-verify "$RELEASE_VERIFY_TIMEOUT_SECONDS" \
  env REQUIRE_NOTARIZATION="$RELEASE_MODE_REQUIRE_NOTARIZATION" \
  "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install

staple_and_validate uninstaller-pkg "$UNINSTALL_PACKAGE"
run_release_stage uninstaller-pkg-verify "$RELEASE_VERIFY_TIMEOUT_SECONDS" \
  env REQUIRE_NOTARIZATION="$RELEASE_MODE_REQUIRE_NOTARIZATION" \
  "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall

run_release_stage dmg-build 120 env BUILD_COMPONENTS=0 "$ROOT/scripts/build-dmg.sh"
notarize dmg-notary "$DMG"
staple_and_validate dmg "$DMG"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256"
)
run_release_stage dmg-verify "$RELEASE_VERIFY_TIMEOUT_SECONDS" \
  env REQUIRE_NOTARIZATION="$RELEASE_MODE_REQUIRE_NOTARIZATION" \
  "$ROOT/scripts/verify-dmg.sh" "$DMG"

if [[ "$GENERATE_SPARKLE_UPDATE" == "1" ]]; then
  case "$UPDATE_ZIP" in
    "$OUTPUT_DIR"/Remote-Mic-*.zip) ;;
    *) print -u2 "refusing to replace unexpected Sparkle archive: $UPDATE_ZIP"; exit 1 ;;
  esac
  case "$APPCAST" in
    "$OUTPUT_DIR"/appcast.xml|"$OUTPUT_DIR"/appcast-intel.xml) ;;
    *) print -u2 "refusing to replace unexpected appcast path: $APPCAST"; exit 1 ;;
  esac
  /bin/rm -f -- "$UPDATE_ZIP" "$APPCAST" "$ZH_RELEASE_NOTES" "$EN_RELEASE_NOTES"
  /usr/bin/ditto -c -k --keepParent "$APP" "$UPDATE_ZIP"
  /bin/mkdir -p "$SPARKLE_ARCHIVES"
  /usr/bin/ditto --norsrc --noqtn --noacl "$UPDATE_ZIP" "$SPARKLE_ARCHIVES/$ZIP_BASENAME"
  extract_release_notes \
    "$ROOT/Resources/zh-Hans.lproj/ReleaseHistory.md" \
    "$SPARKLE_ARCHIVES/$ZH_NOTES_BASENAME"
  extract_release_notes \
    "$ROOT/Resources/en.lproj/ReleaseHistory.md" \
    "$SPARKLE_ARCHIVES/$EN_NOTES_BASENAME"
  # Empty when the key lives in the login Keychain, which is where this fork's
  # key is. `--ed-key-file ""` is not the same as omitting the flag: Sparkle
  # would try to read a file named "" and fail.
  SPARKLE_KEY_ARGS=()
  if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    SPARKLE_KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
  fi
  "$GENERATE_APPCAST" \
    "${SPARKLE_KEY_ARGS[@]}" \
    --download-url-prefix "$CDN_DOWNLOAD_PREFIX" \
    --release-notes-url-prefix "$CDN_DOWNLOAD_PREFIX" \
    --link "$RELEASE_PAGE" \
    --versions "$BUILD" \
    --maximum-versions 1 \
    -o "$APPCAST" \
    "$SPARKLE_ARCHIVES"
  if [[ "$RELEASE_VARIANT" == "intel" ]]; then
    APPCAST_WITH_SHARED_NOTES="$WORK_DIR/appcast-intel-shared-notes.xml"
    /usr/bin/sed \
      -e "s#${ZH_NOTES_BASENAME}#${PUBLISHED_ZH_NOTES_BASENAME}#g" \
      -e "s#${EN_NOTES_BASENAME}#${PUBLISHED_EN_NOTES_BASENAME}#g" \
      "$APPCAST" > "$APPCAST_WITH_SHARED_NOTES"
    /bin/mv "$APPCAST_WITH_SHARED_NOTES" "$APPCAST"
  fi
  /usr/bin/ditto --norsrc --noqtn --noacl \
    "$SPARKLE_ARCHIVES/$ZH_NOTES_BASENAME" "$ZH_RELEASE_NOTES"
  /usr/bin/ditto --norsrc --noqtn --noacl \
    "$SPARKLE_ARCHIVES/$EN_NOTES_BASENAME" "$EN_RELEASE_NOTES"

  ENCLOSURE_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST" | head -n 1)"
  require_signed_appcast "$APPCAST" "${APPCAST:t}"
  rg -Fq "url=\"$CDN_DOWNLOAD_PREFIX$ZIP_BASENAME\"" "$APPCAST"
  rg -Fq "$CDN_DOWNLOAD_PREFIX$PUBLISHED_ZH_NOTES_BASENAME" "$APPCAST"
  rg -Fq "$CDN_DOWNLOAD_PREFIX$PUBLISHED_EN_NOTES_BASENAME" "$APPCAST"
  rg -Fq "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST"
  "$SIGN_UPDATE" --verify "${SPARKLE_KEY_ARGS[@]}" "$UPDATE_ZIP" "$ENCLOSURE_SIGNATURE"
  "$SIGN_UPDATE" "${SPARKLE_KEY_ARGS[@]}" "$APPCAST"
  "$SIGN_UPDATE" --verify "${SPARKLE_KEY_ARGS[@]}" "$APPCAST"
fi

if [[ "$RELEASE_MODE_REQUIRE_NOTARIZATION" == "1" ]]; then
  print "NOTARIZED RELEASE READY"
else
  print "AD-HOC RELEASE READY (NOT NOTARIZED)"
fi
print "RELEASE VARIANT: $RELEASE_VARIANT"
print "RELEASE TAG: $RELEASE_TAG"
print "DMG: $DMG"
print "SHA256: $DMG.sha256"
print "INSTALL PACKAGE: $INSTALL_PACKAGE"
print "UNINSTALL PACKAGE: $UNINSTALL_PACKAGE"
if [[ "$GENERATE_SPARKLE_UPDATE" == "1" ]]; then
  print "SPARKLE ZIP: $UPDATE_ZIP"
  print "APPCAST: $APPCAST"
  print "ZH RELEASE NOTES: $ZH_RELEASE_NOTES"
  print "EN RELEASE NOTES: $EN_RELEASE_NOTES"
else
  print "SPARKLE UPDATE: skipped for private test package"
fi
release_signing_mode_report
