#!/bin/zsh
set -euo pipefail

# Executable regression for the opt-in ad-hoc release mode.
#
# The point of the mode is that it waives three named families of checks and
# nothing else. A mode that waives everything would pass every source-level
# assertion just as happily, so this drives the real functions in
# scripts/release-signing-mode.sh against real inputs and requires them to
# REFUSE the bad ones. Every negative case below fails before the change that
# introduced the mode, because the function it exercises did not exist.
#
# Covered here:
#   - the mode gate itself: default, both valid values, an invalid value;
#   - the team-ID gate in both directions;
#   - the identity-shape gate in both directions;
#   - a real ad-hoc signed bundle passing, an unsigned bundle failing, and a
#     tampered bundle failing (negative control on the signature);
#   - the appcast signature shape and the Sparkle key match, including the
#     upstream key that would break auto-update for every installed user
#     (negative control on the payload).
#
# Not covered here, and deliberately: refusing a real Developer ID signature.
# Producing one needs a paid Apple Developer certificate, which is the whole
# reason this mode exists. That branch is asserted at source level in
# Tests/RemoteMicTests/BuildSigningTests.swift instead.

ROOT="${0:A:h:h}"
FORK_PUBLIC_ED_KEY="+EyNzAtTgwbJ4/04/ujn/JrpA0NKLFQSOd9w3Pg80M8="
UPSTREAM_PUBLIC_ED_KEY="8dWQovCnGPucjMcQuCHfrAv4PtjuDjJSbHNmItqYiyc="
VALID_SHAPED_SIGNATURE="$(/usr/bin/head -c 64 /dev/zero | /usr/bin/base64)"
WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remote-mic-adhoc-mode-test.XXXXXX)"
PROBE="$WORK_DIR/probe.zsh"
TEST_APP="$WORK_DIR/AdHocProbe.app"
FAILURES=0

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remote-mic-adhoc-mode-test.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected test path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi

# A separate process per case, so a refusal is an exit status instead of a
# `return` that would take this harness down with it.
/bin/cat > "$PROBE" <<'PROBE_SCRIPT'
#!/bin/zsh
set -euo pipefail
source "$ROOT/scripts/release-signing-mode.sh"
eval "$1"
PROBE_SCRIPT

probe() {
  local mode="$1" snippet="$2"
  RELEASE_SIGNING_MODE="$mode" ROOT="$ROOT" \
    /bin/zsh "$PROBE" "$snippet" >/dev/null 2>&1
}

expect_pass() {
  local label="$1" mode="$2" snippet="$3"
  if probe "$mode" "$snippet"; then
    print "PASS (accepted): $label"
  else
    print -u2 "FAIL: $label was refused but should have been accepted"
    FAILURES=$(( FAILURES + 1 ))
  fi
}

expect_refusal() {
  local label="$1" mode="$2" snippet="$3"
  if probe "$mode" "$snippet"; then
    print -u2 "FAIL: $label was accepted but should have been refused"
    FAILURES=$(( FAILURES + 1 ))
  else
    print "PASS (refused): $label"
  fi
}

print "== mode gate =="
expect_pass "default mode is developer-id with both Apple checks required" "" \
  '[[ "$RELEASE_SIGNING_MODE" == "developer-id" ]] &&
   [[ "$RELEASE_MODE_REQUIRE_DEVELOPER_ID_SIGNING" == "1" ]] &&
   [[ "$RELEASE_MODE_REQUIRE_NOTARIZATION" == "1" ]] &&
   [[ "$RELEASE_MODE_DEFAULT_DEVELOPER_TEAM_ID" == "L3QHLDRPAY" ]]'
expect_pass "adhoc waives Developer ID and notarization and nothing is defaulted to a team" adhoc \
  '[[ "$RELEASE_MODE_REQUIRE_DEVELOPER_ID_SIGNING" == "0" ]] &&
   [[ "$RELEASE_MODE_REQUIRE_NOTARIZATION" == "0" ]] &&
   [[ -z "$RELEASE_MODE_DEFAULT_DEVELOPER_TEAM_ID" ]] &&
   [[ "$RELEASE_MODE_DEFAULT_SIGNING_IDENTITY" == "-" ]]'
