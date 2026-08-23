#!/bin/zsh
set -euo pipefail

# Prints the release-history entry for exactly one version.
#
# The version match is EXACT, not a prefix. A prefix test picked the earliest
# heading that merely started with the requested version, and in this repository
# versions are prefixes of each other: `## 1.8.25-fork.4`, `## 1.8.25-fork.3`,
# `## 1.8.25-fork.2` and `## 1.8.25` all coexist, newest first. So `1.8.25`
# returned fork.4's entry — the right notes only as long as fork.4 happened to be
# the release being published — and `1.8.2` returned fork.4's entry too, while the
# real `## 1.8.25（预发布）` and `## 1.8.2（预发布）` entries could not be reached at
# all. Nothing downstream notices: the notes are a plausible, bullet-bearing
# release body for the wrong release.
#
# A heading's version is therefore compared byte for byte after removing one
# trailing parenthesised label, which is the only decoration the two shipping
# files put after a version number: `（本分支）` and `（预发布）` in
# Resources/zh-Hans.lproj/ReleaseHistory.md, ` (this fork)` and ` (Pre-release)`
# in Resources/en.lproj/ReleaseHistory.md, while 17 of the 52 entries per language
# carry no label at all. Both bracket pairs are listed because both are in use;
# anything else after the version number is not a heading for that version.
#
# The exit rule still comes BEFORE the match rule. Exact matching alone would
# already stop a prefix-sharing heading from re-activating, but a *duplicate*
# heading for the requested version would, and then its `next` would skip the
# exit and merge everything up to the following version into one body.
#
# `--newest-version` prints the bare version of the file's first `## ` heading,
# i.e. the release the file describes as newest. publish-release.sh uses it to
# refuse a release whose tag and version do not name the entry being shipped, and
# it lives here so that the rule for "what version does this heading name" has
# exactly one implementation.
#
# One entry is itself split into the fixed `## ⚠️ / ## 🎉 / ## ✨ / ## 🐛`
# sections of Release_Notes_Guidelines.md. Those headings belong INSIDE an entry,
# so they must not end it. Every other `## ` heading still ends it: that is the
# version boundary this script exists to keep.
#
# So a `## ` heading met inside an entry gets one of three verdicts:
#
#   1. equal to one of the eight mandated section headings — inner structure, kept;
#   2. leading with a mandated section emoji but not equal to any of the eight —
#      refused, non-zero exit, naming the heading and the file;
#   3. anything else — the next version, so the entry ends here.
#
# Verdict 2 is what this script learned the hard way. Guessing either way loses
# user-facing text with no error anywhere:
#
#   - guessing "section" merges the next release into this body, which is how
#     `## 🎉 9.9.8 emoji-prefixed version` used to pull the following entry's
#     bullets into one set of notes;
#   - guessing "version" drops a real section. The predecessor of this rule was
#     "a digit anywhere means version", and under it `## 🐛 问题修复（第 2 批）`
#     ended the entry after the heads-up section, so two shipped fixes vanished
#     from both the GitHub body and the Sparkle notes.
#
# Neither loss is caught downstream: the `^- ` gates in publish-release.sh and
# notarize-release.sh only fire when an entry ends up with no bullet at all, and
# one surviving heads-up bullet satisfies both. A heading that wears a section
# emoji without being a section is a typo in a release note, so the release stops
# and a human fixes the heading instead of the tooling picking a silent loser.
#
# The eight strings are copied, not invented. `## ⚠️ 注意事项`, `## ✨ 改进`,
# `## 🐛 问题修复`, `## ⚠️ Heads-up`, `## ✨ Improvements` and `## 🐛 Bug fixes`
# are byte-for-byte the headings in Resources/{zh-Hans,en}.lproj/ReleaseHistory.md;
# the two `## 🎉` headings come from Release_Notes_Guidelines.md and AGENTS.md,
# because no shipped entry has needed a new-features section yet. The ⚠️ ones
# carry U+FE0F: a bare `⚠` is verdict 2, not verdict 1.
#
# Only trailing blanks are ignored when comparing, because Markdown renders a
# heading the same with or without them and a CRLF checkout adds one. Everything
# else — a second space after `##`, a missing space after the emoji, different
# capitalisation, extra words — is verdict 2 on purpose: those are the near
# misses that a prefix test used to wave through.
#
# `--bullets-only` keeps just the list items, for the plain-text Sparkle notes
# that render no headings.

usage() {
  print -u2 "usage: extract-release-notes.sh <version> <release-history.md> [--bullets-only]"
  print -u2 "       extract-release-notes.sh --newest-version <release-history.md>"
  exit 2
}

