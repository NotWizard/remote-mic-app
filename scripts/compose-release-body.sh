#!/bin/zsh
set -euo pipefail

# Prints the GitHub release body for one version: the full Chinese text first,
# then the full English text, as Release_Notes_Guidelines.md requires.
#
# Shipping one language because the other was never written is a silent failure,
# so a missing or bullet-less entry in either language is an error rather than a
# half-translated release body.

if [[ $# -ne 3 ]]; then
  print -u2 "usage: compose-release-body.sh <version> <zh-history> <en-history>"
  exit 2
fi

VERSION="$1"
ZH_HISTORY="$2"
EN_HISTORY="$3"
HERE="${0:A:h}"

zh_body="$("$HERE/extract-release-notes.sh" "$VERSION" "$ZH_HISTORY")"
en_body="$("$HERE/extract-release-notes.sh" "$VERSION" "$EN_HISTORY")"

if ! print -r -- "$zh_body" | /usr/bin/grep -q '^- '; then
  print -u2 "release notes: no Chinese entry with bullets for $VERSION"
  exit 1
fi
if ! print -r -- "$en_body" | /usr/bin/grep -q '^- '; then
  print -u2 "release notes: no English entry with bullets for $VERSION"
  exit 1
fi

print "## 更新内容"
print
print -r -- "$zh_body"
print -r -- "---"
print
print "## What's New"
print
print -r -- "$en_body"
