#!/bin/zsh

# Sourced by every release script that has to know which signing story the
# release in front of it can actually prove.
#
# Two modes, always explicit, never inferred from which certificates happen to
# be installed:
#
#   developer-id (the default)
#     A paid Apple Developer account signs the app, both PKGs and the DMG with
#     Developer ID identities, Apple notarizes and staples them, and Gatekeeper
#     opens the app on a plain double-click. This is the only mode that may
#     claim any of that.
#
#   adhoc
#     There is no paid Apple Developer account. The app carries an ad-hoc
#     signature, nothing is notarized, and the first launch needs a
#     right-click -> Open. Choosing this mode is a decision about what the
#     release can promise, so it is opt-in: the default stays developer-id and
#     nothing loosens unless RELEASE_SIGNING_MODE=adhoc is set on purpose.
#
# adhoc waives EXACTLY three families of checks:
#
#   1. the Developer ID authority, team identifier and Hardened Runtime
#      assertions on the app, its Sparkle components, the PKGs and the DMG;
#   2. Apple notarization, `stapler validate` and `spctl` acceptance;
#   3. the upstream Apple Developer Team equality gate.
#
# Plus, in this repository only, the production service and private-package
# markers, because the URLs and packages they require live in repositories this
# fork cannot read at all (`Apps/MobileWeb` is a path
# scripts/check-repository-boundaries.sh forbids from ever existing here).
#
# Everything else a release can still prove stays mandatory in adhoc mode, and
# adhoc adds assertions of its own so it cannot become the mode where nothing
# is checked:
#
#   - `codesign --verify --deep --strict` on the app, unchanged and unconditional;
#   - the signature must exist, be internally valid AND actually be ad-hoc;
#   - a Developer ID signature is REFUSED here, so adhoc can never be used to
#     publish a Developer ID build with the notarization checks skipped;
#   - the DMG stays drag-install and the driver payload stays free of any
#     /Applications path (both already unconditional in the verifiers);
#   - the Sparkle key that signs the appcast must be the key the shipped app
#     trusts, otherwise auto-update is broken for every installed user;
#   - version and build still have to agree everywhere.
#
# Whatever adhoc can no longer prove is printed, loudly, by
# release_signing_mode_report before any public byte exists.

if [[ -z "${ROOT:-}" ]]; then
  print -u2 "release-signing-mode.sh requires ROOT"
  return 1
fi

RELEASE_SIGNING_MODE="${RELEASE_SIGNING_MODE:-developer-id}"

# Upstream's team. This fork has no Apple Developer account and therefore no
# team of its own, which is why adhoc mode has no team to compare against
# rather than a different team to compare against.
RELEASE_UPSTREAM_DEVELOPER_TEAM_ID="L3QHLDRPAY"

# Upstream's Sparkle public key. Its private half is not available here, so an
# app shipping this key can never be updated by anything this fork signs. Named
# so it can be refused by value instead of being described in a comment.
RELEASE_UPSTREAM_SPARKLE_PUBLIC_ED_KEY="8dWQovCnGPucjMcQuCHfrAv4PtjuDjJSbHNmItqYiyc="

case "$RELEASE_SIGNING_MODE" in
  developer-id)
    RELEASE_MODE_REQUIRE_DEVELOPER_ID_SIGNING=1
    RELEASE_MODE_REQUIRE_NOTARIZATION=1
    RELEASE_MODE_REQUIRE_PRIVATE_SERVICES=1
    RELEASE_MODE_DEFAULT_DEVELOPER_TEAM_ID="$RELEASE_UPSTREAM_DEVELOPER_TEAM_ID"
    RELEASE_MODE_DEFAULT_SIGNING_IDENTITY=""
    ;;
  adhoc)
    RELEASE_MODE_REQUIRE_DEVELOPER_ID_SIGNING=0
    RELEASE_MODE_REQUIRE_NOTARIZATION=0
    RELEASE_MODE_REQUIRE_PRIVATE_SERVICES=0
    RELEASE_MODE_DEFAULT_DEVELOPER_TEAM_ID=""
    RELEASE_MODE_DEFAULT_SIGNING_IDENTITY="-"
    ;;
  *)
    print -u2 "RELEASE_SIGNING_MODE must be developer-id or adhoc"
    return 1
    ;;
esac

export RELEASE_SIGNING_MODE

