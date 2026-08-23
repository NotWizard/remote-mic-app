import Foundation
import Testing
@testable import RemoteMic

/// The release body is built by extracting one version's entry out of the release
/// history. Versions in this repository are prefixes of each other — `1.8.25`,
/// `1.8.25-fork.2`, `1.8.25-fork.3`, `1.8.25-fork.4` all coexist — and the app's
/// own version string is the bare `1.8.25`, so prefix handling is what decides
/// whether a release describes itself or four releases at once.
///
/// These tests drive the real `scripts/extract-release-notes.sh` with real bytes.
@Suite("Release notes extraction")
struct ReleaseNotesExtractionTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private struct ExtractionResult {
        var status: Int32
        var notes: String
        var errors: String
    }

    /// Runs the real script and reports everything it produced. The exit status is
    /// part of the contract now: an entry that cannot be delimited unambiguously
    /// must stop the release rather than print a plausible-looking subset.
    private func extractResult(
        version: String,
        from history: String,
        bulletsOnly: Bool = false,
        environment: [String: String]? = nil
    ) throws -> ExtractionResult {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReleaseNotesExtraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let historyURL = directory.appendingPathComponent("ReleaseHistory.md")
        try history.write(to: historyURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            repositoryRoot.appendingPathComponent("scripts/extract-release-notes.sh").path,
            version,
            historyURL.path,
        ] + (bulletsOnly ? ["--bullets-only"] : [])
        if let environment { process.environment = environment }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Both streams are a handful of lines here, so reading them in turn cannot
        // fill the other pipe's buffer.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ExtractionResult(
            status: process.terminationStatus,
            notes: String(decoding: outputData, as: UTF8.self),
            errors: String(decoding: errorData, as: UTF8.self)
        )
    }

    private func extract(
        version: String,
        from history: String,
        bulletsOnly: Bool = false
    ) throws -> String {
        let result = try extractResult(
            version: version,
            from: history,
            bulletsOnly: bulletsOnly
        )
        #expect(result.status == 0)
        #expect(result.errors.isEmpty)
        return result.notes
    }

    /// A history where later headings share the requested version as a prefix.
    private static let prefixSharingHistory = """
    # 版本历史

    ## 1.8.25-fork.4（本分支）

    - Newest entry only

    ## 1.8.25-fork.3（本分支）

    - Older fork entry

    ## 1.8.25-fork.2（本分支）

    - Even older fork entry

    ## 1.8.25（预发布）

    - Upstream entry

    """

    @Test func theBareVersionStopsAtTheNextHeadingInsteadOfSwallowingEveryForkEntry()
        throws
    {
        let notes = try extract(version: "1.8.25", from: Self.prefixSharingHistory)

        #expect(notes.contains("Newest entry only"))
        // Each of these used to land in the same release body, because a heading
        // sharing the prefix re-matched and skipped the stop rule.
        #expect(!notes.contains("Older fork entry"))
        #expect(!notes.contains("Even older fork entry"))
        #expect(!notes.contains("Upstream entry"))
        #expect(!notes.contains("## "))
    }

    @Test func anExactForkVersionExtractsOnlyItsOwnEntry() throws {
        let notes = try extract(
            version: "1.8.25-fork.3",
            from: Self.prefixSharingHistory
        )

        #expect(notes.contains("Older fork entry"))
        #expect(!notes.contains("Newest entry only"))
        #expect(!notes.contains("Even older fork entry"))
    }

    @Test func theLastEntryInTheFileIsStillExtracted() throws {
        let notes = try extract(version: "1.8.25（预发布）", from: Self.prefixSharingHistory)

        #expect(notes.contains("Upstream entry"))
        #expect(!notes.contains("Older fork entry"))
    }

    @Test func aVersionWithNoEntryYieldsNothingRatherThanSomebodyElsesNotes() throws {
        let notes = try extract(version: "9.9.9", from: Self.prefixSharingHistory)

        #expect(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// One entry is divided into the fixed sections of
    /// `Release_Notes_Guidelines.md`, so `## ` headings now appear both *inside*
    /// an entry and *between* entries. The `## ` line that ends an entry is only
    /// the next version.
    private static let sectionedHistory = """
    # 版本历史

    ## 1.9.0（本分支）

    ## ⚠️ 注意事项

    - Pinned heads-up bullet
    - Why it changed bullet

    ## 🎉 新功能

    - New feature bullet

    ## ✨ 改进

    - Improvement bullet

    ## 🐛 问题修复

    - Bug fix bullet

    ## 1.8.25-fork.4（本分支）

    - Previous release bullet

    """

    @Test func guidelineSectionHeadingsStayInsideTheEntryInsteadOfTruncatingIt()
        throws
    {
        let notes = try extract(version: "1.9.0", from: Self.sectionedHistory)

        // Truncation at the first section heading would leave the body empty,
        // which the `- ` gate in compose-release-body.sh cannot detect once any
        // one bullet survives, so every section is asserted individually.
        #expect(notes.contains("## ⚠️ 注意事项"))
        #expect(notes.contains("## 🎉 新功能"))
        #expect(notes.contains("## ✨ 改进"))
        #expect(notes.contains("## 🐛 问题修复"))
        #expect(notes.contains("- Pinned heads-up bullet"))
        #expect(notes.contains("- Why it changed bullet"))
        #expect(notes.contains("- New feature bullet"))
        #expect(notes.contains("- Improvement bullet"))
        #expect(notes.contains("- Bug fix bullet"))
        // The heads-up section is pinned to the top of the body.
        let headsUp = try #require(notes.range(of: "## ⚠️ 注意事项"))
        let fixes = try #require(notes.range(of: "## 🐛 问题修复"))
        #expect(headsUp.lowerBound < fixes.lowerBound)
        // Keeping inner headings must not cost the version boundary.
        #expect(!notes.contains("Previous release bullet"))
        #expect(!notes.contains("1.8.25-fork.4"))
    }

    /// Sections are an allow-list, not "any heading is inner structure": an
    /// unexpected heading still ends the entry, because one truncated entry is a
    /// visible loss while a swallowed boundary silently merges two releases.
    @Test func aHeadingThatIsNotAGuidelineSectionStillEndsTheEntry() throws {
        let history = """
        # 版本历史

        ## 1.9.0（本分支）

        - Own bullet

        ## Something else entirely

        - Foreign bullet

        """

        let notes = try extract(version: "1.9.0", from: history)

        #expect(notes.contains("- Own bullet"))
        #expect(!notes.contains("Foreign bullet"))
        #expect(!notes.contains("Something else entirely"))
    }

    /// A version entry with one candidate heading dropped into the middle of it,
    /// between a section that must survive and a bullet that must not be lost.
    private static func historyWithCandidateHeading(_ heading: String) -> String {
        """
        # 版本历史

        ## 9.9.9

        ## ⚠️ 注意事项

        - Current heads-up bullet

        \(heading)

        - Bullet after the candidate heading

        ## 9.9.7

        - Oldest bullet

        """
    }

    /// The verdicts a `## ` heading inside an entry can get. Only an exact match
    /// against the mandated headings is inner structure; a heading that merely
    /// leads with a section emoji is a refusal, not a guess; everything else is
    /// the next version, which is the boundary behaviour this script started with.
    private static let ambiguousHeadings = [
        // The review case: a section heading with a batch number appended. Under
        // the "a digit means version" rule this ended the entry, so this section
        // and both of its bullets disappeared from the GitHub body and the Sparkle
        // notes with every exit code still 0.
        "## 🐛 问题修复（第 2 批）",
        // A version heading wearing a section emoji. Under a leading-emoji test
        // this counted as inner structure and merged the next release in.
        "## 🎉 9.9.8 emoji-prefixed version",
        "## 🎉 v9.9.8 (this fork)",
        // The two the digit rule admitted it could not catch: no ASCII digit at
        // all, and fullwidth digits.
        "## 🎉 版本九点九点八",
        "## 🎉 ９.９.８ fullwidth digits",
        // Near misses of a real section: different case, no space after the emoji,
        // a bare ⚠ without U+FE0F, emoji with no text, two spaces after `##`.
        "## ⚠️ HEADS-UP",
        "## ⚠️Heads-up",
        "## ⚠ 注意事项",
        "## 🎉",
        "##  ⚠️ 注意事项",
    ]

    @Test func aHeadingWearingASectionEmojiWithoutBeingOneIsRefused() throws {
        for heading in Self.ambiguousHeadings {
            for bulletsOnly in [false, true] {
                let result = try extractResult(
                    version: "9.9.9",
                    from: Self.historyWithCandidateHeading(heading),
                    bulletsOnly: bulletsOnly
                )

                #expect(result.status != 0, "\(heading) bulletsOnly=\(bulletsOnly)")
                // The message has to let a human find the line, so it names the
                // heading and the file it came from.
                #expect(result.errors.contains(heading), "\(heading)")
                #expect(result.errors.contains("ReleaseHistory.md"), "\(heading)")
                // Neither wrong guess may leak: no merge of the next release …
                #expect(!result.notes.contains("Oldest bullet"), "\(heading)")
                // … and nothing past the ambiguous heading is presented as if it
                // belonged to this release either.
                #expect(
                    !result.notes.contains("Bullet after the candidate heading"),
                    "\(heading)"
                )
            }
        }
    }

    /// A truncated entry keeps the heads-up bullet, which satisfies the `^- `
    /// gates in publish-release.sh and notarize-release.sh, so the exit code is
    /// the only thing that can stop a release. This is the scenario the previous
    /// attempt shipped: exit 0, a body missing two fixes, both gates green.
    @Test func theRefusalStopsTheComposedBodyInsteadOfPublishingASubset() throws {
        let chinese = Self.historyWithCandidateHeading("## 🐛 问题修复（第 2 批）")
        let english = """
        # Version History

        ## 9.9.9

        ## ⚠️ Heads-up

        - Current heads-up bullet

        ## 🐛 Bug fixes

        - Bullet after the candidate heading

        ## 9.9.7

        - Oldest bullet

        """

        let truncatable = try extractResult(version: "9.9.9", from: chinese)
        // Truncation would have left a body that still passes a bullet-presence
        // gate — hence the refusal.
        #expect(truncatable.notes.contains("- Current heads-up bullet"))

        let result = try compose(version: "9.9.9", chinese: chinese, english: english)

        #expect(result.status != 0)
        #expect(result.body.isEmpty)
        #expect(!result.body.contains("Current heads-up bullet"))
    }

    /// `/usr/bin/awk` compares strings through the locale's collation table, and
    /// under en_US.UTF-8 two headings made of characters the table does not cover
    /// collate EQUAL — `## 🎉 版本九点九点八` matched `## 🐛 问题修复` and passed as a
    /// section. Not every locale gets this wrong, so the verdict is pinned under
    /// each of them: CI, Xcode and a terminal do not agree on the locale.
    @Test func theSectionMatchIsByBytesNotByLocaleCollation() throws {
        for locale in ["en_US.UTF-8", "zh_CN.UTF-8", "C"] {
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "LC_ALL")
            environment["LANG"] = locale

            let result = try extractResult(
                version: "9.9.9",
                from: Self.historyWithCandidateHeading("## 🎉 版本九点九点八"),
                environment: environment
            )

            #expect(result.status != 0, "\(locale)")
            #expect(
                !result.notes.contains("Bullet after the candidate heading"),
                "\(locale)"
            )
            #expect(!result.notes.contains("Oldest bullet"), "\(locale)")
        }
    }

    @Test func anExactMandatedSectionHeadingStaysInsideTheEntry() throws {
        // Trailing blanks are the one difference that does not change how Markdown
        // renders the heading, and a CRLF checkout adds one, so they are tolerated.
        let inner = Self.mandatedChineseSections + Self.mandatedEnglishSections
            + ["## ⚠️ 注意事项   "]

        for heading in inner {
            let notes = try extract(
                version: "9.9.9",
                from: Self.historyWithCandidateHeading(heading)
            )

            #expect(notes.contains("- Current heads-up bullet"), "\(heading)")
            #expect(notes.contains("- Bullet after the candidate heading"), "\(heading)")
            // Kept inside, but the version boundary still holds.
            #expect(!notes.contains("Oldest bullet"), "\(heading)")
            #expect(!notes.contains("9.9.7"), "\(heading)")
        }
    }

    @Test func aHeadingWithoutALeadingSectionEmojiStillEndsTheEntry() throws {
        for heading in [
            "## 9.9.8（本分支）",
            "## 9.9.8 (this fork)",
            "## 新功能",
            "## Something else entirely",
            // The emoji is in the heading but does not lead it, so it is a version
            // heading, exactly as it was before sections existed.
            "## 9.9.8 🎉 shipped",
        ] {
            let result = try extractResult(
                version: "9.9.9",
                from: Self.historyWithCandidateHeading(heading)
            )

            #expect(result.status == 0, "\(heading)")
            #expect(result.notes.contains("- Current heads-up bullet"), "\(heading)")
            #expect(
                !result.notes.contains("Bullet after the candidate heading"),
                "\(heading)"
            )
            #expect(!result.notes.contains("Oldest bullet"), "\(heading)")
        }
    }

    /// The shipping files must keep extracting whole: every `## ` heading inside
    /// the entry a release would ship has to be one of the eight headings the
    /// script accepts verbatim.
    ///
    /// This used to assert only that the character after `## ` was not a digit,
    /// which is a weaker rule than the script's and blind to this whole class:
    /// `## 🐛 问题修复（第 2 批）` and `## 🎉 版本九点九点八` both pass it while the script
    /// refuses them, so a shipping file drifting into either would fail the
    /// release rather than the test.
    @Test func everyShippingSectionHeadingIsStillTreatedAsInnerStructure() throws {
        let mandated = Set(Self.mandatedChineseSections + Self.mandatedEnglishSections)

        for locale in ["zh-Hans", "en"] {
            let history = try shippingHistory(locale: locale)
            let notes = try extract(
                version: try Self.topVersion(of: history),
                from: history
            )
            let sectionHeadings = Self.entryBody(of: history)
                .split(separator: "\n")
                .filter { $0.hasPrefix("## ") }

            #expect(!sectionHeadings.isEmpty)
            for heading in sectionHeadings {
                #expect(mandated.contains(String(heading)), "\(locale): \(heading)")
                #expect(notes.contains(heading), "\(locale): \(heading)")
            }
        }
    }

    /// The Sparkle update notes are plain text files that render no headings, so
    /// that path asks for the list items only — and it must still get every one
    /// of them, including the bullets that sit under a section heading.
    @Test func bulletsOnlyKeepsEveryListItemAndDropsSectionHeadings() throws {
        let notes = try extract(
            version: "1.9.0",
            from: Self.sectionedHistory,
            bulletsOnly: true
        )

        #expect(!notes.contains("## "))
        #expect(!notes.contains("注意事项"))
        let bullets = notes.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(bullets.count == 5)
        #expect(notes.contains("- Pinned heads-up bullet"))
        #expect(notes.contains("- Why it changed bullet"))
        #expect(notes.contains("- New feature bullet"))
        #expect(notes.contains("- Improvement bullet"))
        #expect(notes.contains("- Bug fix bullet"))
        #expect(!notes.contains("Previous release bullet"))
    }

    @Test func bulletsOnlyStillRefusesToCrossIntoTheNextVersion() throws {
        let notes = try extract(
            version: "1.8.25",
            from: Self.prefixSharingHistory,
            bulletsOnly: true
        )

        #expect(notes.contains("Newest entry only"))
        #expect(!notes.contains("Older fork entry"))
        #expect(!notes.contains("Even older fork entry"))
        #expect(!notes.contains("Upstream entry"))
    }

    /// The publish script requires at least one bullet in the generated notes, so
    /// the entry the next release will actually ship must satisfy that gate in
    /// both languages.
    @Test func theCurrentTopEntryExtractsBulletsInBothLanguages() throws {
        for locale in ["zh-Hans", "en"] {
            let history = try shippingHistory(locale: locale)
            let version = try Self.topVersion(of: history)
            let notes = try extract(version: version, from: history)

            #expect(notes.split(separator: "\n").contains { $0.hasPrefix("- ") })
            // `!notes.contains("## ")` used to stand for "no neighbouring version
            // leaked in", but an entry now legitimately contains the section
            // headings of Release_Notes_Guidelines.md. Comparing against the
            // file's own slice is the stronger statement: it fails on a leaked
            // neighbour *and* on an entry truncated at its first section.
            #expect(
                Self.withoutTrailingNewlines(notes)
                    == Self.withoutTrailingNewlines(Self.entryBody(of: history))
            )
            for line in notes.split(separator: "\n") where line.hasPrefix("## ") {
                // The script keeps a heading only when it matches one of the eight
                // mandated headings byte for byte, so that is what the shipping
                // notes must contain. "no digit right after `##`" used to stand in
                // here and accepts headings the script refuses outright.
                #expect(
                    Set(Self.mandatedChineseSections + Self.mandatedEnglishSections)
                        .contains(String(line)),
                    "\(locale): \(line)"
                )
            }
            // Extraction that silently dropped the pinned section would still
            // publish bullets, so the section itself is asserted.
            #expect(notes.contains("## ⚠️"))
        }
    }

    /// The two languages are one release described twice: a reviewer diffs them
    /// item by item, and the halves are composed into a single body, so a section
    /// or a bullet added to one language only is a defect.
    @Test func bothLanguagesShipTheSameSectionsAndBulletCount() throws {
        var sectionsPerLocale: [[String]] = []
        var bulletsPerLocale: [Int] = []

        for locale in ["zh-Hans", "en"] {
            let history = try shippingHistory(locale: locale)
            let notes = try extract(
                version: try Self.topVersion(of: history),
                from: history
            )
            let lines = notes.split(separator: "\n")
            sectionsPerLocale.append(
                lines
                    .filter { $0.hasPrefix("## ") }
                    .compactMap { $0.dropFirst(3).split(separator: " ").first }
                    .map(String.init)
            )
            bulletsPerLocale.append(lines.filter { $0.hasPrefix("- ") }.count)
        }

        #expect(sectionsPerLocale[0] == sectionsPerLocale[1])
        #expect(bulletsPerLocale[0] == bulletsPerLocale[1])
        #expect(!sectionsPerLocale[0].isEmpty)
        #expect(bulletsPerLocale[0] > 0)
    }

    private func shippingHistory(locale: String) throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Resources/\(locale).lproj/ReleaseHistory.md"),
            encoding: .utf8
        )
    }

    /// The heading of the entry a release would ship next, exactly as written.
    private static func topVersion(of history: String) throws -> String {
        try #require(
            history
                .split(separator: "\n")
                .first { $0.hasPrefix("## ") }?
                .dropFirst(3)
                .trimmingCharacters(in: .whitespaces)
        )
    }

    /// Everything between the newest version heading and the next one, read
    /// independently of the script under test.
    private static func entryBody(of history: String) -> String {
        let lines = history.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## ") }) else {
            return ""
        }
        let end = lines[(start + 1)...].firstIndex { line in
            line.hasPrefix("## ") && line.dropFirst(3).first?.isNumber == true
        } ?? lines.endIndex
        return lines[(start + 1) ..< end].joined(separator: "\n")
    }

    private static func withoutTrailingNewlines(_ value: String) -> String {
        var result = value
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    // MARK: - Composed GitHub release body

    private struct ComposeResult {
        var status: Int32
        var body: String
    }

    private func compose(
        version: String,
        chinese: String,
        english: String
    ) throws -> ComposeResult {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReleaseBodyCompose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let zhURL = directory.appendingPathComponent("zh.md")
        let enURL = directory.appendingPathComponent("en.md")
        try chinese.write(to: zhURL, atomically: true, encoding: .utf8)
        try english.write(to: enURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            repositoryRoot.appendingPathComponent("scripts/compose-release-body.sh").path,
            version,
            zhURL.path,
            enURL.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ComposeResult(
            status: process.terminationStatus,
            body: String(decoding: data, as: UTF8.self)
        )
    }

    private static let englishHistory = """
    # Version History

    ## 1.8.25-fork.4 (this fork)

    - Newest English entry

    ## 1.8.25-fork.3 (this fork)

    - Older English entry

    """

    /// `Release_Notes_Guidelines.md` requires the full Chinese text first and the
    /// full English text after it, not line-by-line alternation.
    @Test func theReleaseBodyCarriesBothLanguagesWithChineseFirst() throws {
        let result = try compose(
            version: "1.8.25",
            chinese: Self.prefixSharingHistory,
            english: Self.englishHistory
        )

        #expect(result.status == 0)
        let chineseIndex = try #require(result.body.range(of: "Newest entry only"))
        let englishIndex = try #require(result.body.range(of: "Newest English entry"))
        #expect(chineseIndex.lowerBound < englishIndex.lowerBound)
        // The rule between the halves went missing once already: zsh's `print`
        // reads a leading dash as options, so it has to be written with `--`.
        #expect(result.body.contains("\n---\n"))
        // Neither half may drag in a neighbouring version.
        #expect(!result.body.contains("Older fork entry"))
        #expect(!result.body.contains("Older English entry"))
    }

    @Test func aMissingEnglishEntryFailsInsteadOfShippingChineseOnly() throws {
        let result = try compose(
            version: "1.8.25",
            chinese: Self.prefixSharingHistory,
            english: "# Version History\n\n## 9.9.9 (unrelated)\n\n- Nothing for us\n"
        )

        #expect(result.status != 0)
        #expect(!result.body.contains("Newest entry only"))
    }

    @Test func aMissingChineseEntryAlsoFails() throws {
        let result = try compose(
            version: "1.8.25",
            chinese: "# 版本历史\n\n## 9.9.9（无关）\n\n- 与本次无关\n",
            english: Self.englishHistory
        )

        #expect(result.status != 0)
    }

    /// The four section headings `Release_Notes_Guidelines.md` fixes, per language.
    /// The guidelines forbid translating or renaming them, so restating them here
    /// is the contract, not a duplicate of the data.
    private static let mandatedChineseSections = [
        "## ⚠️ 注意事项",
        "## 🎉 新功能",
        "## ✨ 改进",
        "## 🐛 问题修复",
    ]
    private static let mandatedEnglishSections = [
        "## ⚠️ Heads-up",
        "## 🎉 New features",
        "## ✨ Improvements",
        "## 🐛 Bug fixes",
    ]

    /// The bodies this repository will actually publish next must compose cleanly.
    @Test func theCurrentTopEntryComposesABilingualBody() throws {
        let chinese = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Resources/zh-Hans.lproj/ReleaseHistory.md"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Resources/en.lproj/ReleaseHistory.md"),
            encoding: .utf8
        )
        let version = try #require(
            chinese
                .split(separator: "\n")
                .first { $0.hasPrefix("## ") }?
                .dropFirst(3)
                .trimmingCharacters(in: .whitespaces)
        )
        // The Chinese heading carries a localized suffix, so compose on the shared
        // numeric prefix the publish script actually passes.
        let numericVersion = String(version.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter })

        let result = try compose(
            version: numericVersion,
            chinese: chinese,
            english: english
        )

        #expect(result.status == 0)

        // The halves used to be wrapped in `## 更新内容` / `## What's New`. Those are
        // `##` siblings of the mandated sections, so the first heading a reader met
        // was the wrapper and `## ⚠️` was no longer pinned to the top. Asserting
        // their presence is what this test used to do; the replacement below is
        // strictly more, because it pins down every heading in the body rather than
        // two of them.
        #expect(!result.body.contains("## 更新内容"))
        #expect(!result.body.contains("## What's New"))

        let lines = result.body.components(separatedBy: "\n")
        // Exactly one rule, so the split into halves is unambiguous — and it is
        // still emitted at all, which `print "---"` silently dropped once.
        let separators = lines.indices.filter { lines[$0] == "---" }
        #expect(separators.count == 1)
        let separator = try #require(separators.first)
        let chineseHalf = Array(lines[..<separator])
        let englishHalf = Array(lines[(separator + 1)...])

        // The release title is the H1; a body H1 renders the title twice.
        #expect(!lines.contains { $0.hasPrefix("# ") })

        for (half, mandated) in [
            (chineseHalf, Self.mandatedChineseSections),
            (englishHalf, Self.mandatedEnglishSections),
        ] {
            let headings = half.filter { $0.hasPrefix("#") }
            let firstHeading = try #require(headings.first)
            // Positively: the half opens on a mandated section, not on a wrapper.
            #expect(mandated.contains(firstHeading))
            // Nothing outranks them (an `#` H1 or an `##` sibling of its own),
            // nothing sits outside the mandated list, nothing repeats.
            #expect(headings.allSatisfy { mandated.contains($0) })
            #expect(Set(headings).count == headings.count)
            // The heads-up is pinned to the top of the half whenever it exists.
            if headings.contains(mandated[0]) {
                #expect(firstHeading == mandated[0])
            }
            // The sections keep the order the guidelines list them in.
            #expect(headings == mandated.filter { headings.contains($0) })
        }

        // Chinese full text first, English full text after it.
        #expect(chineseHalf.contains { $0.hasPrefix("- ") })
        #expect(englishHalf.contains { $0.hasPrefix("- ") })
    }
}

