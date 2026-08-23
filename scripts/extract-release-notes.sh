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

if [[ $# -ne 2 ]]; then
  print -u2 "usage: extract-release-notes.sh <version> <release-history.md>"
  exit 2
fi

VERSION="$1"
HISTORY="$2"

test -f "$HISTORY"

/usr/bin/awk -v version="$VERSION" '
  active && /^## / { exit }
  index($0, "## " version) == 1 { active = 1; next }
  active { print }
' "$HISTORY"