expect_refusal "an unknown signing mode" nonsense 'print ok'
expect_refusal "an empty-but-set signing mode" " " 'print ok'
expect_pass "adhoc names every waiver in its report" adhoc \
  'report="$(release_signing_mode_report)"
   for required in "NOT PROVEN: a Developer ID Application authority" \
     "NOT PROVEN: Apple notarization" \
     "NOT PROVEN: any Apple Developer Team identity" \
     "USERS MUST right-click -> Open once" \
     "STILL PROVES"; do
     print -r -- "$report" | /usr/bin/grep -Fq -- "$required" || exit 1
   done'

print "== Apple Developer Team gate =="
expect_pass "developer-id accepts the expected team" "" \
  'require_release_developer_team L3QHLDRPAY'
expect_refusal "developer-id with a different team" "" \
  'require_release_developer_team SOMEOTHER'
expect_refusal "developer-id with no team at all" "" \
  'require_release_developer_team ""'
expect_pass "adhoc with no team" adhoc \
  'require_release_developer_team ""'
expect_refusal "adhoc that still names a team (mode mismatch)" adhoc \
  'require_release_developer_team L3QHLDRPAY'

print "== signing identity gate =="
expect_pass "developer-id accepts Developer ID identities" "" \
  'require_release_signing_identity "Developer ID Application: Someone (L3QHLDRPAY)" \
     "Developer ID Installer: Someone (L3QHLDRPAY)"'
expect_refusal "developer-id with the ad-hoc identity" "" \
  'require_release_signing_identity - -'
expect_pass "adhoc accepts the ad-hoc identity" adhoc \
  'require_release_signing_identity - -'
expect_refusal "adhoc that still names a Developer ID identity" adhoc \
  'require_release_signing_identity "Developer ID Application: Someone (L3QHLDRPAY)" \
     "Developer ID Installer: Someone (L3QHLDRPAY)"'

print "== signature negative control (real bundle) =="
/bin/mkdir -p "$TEST_APP/Contents/MacOS"
# A real, already-valid Mach-O, so codesign has something it will actually seal.
/bin/cp /bin/echo "$TEST_APP/Contents/MacOS/AdHocProbe"
/bin/chmod 0755 "$TEST_APP/Contents/MacOS/AdHocProbe"
/bin/cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AdHocProbe</string>
    <key>CFBundleIdentifier</key>
    <string>com.hd838a.RemoteMic.adhocprobe</string>
    <key>CFBundleName</key>
    <string>AdHocProbe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$TEST_APP/Contents/Info.plist" >/dev/null

codesign --force --timestamp=none --sign - "$TEST_APP" 2>/dev/null
expect_pass "a genuinely ad-hoc signed bundle" adhoc \
  "require_adhoc_code_signature '$TEST_APP' 'ad-hoc probe'"

codesign --remove-signature "$TEST_APP" 2>/dev/null
expect_refusal "an unsigned bundle" adhoc \
  "require_adhoc_code_signature '$TEST_APP' 'unsigned probe'"

# Re-sign, then break the seal. This is the case that matters: the bundle IS
# signed, so a check that only asked "is there a signature?" would pass it.
codesign --force --timestamp=none --sign - "$TEST_APP" 2>/dev/null
print -n 'tamper' >> "$TEST_APP/Contents/MacOS/AdHocProbe"
expect_refusal "a signed bundle whose executable was modified after signing" adhoc \
  "require_adhoc_code_signature '$TEST_APP' 'tampered probe'"

