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

# LC_ALL=C is load-bearing, and so is not comparing headings with `==`.
# /usr/bin/awk (one-true-awk 20200816) compares strings through the locale's
# collation table, and under en_US.UTF-8 two headings built from characters the
# table does not cover collate EQUAL: `"## 🎉 版本九点九点八" == "## 🐛 问题修复"`
# is true there. That turns the allow-list below into "anything unusual is a
# section", i.e. straight back to merging two releases. C collation compares
# bytes, and `same()` compares bytes whatever the locale, so dropping one of the
# two does not silently reopen the hole.
LC_ALL=C /usr/bin/awk -v version="$VERSION" -v bullets_only="$BULLETS_ONLY" '
  BEGIN {
    sections = "## ⚠️ 注意事项\n## 🎉 新功能\n## ✨ 改进\n## 🐛 问题修复"
    sections = sections "\n## ⚠️ Heads-up\n## 🎉 New features"
    sections = sections "\n## ✨ Improvements\n## 🐛 Bug fixes"
    section_count = split(sections, section, "\n")
    emoji_count = split("⚠\n🎉\n✨\n🐛", emoji, "\n")
  }
  function same(left, right) {
    return length(left) == length(right) && index(left, right) == 1
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
  index($0, "## " version) == 1 { active = 1; next }
  active && bullets_only == 1 && !/^- / { next }
  active { print }
' "$HISTORY"
