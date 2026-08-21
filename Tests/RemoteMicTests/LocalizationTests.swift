import Foundation
import Testing
@testable import RemoteMic

@Suite("Application localization")
struct LocalizationTests {
    @Test func languageSelectionPersistsAndUpdatesTheLocaleImmediately() throws {
        let suiteName = "RemoteMicTests.Localization.(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let localization = LocalizationStore(settings: settings)

        localization.select(.english)
        #expect(localization.language == .english)
        #expect(localization.locale.identifier == "en")
        #expect(localization.localizedWebsiteURL.absoluteString == "https://sayall.app/en/")
        #expect(AppSettings(defaults: defaults).applicationLanguage == .english)

        localization.select(.simplifiedChinese)
        #expect(localization.language == .simplifiedChinese)
        #expect(localization.locale.identifier == "zh-Hans")
        #expect(localization.localizedWebsiteURL.absoluteString == "https://sayall.app/")
        #expect(AppSettings(defaults: defaults).applicationLanguage == .simplifiedChinese)
    }

    @Test func appLinksProvideThePublicTestFlightBetaEverywhere() throws {
        let expectedURL = "https://testflight.apple.com/join/J8k8fb7v"
        #expect(AppLinks.testFlightPublicBeta.absoluteString == expectedURL)

        // This fork's READMEs drop the TestFlight entry along with the rest of the
        // promotional material, so only the repo-wide uniqueness scan below applies.
        let expression = try NSRegularExpression(
            pattern: #"https://testflight\.apple\.com/join/[A-Za-z0-9]+"#
        )
        let allowedExtensions = Set([
            "json", "md", "plist", "sh", "strings", "swift", "ts", "tsx", "yaml", "yml"
        ])
        let ignoredDirectories = Set([".build", ".git", ".swiftpm", "dist"])
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: repositoryRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        )
        var referencedURLs: Set<String> = []

