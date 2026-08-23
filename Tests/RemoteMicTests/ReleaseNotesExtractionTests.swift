import Foundation
import Testing

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

    private func extract(version: String, from history: String) throws -> String {
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
        ]
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

    /// The publish script requires at least one bullet in the generated notes, so
    /// the entry the next release will actually ship must satisfy that gate in
    /// both languages.
    @Test func theCurrentTopEntryExtractsBulletsInBothLanguages() throws {
        for locale in ["zh-Hans", "en"] {
            let history = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Resources/\(locale).lproj/ReleaseHistory.md"),
                encoding: .utf8
            )
            let version = try #require(
                history
                    .split(separator: "\n")
                    .first { $0.hasPrefix("## ") }?
                    .dropFirst(3)
                    .trimmingCharacters(in: .whitespaces)
            )
            let notes = try extract(version: version, from: history)

            #expect(notes.split(separator: "\n").contains { $0.hasPrefix("- ") })
            #expect(!notes.contains("## "))
        }
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