/// The same files also feed the in-app version-history sheet, which renders one
/// card per version. The sections `Release_Notes_Guidelines.md` requires of the
/// GitHub release body live inside a version entry, so they must not turn into
/// cards of their own or split one version's bullets across several cards.
@Suite("Release history sheet")
struct ReleaseHistorySheetParsingTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func guidelineSectionHeadingsDoNotBecomeVersionCards() {
        let sections = ReleaseHistorySection.parse(markdown: """
        # 版本历史

        ## 1.9.0（本分支）

        ## ⚠️ 注意事项

        - Pinned heads-up bullet

        ## ✨ 改进

        - Improvement bullet

        ## 🐛 问题修复

        - Bug fix bullet

        ## 1.8.25-fork.4（本分支）

        - Previous release bullet
        """)

        #expect(sections.count == 2)
        #expect(sections.first?.title == "1.9.0（本分支）")
        #expect(sections.first?.entries == [
            "Pinned heads-up bullet",
            "Improvement bullet",
            "Bug fix bullet",
        ])
        #expect(sections.last?.title == "1.8.25-fork.4（本分支）")
        #expect(sections.last?.entries == ["Previous release bullet"])
    }

    @Test func everyShippingLocaleKeepsOneCardPerVersionWithEveryBullet() throws {
        for locale in ["zh-Hans", "en"] {
            let markdown = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Resources/\(locale).lproj/ReleaseHistory.md"),
                encoding: .utf8
            )
            let sections = ReleaseHistorySection.parse(markdown: markdown)

            #expect(!sections.isEmpty)
            // A version heading is the only thing that opens a card.
            for section in sections {
                #expect(section.title.first?.isNumber == true)
                #expect(!section.entries.isEmpty)
            }
            // The newest entry keeps every bullet it has in the file, including the
            // ones written under a section heading.
            let bulletsInNewestEntry = markdown
                .components(separatedBy: "\n")
                .drop { !$0.hasPrefix("## ") }
                .dropFirst()
                .prefix { line in
                    !(line.hasPrefix("## ") && line.dropFirst(3).first?.isNumber == true)
                }
                .filter { $0.hasPrefix("- ") }
                .count
            #expect(sections.first?.entries.count == bulletsInNewestEntry)
            #expect(bulletsInNewestEntry > 0)
        }
    }
}