        while let fileURL = enumerator.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true {
                if ignoredDirectories.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard allowedExtensions.contains(fileURL.pathExtension.lowercased()),
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8)
            else {
                continue
            }
            let range = NSRange(contents.startIndex..., in: contents)
            for match in expression.matches(in: contents, range: range) {
                guard let matchRange = Range(match.range, in: contents) else { continue }
                referencedURLs.insert(String(contents[matchRange]))
            }
        }

        #expect(referencedURLs == [expectedURL])
    }

    @Test func readmesUseVersionIndependentMacDownloadEntries() throws {
        let upstreamReleasesURL = "https://github.com/HD838A/remote-mic-app/releases"
        let expectations = [
            ("README.md", "## 安装"),
            ("README.en.md", "## Installation"),
        ]

        for (readmeName, sectionHeading) in expectations {
            let readme = try String(
                contentsOf: repositoryRoot.appendingPathComponent(readmeName),
                encoding: .utf8
            )
            let sectionStart = try #require(readme.range(of: sectionHeading))
            let remainingReadme = readme[sectionStart.upperBound...]
            let sectionEnd = remainingReadme.range(of: "\n## ")?.lowerBound ?? readme.endIndex
            let installSection = readme[sectionStart.lowerBound..<sectionEnd]

            // The fork ships no installer, so the section points at upstream's release
            // index. It must stay version-independent: a pinned tag or asset URL rots.
            #expect(installSection.contains("](\(upstreamReleasesURL))"))
            #expect(!installSection.contains("/releases/tag/"))
            #expect(!installSection.contains("/releases/download/"))
        }
    }

    @Test func localizationFilesUseSemanticCompleteKeysAndMatchingFormats() throws {
        let localizationDirectories = try sourceLocalizationDirectories()
        let englishDirectory = try #require(
            localizationDirectories.first { $0.lastPathComponent == "en.lproj" }
        )
        let english = try strings(at: englishDirectory.appendingPathComponent("Localizable.strings"))
        let englishInfo = try strings(at: englishDirectory.appendingPathComponent("InfoPlist.strings"))

        #expect(english["action.command_delete"] == "Command-Delete")
        #expect(english["about.support.feedback"] == "Feedback")
        #expect(english["onboarding.remote.first_pairing.wake"] == "Hold TV for about 2 seconds until the white light at the bottom starts flashing.")
        #expect(english["onboarding.remote.first_pairing.pair"] == "Then hold Home + Menu together to enter Bluetooth pairing mode.")

        #expect(!english.isEmpty)
        for (key, value) in english {
            #expect(key.range(of: #"^[a-z0-9]+(?:[._][a-z0-9]+)*$"#, options: .regularExpression) != nil)
            #expect(!value.isEmpty)
            #expect(value != key)
        }

        for directory in localizationDirectories {
            let localized = try strings(at: directory.appendingPathComponent("Localizable.strings"))
            let localizedInfo = try strings(at: directory.appendingPathComponent("InfoPlist.strings"))
            if directory.lastPathComponent == "zh-Hans.lproj" {
                #expect(localized["action.command_delete"] == "Command-Delete")
                #expect(localized["about.support.feedback"] == "问题反馈")
                #expect(localized["onboarding.remote.first_pairing.wake"] == "长按 TV 键约 2 秒，直到遥控器底部白灯开始闪烁。")
                #expect(localized["onboarding.remote.first_pairing.pair"] == "同时长按 Home（主页）+ Menu（菜单）键，进入蓝牙配对模式。")
            }
            #expect(Set(localized.keys) == Set(english.keys))
            #expect(Set(localizedInfo.keys) == Set(englishInfo.keys))

            for key in english.keys {
                let englishValue = try #require(english[key])
                let localizedValue = try #require(localized[key])
                #expect(!localizedValue.isEmpty)
                #expect(localizedValue != key)
                #expect(formatPlaceholders(in: localizedValue) == formatPlaceholders(in: englishValue))
                #expect(!containsRestrictedUserTerm(localizedValue))
            }
        }
    }

    /// The connection approval alerts are `NSAlert`s, so they resolve their copy at runtime
    /// through `LocalizationStore`. A missing key does not crash there — `text(_:)` hands back
    /// the identifier — so the user is shown something like `connection.approval.deny` on a
    /// button. The key-set parity check above cannot catch that on its own, because it only
    /// compares the two files against each other: a key absent from *both* passes.
    ///
    /// This walks the keys the alerts actually ask for, which is why they are declared in one
    /// list on `ConnectionApprovalAlertText` rather than inline at each assignment.
    @Test func connectionApprovalAlertsResolveEveryKeyInBothLanguages() throws {
        let referencedKeys = BridgeAppModel.ConnectionApprovalAlertText.referencedKeys
        #expect(!referencedKeys.isEmpty)
        #expect(Set(referencedKeys).count == referencedKeys.count)

        // Arguments each call site passes, so a template with the wrong arity is caught here
        // rather than printing a stray placeholder into a security prompt.
        let expectedPlaceholderCounts = [
            "connection.approval.nearby.title": 1,
            "connection.approval.watch.detail": 0,
            "connection.approval.phone.detail": 0,
            "connection.approval.web.title": 1,
            "connection.approval.web.detail": 0,
            "connection.web.pairing_code_accessibility": 1,
            "connection.approval.allow": 0,
            "connection.approval.deny": 0,
            "connection.phone.cancel_waiting": 0,
        ]
        #expect(Set(expectedPlaceholderCounts.keys) == Set(referencedKeys))

        for directory in try sourceLocalizationDirectories() {
            let localized = try strings(
                at: directory.appendingPathComponent("Localizable.strings")
            )
            let language = directory.lastPathComponent

            for key in referencedKeys {
                let value = try #require(
                    localized[key],
                    Comment(rawValue: "\(language) is missing \(key)")
                )
                #expect(!value.isEmpty, Comment(rawValue: "\(language) \(key)"))
                #expect(value != key, Comment(rawValue: "\(language) \(key)"))
                #expect(
                    formatPlaceholders(in: value).count == expectedPlaceholderCounts[key],
                    Comment(rawValue: "\(language) \(key) placeholder arity")
                )
            }

            // The defect these keys replaced was hard-coded Chinese reaching English users,
            // so an English file that merely copies the Chinese would not be a fix.
            if language == "en.lproj" {
                for key in referencedKeys {
                    let value = try #require(localized[key])
                    #expect(
                        !containsCJKText(value),
                        Comment(rawValue: "en \(key) still contains Chinese")
                    )
                }
            }
        }
    }

    @Test func glossaryResourcesContainTheDocumentedTechnicalTerms() throws {
        for localization in ["en", "zh-Hans"] {
            let glossaryURL = repositoryRoot
                .appendingPathComponent("Resources")
                .appendingPathComponent("\(localization).lproj")
                .appendingPathComponent("Glossary.md")
            let glossary = try String(contentsOf: glossaryURL, encoding: .utf8)
            for term in ["RC003", "ATVV", "HID", "UUID", "Core Audio", "DMG", "PKG"] {
                #expect(glossary.contains(term))
            }
        }
    }

    @Test func localizedDocumentsFallBackToEnglish() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("RemoteMicLocalizationTests-\(UUID().uuidString)")
        let bundleURL = temporaryRoot.appendingPathComponent("Localization.bundle")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        let englishURL = resourcesURL.appendingPathComponent("en.lproj")
        let chineseURL = resourcesURL.appendingPathComponent("zh-Hans.lproj")
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try fileManager.createDirectory(at: englishURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: chineseURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": "com.hd838a.RemoteMic.LocalizationTests",
            "CFBundlePackageType": "BNDL"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data("English glossary".utf8).write(to: englishURL.appendingPathComponent("Glossary.md"))

        let bundle = try #require(Bundle(url: bundleURL))
        let suiteName = "RemoteMicTests.LocalizationFallback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = .simplifiedChinese
        let localization = LocalizationStore(settings: settings, resourceBundle: bundle)
        let localizedURL = try #require(
            localization.localizedURL(forResource: "Glossary", withExtension: "md")
        )

        #expect(try String(contentsOf: localizedURL, encoding: .utf8) == "English glossary")
    }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func sourceLocalizationDirectories() throws -> [URL] {
    let resourcesURL = repositoryRoot.appendingPathComponent("Resources")
    return try FileManager.default.contentsOfDirectory(
        at: resourcesURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "lproj" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func strings(at url: URL) throws -> [String: String] {
    let data = try Data(contentsOf: url)
    let propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    )
    return try #require(propertyList as? [String: String])
}

private func formatPlaceholders(in value: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: #"%(?:[0-9]+\$)?[a-zA-Z@]"#)
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
        guard let range = Range(match.range, in: value) else { return nil }
        return String(value[range])
    }.sorted()
}

private func containsRestrictedUserTerm(_ value: String) -> Bool {
    value.range(
        of: #"RC003|ATVV|\bHID\b|\bUUID\b|virtual[ -]transport"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}

/// CJK unified ideographs. Used to prove an English value is really English rather than a
/// copy of the Chinese wording, which is the failure the approval alerts shipped with.
private func containsCJKText(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3000...0x303F).contains(scalar.value)
    }
}
