import Foundation
import SayAllMacRemoteCore
import SwiftUI
import Testing
@testable import RemoteMic

@Suite("Settings page regression")
struct SettingsPageRegressionTests {
    /// Records every line the shared logger actually writes.
    ///
    /// `AppLogger` notifies observers synchronously from the writing thread, so a lock is
    /// required rather than optional. Suppressed (folded) lines never reach observers, but
    /// none of the messages asserted here are foldable.
    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        /// The logger is process-global and suites run in parallel, so every needle used
        /// with this has to name the source it belongs to.
        func count(of needle: String) -> Int {
            lines.filter { $0.contains(needle) }.count
        }
    }

    private struct SettingsScope {
        let settings: AppSettings
        let defaults: UserDefaults
        let name: String

        func tearDown() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private static func scopedSettings(_ label: String) throws -> SettingsScope {
        let name = "SettingsPageRegressionTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return SettingsScope(settings: AppSettings(defaults: defaults), defaults: defaults, name: name)
    }

    @Test func applicationEditMenuPreservesStandardTextEditingShortcuts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        for key in ["copy:", "paste:", "cut:", "undo:", "redo:", "selectAll:"] {
            #expect(appSource.contains("action: \"\(key)\""))
        }
        #expect(appSource.contains("item.target = nil"))
        #expect(appSource.contains("common.action.copy"))
        #expect(appSource.contains("common.action.select_all"))
    }

    @Test func versionTapRevealRequiresFiveConsecutiveTaps() {
        var counter = VersionTapRevealCounter()

        for expectedCount in 1...4 {
            let revealed = counter.registerTap()
            #expect(!revealed)
            #expect(counter.tapCount == expectedCount)
        }

        let revealed = counter.registerTap()
        #expect(revealed)
        #expect(counter.tapCount == 0)
        let revealedAgain = counter.registerTap()
        #expect(!revealedAgain)
        #expect(counter.tapCount == 1)
    }

    @Test func privateFeatureFallbackRemainsCompletelyHiddenWithoutPackage() {
        #if !canImport(SayAllAI)
        let privateFeature = PrivateFeatureIntegration(localeIdentifier: "zh-Hans")

        #expect(!privateFeature.isAvailable)
        #expect(!privateFeature.isFeatureVisible)
        #expect(!privateFeature.shouldShowEnrollment)
        #endif
    }

    /// Both nearby listeners are user-initiated, one switch owns both, and an approval that
    /// arrives after the switch went off is refused.
    ///
    /// This replaces fourteen substring assertions on `BridgeAppModel.swift`: that the text
    /// between `func startIfNeeded()` and `func stop()` did not mention
    /// `phoneRemoteServer.start()`, that `enablePhoneRemoteConnection()` did mention it and
    /// `watchBluetoothServer.start()`, that the file somewhere contained
    /// `phoneRemoteServer.stop()`, `watchBluetoothServer.stop()`,
    /// `func disablePhoneRemoteConnection()`, `func togglePhoneRemoteConnection()` and two
    /// particular `guard` statements. Every one of those substrings survived the 366-line
    /// main-actor rewrite of this file with an identical occurrence count — including
    /// `guard self.isPhoneRemoteConnectionEnabled else`, whose surrounding
    /// `DispatchQueue.main.async` was deleted in that commit while the assertion demanding
    /// the guard text stayed green.
    ///
    /// The fork-local transports are no-ops that record nothing, so "the listener came up"
    /// is observed through the line each transport writes through its injected logger when
    /// it is started. That is the only evidence available that both transports were reached
    /// rather than just the phone; it is fork-stub-specific and would need revisiting if the
    /// private package is ever restored.
    @MainActor
    @Test func nearbyMobileListenersComeUpOnlyFromAUserConnectionEntry() throws {
        let scope = try Self.scopedSettings("nearbyEntry")
        defer { scope.tearDown() }
        let model = BridgeAppModel(settings: scope.settings, hidRuntimePermissions: { false })
        let sink = LogSink()
        let token = AppLogger.shared.addWriteObserver { sink.record($0) }
        defer { AppLogger.shared.removeWriteObserver(token) }

        // Constructed but not started: nothing listens and nothing is connected.
        #expect(!model.isPhoneRemoteConnectionEnabled)
        #expect(!model.isWatchRemoteConnectionEnabled)
        #expect(!model.isPhoneRemoteConnected)
        #expect(!model.isWatchRemoteConnected)
        #expect(model.webRemoteState == .disabled)

        // Launch alone must never bring a listener up. Every connection entry point is
        // gated on the app having started, so all four are inert here — this is the
        // property the old `startIfNeeded()` text search was standing in for, and unlike
        // that search it does not care where in the file the calls live.
        model.togglePhoneRemoteConnection()
        model.toggleWatchRemoteConnection()
        model.enablePhoneRemoteConnection()
        model.enableWatchRemoteConnection()
        model.enableWebRemoteConnection()
        AppLogger.shared.flush()
        #expect(!model.isPhoneRemoteConnectionEnabled)
        #expect(!model.isWatchRemoteConnectionEnabled)
        #expect(model.webRemoteState == .disabled)
        #expect(sink.count(of: "PHONE REMOTE enabled_by_user") == 0)
        #expect(sink.count(of: "PHONE REMOTE unavailable_in_fork_build") == 0)
        #expect(sink.count(of: "WATCH REMOTE unavailable_in_fork_build") == 0)

        model.started = true

        // One user entry starts both nearby transports, not just the phone.
        model.togglePhoneRemoteConnection()
        AppLogger.shared.flush()
        #expect(model.isPhoneRemoteConnectionEnabled)
        #expect(model.isWatchRemoteConnectionEnabled)
        #expect(sink.count(of: "PHONE REMOTE enabled_by_user") == 1)
        #expect(sink.count(of: "PHONE REMOTE unavailable_in_fork_build") == 1)
        #expect(sink.count(of: "WATCH REMOTE unavailable_in_fork_build") == 1)

        // Asking again while it is already on must change nothing. A second start would
        // leave the first listener behind, advertising the Mac twice.
        model.enablePhoneRemoteConnection()
        model.enableWatchRemoteConnection()
        AppLogger.shared.flush()
        #expect(sink.count(of: "PHONE REMOTE enabled_by_user") == 1)
        #expect(sink.count(of: "PHONE REMOTE unavailable_in_fork_build") == 1)
        #expect(sink.count(of: "WATCH REMOTE unavailable_in_fork_build") == 1)

        // The watch entry is the same switch as the phone entry, so turning it off from
        // the watch row clears both rows.
        model.toggleWatchRemoteConnection()
        AppLogger.shared.flush()
        #expect(!model.isPhoneRemoteConnectionEnabled)
        #expect(!model.isWatchRemoteConnectionEnabled)
        #expect(!model.isPhoneRemoteConnected)
        #expect(!model.isWatchRemoteConnected)
        #expect(sink.count(of: "PHONE REMOTE disabled_by_user") == 1)

        // And a second off is a no-op rather than a second teardown.
        model.disablePhoneRemoteConnection()
        AppLogger.shared.flush()
        #expect(sink.count(of: "PHONE REMOTE disabled_by_user") == 1)

        // An approval that arrives after the user stopped listening is refused without
        // presenting anything, and the phone is not remembered as trusted. The old test
        // asserted the text of the guard that does this.
        let fingerprint = "SettingsPageRegressionTests-\(UUID().uuidString)"
        var answers: [Bool] = []
        model.requestPhoneApproval(
            deviceName: "iPhone",
            pairingCode: "123456",
            identityFingerprint: fingerprint
        ) { answers.append($0) }
        #expect(answers == [false])
        #expect(!scope.settings.isPhoneIdentityTrusted(fingerprint))
        #expect(!model.isPhoneRemoteConnectionEnabled)
    }

    /// One mobile voice source owns the channel; the others are refused and cannot end it.
    ///
    /// This replaces ten substring assertions on `BridgeAppModel.swift` (`case nearbyPhone`,
    /// `case nearbyWatch`, `phoneRemoteServer.onVoiceStartResult`,
    /// `startPhoneVoice(source: .nearbyPhone)`, `stopPhoneVoice(source: .nearbyPhone)`, the
    /// watch equivalents, `return .busy`, and that `startPhoneVoice(source: .nearby)` was
    /// absent). All ten had identical occurrence counts before and after the main-actor
    /// rewrite of this file, so they tracked nothing that commit could have broken.
    ///
    /// The rule they stood in for is the fix for the watch BLE backlog defect of
    /// 2026-08-15: both nearby transports used to share one source marker, so the watch's
    /// stop — which arrived about 28 seconds late behind its own audio backlog — ended the
    /// iPhone's session and left the channel occupied for the next iPhone request.
    ///
    /// `startPhoneVoice` is only ever called here with the channel already held. The busy
    /// arbitration is its first gate, so a refused request touches no hardware, whereas an
    /// admitted one would bind the virtual audio device and latch a real modifier key on a
    /// machine that has the driver installed.
    @MainActor
    @Test func oneMobileVoiceSourceOwnsTheChannelAndTheOthersAreRefused() throws {
        let scope = try Self.scopedSettings("voiceIsolation")
        defer { scope.tearDown() }
        let model = BridgeAppModel(settings: scope.settings, hidRuntimePermissions: { false })
        let sink = LogSink()
        let token = AppLogger.shared.addWriteObserver { sink.record($0) }
        defer { AppLogger.shared.removeWriteObserver(token) }

        // The iPhone holds the channel.
        model.activeMobileVoiceSource = .nearbyPhone

        // The watch, the web page, and even a duplicate request from the holder itself are
        // all refused, and none of them takes the channel over.
        #expect(model.startPhoneVoice(source: .nearbyWatch) == .busy)
        #expect(model.activeMobileVoiceSource == .nearbyPhone)
        #expect(model.startPhoneVoice(source: .web) == .busy)
        #expect(model.activeMobileVoiceSource == .nearbyPhone)
        #expect(model.startPhoneVoice(source: .nearbyPhone) == .busy)
        #expect(model.activeMobileVoiceSource == .nearbyPhone)
        AppLogger.shared.flush()
        #expect(sink.count(
            of: "MOBILE VOICE start_rejected reason=busy requested=watch active=iphone"
        ) == 1)
        #expect(sink.count(
            of: "MOBILE VOICE start_rejected reason=busy requested=web active=iphone"
        ) == 1)
        #expect(sink.count(
            of: "MOBILE VOICE start_rejected reason=busy requested=iphone active=iphone"
        ) == 1)
        // A refused request must not open a session of its own.
        #expect(sink.count(of: "MOBILE VOICE started source=") == 0)
        #expect(!model.isStreaming)

        // A stop from a source that does not hold the channel must not release it. This is
        // the 2026-08-15 defect itself.
        model.stopPhoneVoice(source: .nearbyWatch)
        #expect(model.activeMobileVoiceSource == .nearbyPhone)
        model.stopPhoneVoice(source: .web)
        #expect(model.activeMobileVoiceSource == .nearbyPhone)
        AppLogger.shared.flush()
        #expect(sink.count(of: "MOBILE VOICE stop_ignored requested=watch active=iphone") == 1)
        #expect(sink.count(of: "MOBILE VOICE stop_ignored requested=web active=iphone") == 1)
        #expect(sink.count(of: "MOBILE VOICE stopped source=iphone") == 0)

        // Audio from a source that does not hold the channel is dropped rather than mixed
        // into the live session.
        model.receivePhoneAudio([1, 2, 3, 4], source: .nearbyWatch)
        AppLogger.shared.flush()
        #expect(sink.count(
            of: "MOBILE VOICE audio_dropped reason=source_mismatch requested=watch " +
                "active=iphone count=1"
        ) == 1)
        // The next mismatch is counted but deliberately not written: only the first and
        // then every twentieth is reported, so misrouted audio cannot flood the log.
        model.receivePhoneAudio([5, 6], source: .web)
        AppLogger.shared.flush()
        #expect(sink.count(
            of: "MOBILE VOICE audio_dropped reason=source_mismatch requested=web"
        ) == 0)
        #expect(sink.count(of: "MOBILE VOICE audio source=iphone") == 0)

        // Positive control. Everything above would also hold for an implementation that
        // simply refused every source, so the holder's own audio and its own stop have to
        // be accepted. There is no audio device in a test process, which is why the
        // accounting reports the write as rejected rather than played.
        model.receivePhoneAudio([7, 8], source: .nearbyPhone)
        AppLogger.shared.flush()
        #expect(sink.lines.contains {
            $0.contains("MOBILE VOICE audio source=iphone batches=1 samples=2 nonzero=2")
                && $0.contains("accepted=false enqueue_failures=1")
        })

        model.stopPhoneVoice(source: .nearbyPhone)
        AppLogger.shared.flush()
        #expect(model.activeMobileVoiceSource == nil)
        #expect(sink.count(of: "MOBILE VOICE stopped source=iphone") == 1)
        // The closing summary carries both mismatches, including the one that was counted
        // without being reported.
        #expect(sink.lines.contains {
            $0.contains("MOBILE VOICE audio_summary source=iphone reason=voice_stop")
                && $0.contains("source_mismatches=2")
        })

        // With the channel free, a further stop is ignored rather than reported twice.
        model.stopPhoneVoice(source: .nearbyPhone)
        AppLogger.shared.flush()
        #expect(sink.count(of: "MOBILE VOICE stop_ignored requested=iphone active=none") == 1)
        #expect(sink.count(of: "MOBILE VOICE stopped source=iphone") == 1)
    }

    /// The button titles the Mac computes reach the Apple Watch transport, not just the phone.
    ///
    /// This replaces the source-text assertion `watchBluetoothServer.updateButtonTitles(titles)`,
    /// which only proved the call was still written, not that the watch actually received the
    /// titles a user's mapping produces — the exact failure mode the whole effort targets. The
    /// fork-local transport now records receipt through the same injected logger it already uses
    /// for `start()`, so the watch's receipt is observable. Driving `updatePhoneRemoteButtonTitles`
    /// also exercises the real title rule: only bindings that differ from the default become a
    /// title, keyed by the button's raw value.
    ///
    /// Negative control: deleting `watchBluetoothServer.updateButtonTitles(titles)` from
    /// `BridgeAppModel.updatePhoneRemoteButtonTitles` removes the `WATCH REMOTE button_titles`
    /// line and turns the first expectation red, whereas the old substring assertion stayed green.
    @MainActor
    @Test func theButtonTitlesTheMacComputesReachTheWatchTransport() throws {
        let scope = try Self.scopedSettings("watchButtonTitles")
        defer { scope.tearDown() }
        let model = BridgeAppModel(settings: scope.settings, hidRuntimePermissions: { false })
        let sink = LogSink()
        let token = AppLogger.shared.addWriteObserver { sink.record($0) }
        defer { AppLogger.shared.removeWriteObserver(token) }
        let localization = LocalizationStore(settings: scope.settings)

        // One binding that differs from its default (power defaults to Escape) becomes exactly
        // one title, keyed by the button's raw value. Every other button is left at its default
        // so it produces nothing — a button absent from the map would fall to `.disabled`, which
        // also differs from its default and would add a title. The watch must receive the payload
        // — not only the phone — and from the same payload, so it is not fed by a divergent path.
        var oneChangedBinding = AppSettings.defaultBindings
        oneChangedBinding[.power] = .returnKey
        model.updatePhoneRemoteButtonTitles(
            bindings: oneChangedBinding,
            shortcuts: [:],
            localization: localization
        )
        AppLogger.shared.flush()
        #expect(sink.count(of: "WATCH REMOTE button_titles count=1 buttons=power") == 1)
        #expect(sink.count(of: "PHONE REMOTE button_titles count=1 buttons=power") == 1)

        // A mapping that matches every default produces no titles, so the watch is handed an
        // empty payload rather than a stale one. This pins the changed-from-default rule.
        model.updatePhoneRemoteButtonTitles(
            bindings: AppSettings.defaultBindings,
            shortcuts: [:],
            localization: localization
        )
        AppLogger.shared.flush()
        #expect(sink.count(of: "WATCH REMOTE button_titles count=0 buttons=") == 1)
    }

    /// The two remaining connection-approval assertions that have no runtime surface, kept as
    /// source text rather than dropped.
    ///
    /// - `connection.phone.cancel_waiting` and `response == .alertThirdButtonReturn`: both belong
    ///   to the third button of a modal `NSAlert`. Reaching them requires `runModal()`, which
    ///   would block the suite, and there is no injectable alert presenter in this repository, so
    ///   they cannot be driven behaviourally without a facility it lacks.
    ///
    /// The neighbouring refusal path — a late approval answered `false` without presenting
    /// anything — is covered behaviourally in
    /// `nearbyMobileListenersComeUpOnlyFromAUserConnectionEntry`, and the push of computed titles
    /// to the watch is covered in `theButtonTitlesTheMacComputesReachTheWatchTransport`.
    @Test func modalStopWaitingButtonPartsWithoutARuntimeSurfaceStayDeclared() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("LocalizedMessage(\"connection.phone.cancel_waiting\")"))
        #expect(source.contains("response == .alertThirdButtonReturn"))
    }

    @Test func mobileConnectionStatusMeetsFontAndSnapshotGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let rendererSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/SettingsScreenshotRenderer.swift"
            ),
            encoding: .utf8
        )

        let noInvite = try #require(settingsSource.range(
            of: "Text(\"connection.phone.no_invite_badge\")"
        ))
        let noInviteBlock = settingsSource[noInvite.lowerBound...]
            .prefix(180)
        #expect(noInviteBlock.contains(".font(.appCaptionStrong)"))

        let statusPill = try #require(settingsSource.range(of: "private struct StatusPill"))
        let statusPillBlock = settingsSource[statusPill.lowerBound...]
            .prefix(420)
        #expect(statusPillBlock.contains(".font(.appCaptionStrong)"))

        // Naming the token is only half the guarantee; the token itself has to clear the
        // repository's 12pt floor, and that part is a value rather than a source string.
        #expect(
            InterfaceTextStyle.captionStrong.pointSize
                >= InterfaceTypography.minimumPointSize
        )
        #expect(appSource.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_DIR"))
        #expect(rendererSource.contains("width >= 800"))
        #expect(rendererSource.contains("height >= 650"))
        for section in ["connection", "mapping", "statistics", "permissions", "about"] {
            #expect(rendererSource.contains(".\(section)"))
        }
    }

    @Test func corruptedSettingsBannerIsInlineAndNeverShrinksChineseBelowTwelvePoints() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        // The two interface rules this banner has to satisfy are a rendered-pixel property and
        // a presentation-style property. Neither is observable from the notice's return value,
        // and asserting them by snapshot would need a running window, so this is the one part
        // of the feature that has to be checked against the declaration itself. The wording and
        // the show/hide decision are covered behaviourally in CorruptedSettingsNoticeTests.
        let bannerStart = try #require(
            settingsSource.range(of: "private var corruptedSettingsBanner: some View {")
        )
        let bannerEnd = try #require(settingsSource.range(
            of: "private func mappingEditorPanel",
            range: bannerStart.upperBound..<settingsSource.endIndex
        ))
        let banner = settingsSource[bannerStart.upperBound..<bannerEnd.lowerBound]

        // Semantic styles are banned here: .caption and .caption2 render at 10pt and
        // .subheadline at 11pt, all of which break the 12pt floor for Chinese text.
        for bannedStyle in [
            ".font(.caption)",
            ".font(.caption2)",
            ".font(.subheadline)",
            ".font(.footnote)",
            "minimumScaleFactor",
        ] {
            #expect(!banner.contains(bannedStyle), Comment(rawValue: bannedStyle))
        }

        // Every font in the banner must either name a token from the shared table or be an
        // explicit size at or above the floor. Counting both and requiring them to account
        // for every `.font(` is what stops a third, unchecked convention appearing here.
        let approvedTokens = [
            ".font(.appCaption)",
            ".font(.appCaptionMedium)",
            ".font(.appCaptionStrong)",
            ".font(.appCaptionHeavy)",
            ".font(.appBody)",
            ".font(.appBodyStrong)",
        ]
        let bannerText = String(banner)
        let fontCount = bannerText.components(separatedBy: ".font(").count - 1
        let tokenCount = approvedTokens.reduce(0) { total, token in
            total + bannerText.components(separatedBy: token).count - 1
        }

        let sizes = try NSRegularExpression(pattern: #"\.font\(\.system\(\s*size: (\d+)"#)
        let range = NSRange(bannerText.startIndex..., in: bannerText)
        let matches = sizes.matches(in: bannerText, range: range)
        for match in matches {
            let digits = try #require(Range(match.range(at: 1), in: bannerText))
            let size = try #require(Int(bannerText[digits]))
            #expect(size >= 12, Comment(rawValue: "font size \(size)"))
        }

        #expect(fontCount > 0)
        #expect(tokenCount > 0)
        #expect(
            tokenCount + matches.count == fontCount,
            Comment(rawValue: "\(tokenCount) tokens + \(matches.count) sizes of \(fontCount)")
        )

        // And the tokens the banner names have to clear the floor, which is a value rather
        // than something scraped out of a source file.
        for style in InterfaceTextStyle.allCases {
            #expect(
                style.pointSize >= InterfaceTypography.minimumPointSize,
                Comment(rawValue: "\(style.rawValue) is \(style.pointSize)pt")
            )
        }

        // Inline on the page: a dismissible container would hide the warning after one look.
        for bannedContainer in [".popover(", ".sheet(", ".alert(", ".confirmationDialog("] {
            #expect(!banner.contains(bannedContainer), Comment(rawValue: bannedContainer))
        }
        // ... and it has to be mounted on the mapping page, where the lost mappings live.
        let mappingPage = try #require(settingsSource.range(of: "private var mappingPage"))
        let mappingPageEnd = try #require(settingsSource.range(
            of: "private var corruptedSettingsBanner",
            range: mappingPage.upperBound..<settingsSource.endIndex
        ))
        #expect(
            settingsSource[mappingPage.upperBound..<mappingPageEnd.lowerBound]
                .contains("corruptedSettingsBanner")
        )
    }

    @Test func settingsWindowDragsOnlyFromDedicatedTopArea() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("window.isMovableByWindowBackground = false"))
        #expect(!appSource.contains("window.isMovableByWindowBackground = true"))
        #expect(settingsSource.contains("WindowDragArea()"))
        #expect(settingsSource.contains("window?.performDrag(with: event)"))
    }

    @Test func mappingSelectionStaysOnTheEditedButtonWhileLocked() {
        #expect(MappingSelectionPolicy.selection(
            current: .home,
            activeButtons: [.menu],
            isLocked: true
        ) == .home)
        #expect(MappingSelectionPolicy.selection(
            current: .home,
            activeButtons: [.menu],
            isLocked: false
        ) == .menu)
        #expect(MappingSelectionPolicy.selection(
            current: .home,
            activeButtons: [],
            isLocked: false
        ) == .home)
    }

    @Test func customMappingPromptsOnlyWhenAnEnabledPermissionIsMissing() {
        #expect(MappingPermissionPolicy.requiresPrompt(
            enabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: true
        ))
        #expect(MappingPermissionPolicy.requiresPrompt(
            enabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ))
        #expect(!MappingPermissionPolicy.requiresPrompt(
            enabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
        #expect(!MappingPermissionPolicy.requiresPrompt(
            enabled: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ))
    }

    @Test func remoteMappingLayoutCoversEveryRealButtonWithExactConnectorAnchors() throws {
        let placements = RemoteMappingLayout.buttonPlacements
        #expect(placements.count == RemoteButton.allCases.count)
        #expect(Set(placements.map(\.button)) == Set(RemoteButton.allCases))

        let expectedAnchors: [RemoteButton: UnitPoint] = [
            .power: UnitPoint(x: 0.386, y: 0.099),
            .up: UnitPoint(x: 0.502, y: 0.179),
            .left: UnitPoint(x: 0.362, y: 0.246),
            .ok: UnitPoint(x: 0.502, y: 0.246),
            .right: UnitPoint(x: 0.638, y: 0.246),
            .down: UnitPoint(x: 0.502, y: 0.317),
            .back: UnitPoint(x: 0.406, y: 0.389),
            .volumeUp: UnitPoint(x: 0.604, y: 0.390),
            .home: UnitPoint(x: 0.406, y: 0.479),
            .volumeDown: UnitPoint(x: 0.604, y: 0.480),
            .menu: UnitPoint(x: 0.406, y: 0.569),
            .tv: UnitPoint(x: 0.604, y: 0.569),
        ]
        for placement in placements {
            let expected = expectedAnchors[placement.button]
            #expect(placement.anchor.x == expected?.x)
            #expect(placement.anchor.y == expected?.y)
            #expect((0...1).contains(placement.targetY))
        }

        let canvasWidth: CGFloat = 866
        let cardWidth: CGFloat = 250
        let leftEnd = RemoteMappingLayout.cardEdgePoint(
            side: .left,
            targetY: 0.5,
            canvasWidth: canvasWidth,
            cardWidth: cardWidth
        )
        let rightEnd = RemoteMappingLayout.cardEdgePoint(
            side: .right,
            targetY: 0.5,
            canvasWidth: canvasWidth,
            cardWidth: cardWidth
        )
        #expect(leftEnd == CGPoint(x: cardWidth, y: RemoteMappingLayout.canvasHeight / 2))
        #expect(rightEnd == CGPoint(x: canvasWidth - cardWidth, y: RemoteMappingLayout.canvasHeight / 2))
        #expect(RemoteMappingLayout.voiceAnchor == UnitPoint(x: 0.630, y: 0.099))
        #expect(RemoteMappingLayout.cardWidth(for: canvasWidth) == 300)

        let menuPlacement = try #require(placements.first { $0.button == .menu })
        let tvPlacement = try #require(placements.first { $0.button == .tv })
        let homePlacement = try #require(placements.first { $0.button == .home })
        let volumeDownPlacement = try #require(placements.first { $0.button == .volumeDown })
        #expect(menuPlacement.side == .left)
        #expect(tvPlacement.side == .right)
        #expect(homePlacement.side == .left)
        #expect(volumeDownPlacement.side == .right)

        for side in [RemoteMappingSide.left, .right] {
            let orderedAnchors = placements
                .filter { $0.side == side }
                .sorted { $0.targetY < $1.targetY }
                .map(\.anchor.y)
            #expect(zip(orderedAnchors, orderedAnchors.dropFirst()).allSatisfy { $0 <= $1 })
        }

        let start = CGPoint(x: canvasWidth / 2, y: 100)
        let leftEndPoint = CGPoint(x: 285, y: 160)
        let leftControls = RemoteMappingLayout.connectionControlPoints(
            start: start,
            end: leftEndPoint,
            side: .left
        )
        #expect(leftControls.start.x < start.x)
        #expect(leftControls.end.x > leftEndPoint.x)

        let rightEndPoint = CGPoint(x: canvasWidth - 285, y: 160)
        let rightControls = RemoteMappingLayout.connectionControlPoints(
            start: start,
            end: rightEndPoint,
            side: .right
        )
        #expect(rightControls.start.x > start.x)
        #expect(rightControls.end.x < rightEndPoint.x)

        #expect(RemoteMappingLayout.arrowTip(cardEdge: leftEndPoint, side: .left).x == leftEndPoint.x + 7)
        #expect(RemoteMappingLayout.arrowTip(cardEdge: rightEndPoint, side: .right).x == rightEndPoint.x - 7)
    }

    @Test func redesignedPagesKeepEveryExistingUserAction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let mappingCanvasSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMappingCanvas.swift"),
            encoding: .utf8
        )
        let bridgeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let source = settingsSource + mappingCanvasSource

        for requiredAction in [
            "model.reconnect()",
            "model.applyAudioSettings()",
            "model.refreshAudioDevices()",
            "model.sendTestTone()",
            "model.selectDoubaoAudioDevice()",
            "model.openDoubaoDriverInstructions(using: localization)",
            "model.setVoiceFnTapModeEnabled",
            "model.togglePhoneRemoteConnection()",
            "model.toggleWatchRemoteConnection()",
            "copyTestFlightPublicBetaLink()",
            "requestWebRemoteSession()",
            "settings.clearTrustedPhoneIdentities()",
            "settings.setAction(action, for: button, trigger: trigger)",
            "settings.setShortcut(",
            "chooseCustomApplication(for:",
            "recordCustomApplicationInput(profileID:",
            "settings.setApplicationProfileID(",
            ".openCustomApplication",
            "settings.resetBindings()",
        ] {
            #expect(source.contains(requiredAction), Comment(rawValue: requiredAction))
        }

        #expect(source.contains("AppLinks.testFlightPublicBeta"))
        let phoneEntry = try #require(source.range(of: "connection.phone.ios_title"))
        let watchEntry = try #require(source.range(of: "connection.watch.title"))
        let webEntry = try #require(source.range(
            of: "connection.web.title",
            range: watchEntry.upperBound..<source.endIndex
        ))
        #expect(phoneEntry.lowerBound < watchEntry.lowerBound)
        #expect(watchEntry.lowerBound < webEntry.lowerBound)
        let mobileEntrySource = source[phoneEntry.lowerBound..<webEntry.lowerBound]
        #expect(mobileEntrySource.contains("connection.phone.cancel_waiting"))
        #expect(mobileEntrySource.contains("connection.phone.connected"))
        #expect(mobileEntrySource.contains("connection.phone.disconnect"))
        #expect(mobileEntrySource.contains("connection.watch.cancel_waiting"))
        #expect(mobileEntrySource.contains("connection.watch.connected"))
        #expect(mobileEntrySource.contains("connection.watch.disconnect"))
        #expect(mobileEntrySource.contains("model.togglePhoneRemoteConnection()"))
        #expect(mobileEntrySource.contains("model.toggleWatchRemoteConnection()"))
        #expect(!mobileEntrySource.contains(".disabled(model.isPhoneRemoteConnectionEnabled)"))
        #expect(!mobileEntrySource.contains(".disabled(model.isWatchRemoteConnectionEnabled)"))
        #expect(!mobileEntrySource.contains(".foregroundStyle(.green)"))
        #expect(mobileEntrySource.contains("tint: model.isPhoneRemoteConnected"))
        #expect(mobileEntrySource.contains("tint: model.isWatchRemoteConnected"))
        #expect(mobileEntrySource.contains("? .green"))
        #expect(mobileEntrySource.contains("model.isPhoneRemoteConnectionEnabled ? .orange"))
        #expect(mobileEntrySource.contains("model.isWatchRemoteConnectionEnabled ? .orange"))
        #expect(bridgeSource.contains("@Published private(set) var isPhoneRemoteConnected = false"))
        #expect(bridgeSource.contains("@Published private(set) var isWatchRemoteConnected = false"))
        #expect(bridgeSource.contains("phoneRemoteServer.onConnectionStateChange"))
        #expect(bridgeSource.contains("watchBluetoothServer.onConnectionStateChange"))
        #expect(source.contains("ButtonTrigger.allCases"))
        #expect(source.contains("isMappingSelectionLocked"))
        #expect(!source.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(!source.contains("remoteDeviceBindingPanel"))
        #expect(!source.contains("SidebarGlassModifier"))
        #expect(source.contains(".focusEffectDisabled()"))
        #expect(source.contains(".frame(height: 56)"))
        #expect(source.contains(".ignoresSafeArea(.container, edges: .top)"))
        #expect(source.contains("showsAnchor: activeButtons.contains(placement.button)"))
        #expect(source.contains(".toggleStyle(.switch)"))
        #expect(source.contains("button_mapping.permission_prompt.open"))
        #expect(source.contains("button_mapping.selection_lock_hint_short"))
        #expect(source.contains("connection.voice_fn_tap.hint_short"))
        #expect(source.contains("ButtonActionCategory.allCases"))
        #expect(source.contains("LazyVGrid("))
        #expect(source.contains("button_mapping.action.disable_switch"))
        #expect(source.contains(").filter { $0 != .disabled }"))
        #expect(source.contains("DisclosureGroup(isExpanded: $isPresetApplicationActionsExpanded)"))
        #expect(source.contains("isPresetApplicationActionsExpanded = false"))
        #expect(source.contains("custom_application.accessibility.learn_help"))
        #expect(!source.contains(".popover(item: $mappingEditingTarget)"))
        #expect(!source.contains(".sheet(item: $shortcutEditingTarget)"))
        #expect(!source.contains("ApplicationShortcutEditorSheet"))
        #expect(source.contains("shortcut.editor.click_first_help"))
        #expect(source.contains("shortcut.editor.recording_prompt"))
        #expect(source.contains("shortcut.editor.success"))
        #expect(!source.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        #expect(!mappingCanvasSource.contains("size: 8"))
        #expect(!mappingCanvasSource.contains("size: 9"))
        #expect(!mappingCanvasSource.contains("size: 10"))
        #expect(!mappingCanvasSource.contains("size: 11"))
        #expect(!mappingCanvasSource.contains("minimumScaleFactor"))
        #expect(source.range(of: "MappingRemotePhoto()")!.lowerBound < source.range(of: "connectionLines(metrics: metrics)")!.lowerBound)

        let voiceFnToggle = "Toggle(\"connection.voice_fn_tap.enabled\""
        #expect(source.components(separatedBy: voiceFnToggle).count == 2)
        #expect(
            source.range(of: voiceFnToggle)!.lowerBound >
                source.range(of: "private var mappingPage")!.lowerBound
        )
    }

    /// Every boundary in the connection page's battery glyph: which icon bucket a level falls
    /// into, which tint it gets, and that the two change bucket at the same level.
    ///
    /// This replaces two assertions that `SettingsView.swift` still contained the source text
    /// of the `10` and `25` comparisons. Those passed with a comparison pointing either way and
    /// failed on a reformat, so an off-by-one at 10/11 or 25/26 — the only defect that can
    /// realistically appear in a threshold table — was invisible to them.
    @Test func remoteBatteryGlyphBucketsAndTintsAgreeAtEveryBoundary() {
        // Colour comparison has to be able to fail, or the tint half of this test is vacuous.
        #expect(Color.red != Color.orange)
        #expect(Color.red != Color.secondary)
        #expect(Color.orange != Color.secondary)

        let expected: [(level: Int?, symbol: String, tint: Color)] = [
            (nil, "battery.0percent", .secondary),
            (0, "battery.0percent", .red),
            (10, "battery.0percent", .red),
            (11, "battery.25percent", .orange),
            (25, "battery.25percent", .orange),
            (26, "battery.50percent", .secondary),
            (50, "battery.50percent", .secondary),
            (51, "battery.75percent", .secondary),
            (75, "battery.75percent", .secondary),
            (76, "battery.100percent", .secondary),
            (100, "battery.100percent", .secondary),
        ]

        for row in expected {
            let level = row.level.map { "\($0)" } ?? "nil"
            let symbol = RemoteBatteryPresentation.symbol(for: row.level)
            #expect(symbol == row.symbol, "level \(level) drew \(symbol)")
            #expect(
                RemoteBatteryPresentation.color(for: row.level) == row.tint,
                "level \(level) was tinted with the wrong colour"
            )
        }

        // Red and orange are warnings, so neither may leak past 25: 26 is an ordinary level.
        let tintAt26 = RemoteBatteryPresentation.color(for: 26)
        #expect(tintAt26 != .red)
        #expect(tintAt26 != .orange)

        // Stated as a property as well as a table, so no future edit can move one threshold
        // without the other: every level where the tint changes is also a level where the icon
        // bucket changes.
        let iconSteps = (1...100).filter {
            RemoteBatteryPresentation.symbol(for: $0)
                != RemoteBatteryPresentation.symbol(for: $0 - 1)
        }
        let tintSteps = (1...100).filter {
            RemoteBatteryPresentation.color(for: $0)
                != RemoteBatteryPresentation.color(for: $0 - 1)
        }
        #expect(iconSteps == [11, 26, 51, 76])
        #expect(tintSteps == [11, 26])
        #expect(Set(tintSteps).isSubset(of: Set(iconSteps)))
    }

    @Test func remoteCardsShowCompleteNamesWithoutDuplicateConnectionSummary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )

        #expect(chinese.contains(#""remote.device.model.rc001" = "小米蓝牙遥控器 2";"#))
        #expect(chinese.contains(#""remote.device.model.rc003" = "小米蓝牙遥控器 2 Pro";"#))
        #expect(english.contains(#""remote.device.model.rc001" = "Xiaomi Bluetooth Remote 2";"#))
        #expect(english.contains(#""remote.device.model.rc003" = "Xiaomi Bluetooth Remote 2 Pro";"#))

        let cardStart = try #require(settingsSource.range(of: "private func remoteDeviceCard"))
        let cardEnd = try #require(settingsSource.range(
            of: "private func remoteBatteryHelp",
            range: cardStart.upperBound..<settingsSource.endIndex
        ))
        let cardSource = settingsSource[cardStart.lowerBound..<cardEnd.lowerBound]
        #expect(cardSource.contains("ViewThatFits(in: .horizontal)"))
        #expect(cardSource.contains("fillsWidth ? nil : 232"))
        #expect(cardSource.contains("remoteBatteryLabel("))
        #expect(cardSource.contains("powerState: model.powerState(for: profile.id)"))
        #expect(cardSource.contains("Image(systemName: \"bolt.fill\")"))
        #expect(!cardSource.contains("Label(power.text"))
        #expect(!cardSource.contains("remote.device.power.rechargeable"))
        for symbol in [
            "battery.0percent",
            "battery.25percent",
            "battery.50percent",
            "battery.75percent",
            "battery.100percent",
        ] {
            #expect(settingsSource.contains(symbol))
        }

        let panelStart = try #require(settingsSource.range(of: "private var connectionDevicePanel"))
        let panelEnd = try #require(settingsSource.range(
            of: "private var mappingPage",
            range: panelStart.upperBound..<settingsSource.endIndex
        ))
        let panelSource = settingsSource[panelStart.lowerBound..<panelEnd.lowerBound]
        #expect(!panelSource.contains("Text(selectedRemoteDisplayName)"))
        #expect(!panelSource.contains("StatusPill(text: connectionBadge"))

        #expect(appSource.contains(
            "fileMenu.addItem(menuItem(\"menu.open_log_folder\", action: #selector(showLog)))"
        ))
    }

    @Test func aboutPageKeepsVersionFeaturesTogetherAndLanguagesVisible() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let aboutPage = try #require(source.components(separatedBy: "private var aboutPage").last)
        #expect(aboutPage.contains("updateInformationContent"))
        #expect(aboutPage.contains("about.version.history"))
        #expect(aboutPage.contains("about.version.check_prerelease"))
        #expect(aboutPage.contains("about.version.update_to"))
        #expect(aboutPage.contains("ForEach(AppLanguage.allCases)"))
        #expect(aboutPage.contains(".pickerStyle(.segmented)"))
        #expect(!aboutPage.contains("help.glossary.open"))
        #expect(!aboutPage.contains("openGlossary"))
    }

    @Test func privateFeatureUIIsDelegatedAndHiddenByDefault() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("privateFeature.isFeatureVisible"))
        #expect(source.contains("privateFeature.shouldShowEnrollment"))
        #expect(source.contains("privateFeature.settingsView()"))
        #expect(source.contains("privateFeature.enrollmentView()"))
        #expect(!source.contains("deepSeek"))
        #expect(!source.contains("postDictation"))

        let versionSummary = try #require(
            source.components(separatedBy: "Text(currentVersion)").last?
                .components(separatedBy: "if case let .available(update)").first
        )
        #expect(!versionSummary.contains(".onTapGesture"))
        #expect(!versionSummary.contains(".gesture"))
    }

    @Test func macroFeatureUIIsDelegatedWithoutPublishingItsImplementation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integration = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/MacroFeatureIntegration.swift"
            ),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(integration.contains("#if canImport(SayAllMacroRemoteMic)"))
        #expect(integration.contains("feature.executeBoundMacro"))
        #expect(integration.contains("feature.hasActiveBinding"))
        #expect(integration.contains("feature.noteButtonInteraction"))
        #expect(integration.contains("@Published private(set) var isEditorActive"))
        #expect(settings.contains("macroFeature.settingsView"))
        #expect(settings.contains("macroFeature.enrollmentView"))
        #expect(settings.contains("macroFeature.setEditorActive(selectedSection == .macros)"))
        #expect(model.contains("return (resolvedProfileID, !self.macroFeature.isEditorActive)"))
        #expect(model.contains("if macroFeature.isEditorActive"))
        #expect(!settings.contains("macro_buttons"))
        #expect(!settings.contains("EarlyAccessController"))
    }

    @Test func sidebarKeepsTheProductPriorityOrder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let orderStart = try #require(source.range(of: "private static let sidebarSectionOrder"))
        let listStart = try #require(source.range(
            of: "= [",
            range: orderStart.upperBound..<source.endIndex
        ))
        let orderEnd = try #require(source.range(
            of: "]",
            range: listStart.upperBound..<source.endIndex
        ))
        let orderSource = source[listStart.lowerBound...orderEnd.lowerBound]
        var cursor = orderSource.startIndex

        for section in [".mapping", ".macros", ".statistics", ".connection", ".permissions", ".about"] {
            let range = try #require(orderSource.range(
                of: section,
                range: cursor..<orderSource.endIndex
            ))
            cursor = range.upperBound
        }

        #expect(source.contains("Self.sidebarSectionOrder.filter"))
    }
}
