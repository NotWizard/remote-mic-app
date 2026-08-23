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
}