VERSION=""
HISTORY=""
BULLETS_ONLY=0
NEWEST_ONLY=0

if [[ $# -ge 1 && "$1" == "--newest-version" ]]; then
  [[ $# -eq 2 ]] || usage
  NEWEST_ONLY=1
  HISTORY="$2"
else
  [[ $# -ge 2 && $# -le 3 ]] || usage
  VERSION="$1"
  HISTORY="$2"
  case "${3:-}" in
    "") ;;
    --bullets-only) BULLETS_ONLY=1 ;;
    *) print -u2 "extract-release-notes.sh: unknown option: $3"; exit 2 ;;
  esac
fi

test -f "$HISTORY"

# LC_ALL=C is load-bearing, and so is not comparing headings with `==`.
# /usr/bin/awk (one-true-awk 20200816) compares strings through the locale's
# collation table, and under en_US.UTF-8 two headings built from characters the
# table does not cover collate EQUAL: `"## 🎉 版本九点九点八" == "## 🐛 问题修复"`
# is true there. That turns the allow-list below into "anything unusual is a
# section", i.e. straight back to merging two releases. C collation compares
# bytes, and `same()` compares bytes whatever the locale, so dropping one of the
# two does not silently reopen the hole.
LC_ALL=C /usr/bin/awk \
  -v version="$VERSION" \
  -v bullets_only="$BULLETS_ONLY" \
  -v newest_only="$NEWEST_ONLY" '
  BEGIN {
    sections = "## ⚠️ 注意事项\n## 🎉 新功能\n## ✨ 改进\n## 🐛 问题修复"
    sections = sections "\n## ⚠️ Heads-up\n## 🎉 New features"
    sections = sections "\n## ✨ Improvements\n## 🐛 Bug fixes"
    section_count = split(sections, section, "\n")
    emoji_count = split("⚠\n🎉\n✨\n🐛", emoji, "\n")
    # The only decoration allowed after a version number, copied from the two
    # shipping files: a fullwidth-parenthesised label in Chinese and an
    # ASCII-parenthesised one in English.
    label_count = split("（\n(", label_open, "\n")
    split("）\n)", label_close, "\n")
  }
  function same(left, right) {
    return length(left) == length(right) && index(left, right) == 1
  }
  # Bracket expressions are deliberately not used to find the label: under
  # LC_ALL=C `[^（）]` is a set of the four bytes those two characters are made
  # of, and `分` (E5 88 86) contains one of them, so the class never matches a
  # CJK label at all and the label stays attached, leaving the version
  # unresolvable. index() and substr() compare and slice bytes, which is what
  # every other comparison in this script does too. Every trailing label is
  # stripped, not just the last one.
  function without_label(text,   pair, starts, ends, ends_length, start_position) {
    for (pair = 1; pair <= label_count; pair++) {
      starts = label_open[pair]
      ends = label_close[pair]
      ends_length = length(ends)
      if (length(text) <= ends_length) continue
      if (!same(substr(text, length(text) - ends_length + 1), ends)) continue
      start_position = index(text, starts)
      if (start_position <= 1) continue
      text = substr(text, 1, start_position - 1)
      sub(/[ \t]+$/, "", text)
      return text
    }
    return text
  }
  function heading_version(line,   text) {
    text = line
    sub(/^##[ \t]+/, "", text)
    sub(/[ \t\r]+$/, "", text)
    return without_label(text)
  }
  function heading_verdict(line,   position, text) {
    sub(/[ \t\r]+$/, "", line)
    for (position = 1; position <= section_count; position++)
      if (same(line, section[position])) return "section"
    text = line
    sub(/^##[ \t]+/, "", text)
    for (position = 1; position <= emoji_count; position++)
      if (index(text, emoji[position]) == 1) return "ambiguous"
    return "version"
  }
  newest_only == 1 && /^## / { print heading_version($0); exit }
  active && /^## / {
    verdict = heading_verdict($0)
    if (verdict == "ambiguous") {
      refusal = "extract-release-notes.sh: ambiguous heading inside the " version
      refusal = refusal " entry of " FILENAME ": " $0
      print refusal > "/dev/stderr"
      hint = "extract-release-notes.sh: it leads with a section emoji but is not"
      hint = hint " one of the sections of Release_Notes_Guidelines.md; write that"
      hint = hint " section heading exactly, or a version heading with no section emoji"
      print hint > "/dev/stderr"
      exit 3
    }
    if (verdict == "version") exit
  }
  !active && /^## / && same(heading_version($0), version) { active = 1; next }
  active && bullets_only == 1 && !/^- / { next }
  active { print }
' "$HISTORY"
