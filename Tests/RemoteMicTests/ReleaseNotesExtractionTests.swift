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

    private func extract(
        version: String,
        from history: String,
        bulletsOnly: Bool = false
    ) throws -> String {
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
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
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
                #expect(line.dropFirst(3).first?.isNumber != true)
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
        #expect(result.body.contains("## 更新内容"))
        #expect(result.body.contains("## What's New"))
        let zhHeading = try #require(result.body.range(of: "## 更新内容"))
        let enHeading = try #require(result.body.range(of: "## What's New"))
        #expect(zhHeading.lowerBound < enHeading.lowerBound)
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