print "== appcast payload negative control =="
print_appcast() {
  local destination="$1" signature="$2"
  /bin/cat > "$destination" <<APPCAST
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>123</sparkle:version>
      <enclosure url="https://example.invalid/Remote-Mic.zip" sparkle:edSignature="$signature" length="1"/>
    </item>
  </channel>
</rss>
APPCAST
}

print_appcast "$WORK_DIR/appcast-good.xml" "$VALID_SHAPED_SIGNATURE"
print_appcast "$WORK_DIR/appcast-empty.xml" ""
print_appcast "$WORK_DIR/appcast-truncated.xml" "${VALID_SHAPED_SIGNATURE:0:40}"

expect_pass "an appcast carrying a well-formed enclosure signature" adhoc \
  "require_signed_appcast '$WORK_DIR/appcast-good.xml' good"
expect_refusal "an appcast whose enclosure signature is empty" adhoc \
  "require_signed_appcast '$WORK_DIR/appcast-empty.xml' empty"
expect_refusal "an appcast whose enclosure signature is truncated" adhoc \
  "require_signed_appcast '$WORK_DIR/appcast-truncated.xml' truncated"
expect_refusal "a missing appcast" adhoc \
  "require_signed_appcast '$WORK_DIR/appcast-absent.xml' absent"

print "== Sparkle key negative control =="
expect_pass "a signing key whose public half is the key the app ships" adhoc \
  "SPARKLE_PUBLIC_ED_KEY='$FORK_PUBLIC_ED_KEY' \
   require_sparkle_signing_key_matches_app '$FORK_PUBLIC_ED_KEY' '' ''"
expect_refusal "a signing key that is not the key the app ships" adhoc \
  "SPARKLE_PUBLIC_ED_KEY='$UPSTREAM_PUBLIC_ED_KEY' \
   require_sparkle_signing_key_matches_app '$FORK_PUBLIC_ED_KEY' '' ''"
expect_refusal "an app still shipping upstream's key, whose private half is unavailable" adhoc \
  "SPARKLE_PUBLIC_ED_KEY='$UPSTREAM_PUBLIC_ED_KEY' \
   require_sparkle_signing_key_matches_app '$UPSTREAM_PUBLIC_ED_KEY' '' ''"
expect_refusal "an app shipping no Sparkle public key" adhoc \
  "SPARKLE_PUBLIC_ED_KEY='$FORK_PUBLIC_ED_KEY' \
   require_sparkle_signing_key_matches_app '' '' ''"
expect_refusal "no way to determine the signing key's public half" adhoc \
  "require_sparkle_signing_key_matches_app '$FORK_PUBLIC_ED_KEY' \
     '$WORK_DIR/absent-generate-keys' ''"

# A legacy Sparkle key file is base64 of seed||public, so the public half is
# readable from the file and must be compared, not trusted.
/usr/bin/head -c 32 /dev/zero > "$WORK_DIR/seed.bin"
/usr/bin/printf '%s' "$FORK_PUBLIC_ED_KEY" | /usr/bin/base64 -d > "$WORK_DIR/pub.bin"
/bin/cat "$WORK_DIR/seed.bin" "$WORK_DIR/pub.bin" | /usr/bin/base64 > "$WORK_DIR/matching.key"
/bin/cat "$WORK_DIR/seed.bin" "$WORK_DIR/seed.bin" | /usr/bin/base64 > "$WORK_DIR/mismatching.key"
expect_pass "a legacy key file whose embedded public half matches the app" adhoc \
  "require_sparkle_signing_key_matches_app '$FORK_PUBLIC_ED_KEY' '' '$WORK_DIR/matching.key'"
expect_refusal "a legacy key file whose embedded public half does not match the app" adhoc \
  "require_sparkle_signing_key_matches_app '$FORK_PUBLIC_ED_KEY' '' '$WORK_DIR/mismatching.key'"

if (( FAILURES != 0 )); then
  print -u2 "ADHOC RELEASE MODE TEST FAILED: $FAILURES case(s)"
  exit 1
fi
print "ADHOC RELEASE MODE TEST PASS"
