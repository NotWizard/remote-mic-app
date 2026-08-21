## Release notes guidelines

These rules govern user-facing release notes (e.g. GitHub Release body), not the internal `CHANGELOG.md`. The changelog tracks what changed in the repo; release notes tell users what they get.

**Core principle**: write for the people USING this release, not for the people who BUILT it. Every entry should let a user answer "what do I get out of this?"

### Structure

```
# vX.Y.Z: three keywords that point at this release's focus
(optional) one-line opener

## 🎉 New features      — what you can now do
## ✨ Improvements       — same task, now smoother / faster / better-looking
## 🐛 Bug fixes          — what was broken, now fixed
## ⚠️ Heads-up           — behavior changed, or you need to do something (only when present, pinned to the top)
```

When publishing to a GitHub Release, the first-line `# vX.Y.Z: ...` becomes the release **name** (`gh release create --title ...` or `gh release edit --title ...`); the release **body** should NOT repeat that H1, otherwise the page renders the title twice (once in the release header, once at the top of the body). Body starts directly with the optional one-line opener or the first `## ⚠️ Heads-up` / `## 🎉 New features` section.

### Writing rules

0. **Write release notes bilingually.** Put the full Chinese version first, then the full English version. Do not alternate languages line by line.
1. **Write from the user's perspective, not the developer's.** Neutral phrasing ("Adds XX", "Now supports XX") or second-person ("You can now XX") are both fine — pick per product tone. AVOID "We + verb": it shifts the focus from what the user perceives to what the team did.
   - ❌ "We rewrote search"
   - ✅ "Search now matches Chinese synonyms"
2. **Describe the OUTCOME, not the work.**
   - ✅ "100k-row reports open in under 1 second"
   - ❌ "Optimized rendering performance"
3. **Bug fixes must name the scenario.**
   - ✅ "Fixed occasional failure when exporting Excel files over 1000 rows"
   - ❌ "Fixed export bug"
4. **The title states this release's focus**, not "vX.Y.Z released".
5. **Zero code, zero jargon.** Component names / tech stack / PR numbers belong in the PR description, not in user-facing notes.

### Breaking-change three-layer rule

Any change that will annoy users or require them to take action MUST include all three layers:

- **Why it changed** — a reason a user can understand, not a technical one.
- **What the new rule is** — specific: where to click, what to see.
- **What you should do** — the clear next step.

For things users hand-write (config keys, URLs, command flags), provide a `before → after` comparison. This is the ONLY place "code snippets" are allowed in user-facing notes.

### Forbidden

- ❌ Empty marketing words: "revolutionary", "all-new", "ultimate".
- ❌ Listing every commit. When there are more than 10 fixes, group them: "This release fixes N reported issues, [view full list]".
- ❌ Passive voice that dodges responsibility: "Some issues occurred and have been resolved".

### Length reference

- Patch: 50–150 words.
- Minor: 200–400 words.
- Major: 400–800 words plus a highlights section.

### Pre-publish checklist

- [ ] Chinese version first, then English version?
- [ ] Written from the user's perspective (no "We + verb")?
- [ ] Every fix names a scenario?
- [ ] No jargon, no marketing fluff, no PR numbers?
- [ ] If there are breaking changes, all three layers present and pinned to the top?
- [ ] Version bump matches the content (a release with breaking changes is not a minor)?