# Printed before anything public is created, so the waiver is in the release log
# next to the artifacts it applies to rather than in a document nobody opens.
release_signing_mode_report() {
  print "RELEASE SIGNING MODE: $RELEASE_SIGNING_MODE"
  if [[ "$RELEASE_SIGNING_MODE" == "developer-id" ]]; then
    print "RELEASE SIGNING MODE PROVES: Developer ID signature, Hardened Runtime, Apple notarization, staple, Gatekeeper acceptance"
    return 0
  fi
  print "################################################################"
  print "AD-HOC RELEASE MODE: this run CANNOT prove any of the following"
  print "  - NOT PROVEN: a Developer ID Application authority on the app or its Sparkle components"
  print "  - NOT PROVEN: a Developer ID Installer authority on the uninstaller PKG"
  print "  - NOT PROVEN: Hardened Runtime (ad-hoc signing deliberately omits --options runtime)"
  print "  - NOT PROVEN: Apple notarization, a stapled ticket, or spctl acceptance"
  print "  - NOT PROVEN: a plain double-click opens the app; USERS MUST right-click -> Open once"
  print "  - NOT PROVEN: any Apple Developer Team identity, because this build has none"
  print "  - NOT PROVEN: the production relay/Early Access URLs or the private packages,"
  print "                which live in repositories this fork cannot read"
  print "AD-HOC RELEASE MODE STILL PROVES: codesign --verify --deep --strict,"
  print "  an internally valid ad-hoc signature, refusal of a Developer ID build,"
  print "  a drag-install DMG, a driver payload with zero /Applications entries,"
  print "  an appcast signed by the very Sparkle key the shipped app trusts,"
  print "  and version/build agreement across plist, appcast and release notes."
  print "################################################################"
}

# Replaces the four copies of `[[ "$TEAM" != "L3QHLDRPAY" ]] && exit 1`.
#
# developer-id keeps that behaviour byte for byte. adhoc refuses a team ID
# instead of ignoring one: naming a team while skipping notarization is a mode
# mismatch, and refusing it is what stops adhoc from being a shortcut for
# publishing a Developer ID build with the Apple-side checks turned off.
require_release_developer_team() {
  local team_id="${1:-}"
  if [[ "$RELEASE_SIGNING_MODE" == "developer-id" ]]; then
    if [[ "$team_id" != "$RELEASE_UPSTREAM_DEVELOPER_TEAM_ID" ]]; then
      print -u2 "refusing to release for an unexpected Apple Developer Team: ${team_id:-<unset>}"
      print -u2 "  expected: $RELEASE_UPSTREAM_DEVELOPER_TEAM_ID"
      print -u2 "  a fork without a paid Apple Developer account releases with RELEASE_SIGNING_MODE=adhoc instead"
      return 1
    fi
    return 0
  fi
  if [[ -n "$team_id" && "$team_id" != "-" ]]; then
    print -u2 "refusing to release: RELEASE_SIGNING_MODE=adhoc was given an Apple Developer Team ($team_id)"
    print -u2 "  ad-hoc builds have no team identifier, so a team here means the mode is wrong"
    print -u2 "  release a Developer ID build with RELEASE_SIGNING_MODE=developer-id so notarization is verified too"
    return 1
  fi
  return 0
}

# The signing identity has to agree with the mode for the same reason.
require_release_signing_identity() {
  local application_identity="${1:-}" installer_identity="${2:-}"
  if [[ "$RELEASE_SIGNING_MODE" == "developer-id" ]]; then
    if [[ "$application_identity" != "Developer ID Application: "* ]]; then
      print -u2 "CODE_SIGN_IDENTITY must name a Developer ID Application identity"
      return 1
    fi
    if [[ "$installer_identity" != "Developer ID Installer: "* ]]; then
      print -u2 "INSTALLER_SIGNING_IDENTITY must name a Developer ID Installer identity"
      return 1
    fi
    return 0
  fi
  if [[ "$application_identity" != "-" || "$installer_identity" != "-" ]]; then
    print -u2 "refusing to release: RELEASE_SIGNING_MODE=adhoc requires the ad-hoc identity '-'"
    print -u2 "  CODE_SIGN_IDENTITY: ${application_identity:-<unset>}"
    print -u2 "  INSTALLER_SIGNING_IDENTITY: ${installer_identity:-<unset>}"
    return 1
  fi
  return 0
}

# What adhoc asserts in place of the Developer ID authority checks.
#
# An unsigned bundle, a broken signature and a Developer ID signature are three
# different failures, so each gets its own refusal instead of one generic one.
require_adhoc_code_signature() {
  local target="${1:-}" label="${2:-${1:-}}" details signature_line
  if [[ -z "$target" ]]; then
    print -u2 "require_adhoc_code_signature needs a path"
    return 1
  fi
  if ! codesign --verify --strict "$target" >/dev/null 2>&1; then
    print -u2 "ad-hoc release mode requires a valid code signature: $label"
    print -u2 "  codesign --verify --strict failed, so the bundle is unsigned or its seal is broken"
    return 1
  fi
  if ! details="$(codesign -dvvv "$target" 2>&1)"; then
    print -u2 "ad-hoc release mode could not read the signature: $label"
    return 1
  fi
  if print -r -- "$details" | rg -q '^Authority=Developer ID Application:'; then
    print -u2 "ad-hoc release mode refuses a Developer ID signature: $label"
    print -u2 "  a Developer ID build must be released with RELEASE_SIGNING_MODE=developer-id"
    print -u2 "  so notarization, staple and Gatekeeper acceptance are verified as well"
    return 1
  fi
  if ! print -r -- "$details" | rg -q '^Signature=adhoc$'; then
    signature_line="$(print -r -- "$details" | rg '^Signature=' || print -- '<no Signature line>')"
    print -u2 "ad-hoc release mode requires an ad-hoc signature: $label"
    print -u2 "  codesign reported: $signature_line"
    return 1
  fi
  if ! print -r -- "$details" | rg -q '^CodeDirectory .*flags=0x2\(adhoc\)'; then
    print -u2 "ad-hoc release mode requires the ad-hoc code directory flag: $label"
    return 1
  fi
  if ! print -r -- "$details" | rg -q '^TeamIdentifier=not set$'; then
    print -u2 "ad-hoc release mode requires no team identifier: $label"
    return 1
  fi
  print "AD-HOC SIGNATURE PASS: $label"
  return 0
}

