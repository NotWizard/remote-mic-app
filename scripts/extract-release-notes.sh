#!/bin/zsh
set -euo pipefail

# Prints the release-history entry for exactly one version.
#
# The exit rule deliberately comes BEFORE the match rule. With the match first,
# a heading that merely shares the requested version as a prefix re-triggers the
# match and its `next` skips the exit, so `1.8.25` used to swallow the
# `1.8.25-fork.4`, `1.8.25-fork.3`, `1.8.25-fork.2` and `1.8.25` entries into one
# release body. Versions are prefixes of each other in practice, so ordering here
# is load-bearing.
#
# One entry is itself split into the fixed `## ⚠️ / ## 🎉 / ## ✨ / ## 🐛`
# sections of Release_Notes_Guidelines.md. Those headings belong INSIDE an entry,
# so they must not end it. Every other `## ` heading still does: an unrecognised
# heading truncating one entry is a visible loss, while treating it as inner
# structure would merge two releases into one body again — the worse failure, and
# the one this script exists to prevent.
#
# `--bullets-only` keeps just the list items, for the plain-text Sparkle notes
# that render no headings.

if [[ $# -lt 2 || $# -gt 3 ]]; then
  print -u2 "usage: extract-release-notes.sh <version> <release-history.md> [--bullets-only]"
  exit 2
fi

VERSION="$1"
HISTORY="$2"
MODE="${3:-}"
BULLETS_ONLY=0

case "$MODE" in
  "") ;;
  --bullets-only) BULLETS_ONLY=1 ;;
  *) print -u2 "extract-release-notes.sh: unknown option: $MODE"; exit 2 ;;
esac

test -f "$HISTORY"

/usr/bin/awk -v version="$VERSION" -v bullets_only="$BULLETS_ONLY" '
  function is_section_heading(line) {
    return index(line, "## ⚠") == 1 ||
      index(line, "## 🎉") == 1 ||
      index(line, "## ✨") == 1 ||
      index(line, "## 🐛") == 1
  }
  active && /^## / && !is_section_heading($0) { exit }
  index($0, "## " version) == 1 { active = 1; next }
  active && bullets_only == 1 && !/^- / { next }
  active { print }
' "$HISTORY"