# Auto-update is the reason this exists.
#
# Sparkle only installs an update whose signature verifies against the
# SUPublicEDKey inside the app that is already installed. Signing an appcast
# with a key whose public half is not that value produces a release every
# existing user silently refuses, and `sign_update --verify` cannot catch it:
# it verifies the signature against whichever key just made it, so any key
# passes. This compares the signing key's public half with the key the shipped
# app trusts, which is the half `sign_update` cannot check.
require_sparkle_signing_key_matches_app() {
  local expected_public_key="${1:-}" generate_keys="${2:-}" private_key_file="${3:-}"
  local actual_public_key="" key_source="" decoded_length=""
  if [[ -z "$expected_public_key" ]]; then
    print -u2 "refusing to sign an appcast: the app ships no SUPublicEDKey"
    return 1
  fi
  if [[ "$expected_public_key" == "$RELEASE_UPSTREAM_SPARKLE_PUBLIC_ED_KEY" ]]; then
    print -u2 "refusing to sign an appcast: the app still ships upstream's Sparkle public key"
    print -u2 "  its private half is not available here, so nothing signed by this release would be accepted"
    return 1
  fi
  if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    actual_public_key="$SPARKLE_PUBLIC_ED_KEY"
    key_source="SPARKLE_PUBLIC_ED_KEY"
  elif [[ -n "$private_key_file" && -r "$private_key_file" ]]; then
    # Sparkle's legacy exported key file is base64 of seed||public, so the
    # public half is readable. The newer format exports the 32-byte seed alone,
    # and deriving a public key from a seed needs ed25519 scalar
    # multiplication, which no tool here provides. Say so instead of guessing.
    decoded_length="$(/usr/bin/base64 -d < "$private_key_file" 2>/dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
    if [[ "$decoded_length" == "64" ]]; then
      actual_public_key="$(/usr/bin/base64 -d < "$private_key_file" | /usr/bin/tail -c 32 | /usr/bin/base64)"
      key_source="SPARKLE_PRIVATE_KEY_FILE"
    fi
  fi
  if [[ -z "$actual_public_key" && -n "$generate_keys" && -x "$generate_keys" ]]; then
    actual_public_key="$("$generate_keys" -p 2>/dev/null || true)"
    key_source="generate_keys -p (Keychain)"
  fi
  if [[ -z "$actual_public_key" ]]; then
    print -u2 "refusing to sign an appcast: the Sparkle signing key's public half could not be determined"
    print -u2 "  set SPARKLE_PUBLIC_ED_KEY to the public key of the signing key, or make generate_keys available"
    print -u2 "  a 32-byte (seed-only) SPARKLE_PRIVATE_KEY_FILE cannot be checked here on its own"
    return 1
  fi
  if [[ "$actual_public_key" != "$expected_public_key" ]]; then
    print -u2 "refusing to sign an appcast with a key the app does not trust"
    print -u2 "  app SUPublicEDKey: $expected_public_key"
    print -u2 "  signing key public half: $actual_public_key (from $key_source)"
    print -u2 "  every installed copy would reject this update"
    return 1
  fi
  print "SPARKLE SIGNING KEY PASS: matches the app's SUPublicEDKey (from $key_source)"
  return 0
}

# An appcast with no enclosure signature installs nowhere, so an empty
# `sparkle:edSignature` is a broken release rather than an unsigned one.
require_signed_appcast() {
  local appcast="${1:-}" label="${2:-${1:-}}" signature
  if [[ ! -f "$appcast" ]]; then
    print -u2 "appcast is missing: $label"
    return 1
  fi
  signature="$(/usr/bin/sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$appcast" | /usr/bin/head -n 1)"
  if [[ -z "$signature" ]]; then
    print -u2 "appcast carries no Sparkle enclosure signature: $label"
    return 1
  fi
  # An ed25519 signature is 64 bytes, so its base64 form is exactly 86
  # characters followed by two pad characters. A truncated or re-wrapped
  # signature fails here rather than at the first user's update check.
  if [[ ! "$signature" =~ '^[A-Za-z0-9+/]{86}==$' ]]; then
    print -u2 "appcast Sparkle signature is not a base64 ed25519 signature: $label"
    return 1
  fi
  print "APPCAST SIGNATURE PASS: $label"
  return 0
}
