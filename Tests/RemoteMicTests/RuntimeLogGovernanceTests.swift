import Foundation
import Testing
@testable import RemoteMic

/// Behaviour coverage for the runtime log governance work (A3).
///
/// A resident install grew `~/Library/Logs/RemoteMic/runtime.log` to 21.5 MB / 113k lines
/// in 11 days: one no-op `AUDIO RELEASE completed` diagnostic accounted for 42% of the
/// bytes, the file was world readable, it never rotated, and every line reopened the file.
/// These tests drive the real logger against real files and the real
/// `BridgeAppModel` release path rather than inspecting source text.
@Suite("Runtime log governance")
struct RuntimeLogGovernanceTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeLogGovernanceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func lines(of url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func permissions(of url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: - 1. @autoclosure laziness

    @Test func foldedRepeatsNeverEvaluateTheExpensiveMessageExpression() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AppLogger(directory: directory, foldWindow: 60)

        // Stands in for the CoreAudio/CoreBluetooth property reads that make some log
        // interpolations expensive.
        final class Probe {
            private(set) var evaluations = 0
            func deviceName() -> String {
                evaluations += 1
                return "小米蓝牙语音遥控器"
            }
        }
        let probe = Probe()

        // A declared key skips the fold decision ahead of the interpolation. It has to be
        // the complete message text, which is exactly what makes it safe.
        for _ in 0 ..< 50 {
            logger.write(
                "BLE CONNECTING source=target_identifier name=\(probe.deviceName())",
                foldKey: "BLE CONNECTING source=target_identifier name=小米蓝牙语音遥控器"
            )
        }
        logger.flush()

        // Only the line that was actually written paid for the interpolation.
        #expect(probe.evaluations == 1)
        #expect(try lines(of: logger.logURL).count == 1)
    }

    @Test func aSuppressedWriteStillBuildsItsMessageWhenNoFoldKeyIsDeclared() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AppLogger(directory: directory, foldWindow: 60)

        var sideEffects = 0
        func expensive() -> String {
            sideEffects += 1
            return "target_identifier"
        }

        // Without a declared key the message must be built before the fold decision can
        // be taken at all, so the saving is the 19 disk writes, not the interpolation.
        // Recording that boundary keeps the distinction honest.
        for _ in 0 ..< 20 {
            logger.write("BLE CONNECTING source=\(expensive()) name=Remote")
        }
        logger.flush()

        #expect(sideEffects == 20)
        #expect(try lines(of: logger.logURL).count == 1)
    }

    // MARK: - 2. Rotation

    @Test func oversizedLogRotatesKeepsABoundedHistoryAndStaysWritable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limit: UInt64 = 1024
        let logger = AppLogger(
            directory: directory,
            maximumFileSize: limit,
            maximumArchiveCount: 2,
            foldWindow: 60
        )
        let padding = String(repeating: "x", count: 100)

        // Distinct fold keys, so nothing is collapsed and the size cap is what rotates.
        for index in 0 ..< 80 {
            logger.write("ROTATION index=\(index) payload=\(padding)")
        }
        logger.flush()

        let current = logger.logURL
        let archiveOne = current.appendingPathExtension("1")
        let archiveTwo = current.appendingPathExtension("2")
        let archiveThree = current.appendingPathExtension("3")

        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: archiveOne.path))
        #expect(FileManager.default.fileExists(atPath: archiveTwo.path))
        // Retention is bounded: the third archive is never created.
        #expect(!FileManager.default.fileExists(atPath: archiveThree.path))

        for url in [current, archiveOne, archiveTwo] {
            let size = try #require(
                (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
            )
            #expect(size <= limit)
        }

        // The live file survives rotation and still accepts writes.
        logger.write("ROTATION marker=still-writable")
        logger.flush()
        let tail = try lines(of: current)
        #expect(tail.contains { $0.contains("ROTATION marker=still-writable") })
        #expect(try permissions(of: current) == 0o600)
    }

    // MARK: - 3. Permissions

    @Test func logFilesAreCreatedPrivateToTheUser() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AppLogger(directory: directory)

        logger.write("PERMISSION probe=fresh")
        logger.flush()

        #expect(FileManager.default.fileExists(atPath: logger.logURL.path))
        // The log records target bundle identifiers and audio device names, so the old
        // world-readable 0644 default is not acceptable.
        #expect(try permissions(of: logger.logURL) == 0o600)
    }

    @Test func anAlreadyWorldReadableLogIsTightenedOnFirstWrite() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AppLogger(directory: directory)
        FileManager.default.createFile(
            atPath: logger.logURL.path,
            contents: Data("legacy line\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o644))]
        )
        #expect(try permissions(of: logger.logURL) == 0o644)

        logger.write("PERMISSION probe=upgrade")
        logger.flush()

        #expect(try permissions(of: logger.logURL) == 0o600)
        // Tightening must not discard history already on disk.
        #expect(try lines(of: logger.logURL).contains("legacy line"))
    }

    // MARK: - 4. Folding

    @Test func repeatedMessagesCollapseIntoOneLineCarryingTheSuppressedCount() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let window: TimeInterval = 0.2
        let logger = AppLogger(directory: directory, foldWindow: window)

        // The real bluetooth retry loop renders this exact text on every attempt: 21671
        // byte-identical copies in the field log.
        let attempt = "BLE CONNECTING source=target_identifier name=小米蓝牙语音遥控器"
        for _ in 0 ..< 200 {
            logger.write(attempt)
        }
        Thread.sleep(forTimeInterval: window * 1.5)
        logger.write(attempt)
        logger.flush()

        let written = try lines(of: logger.logURL)
        // 201 calls, 2 lines on disk: the first of the window plus the one that closes it.
        #expect(written.count == 2)
        #expect(written[1].contains("folded_repeats=199"))
        // The first line is never delayed, so a brand new event is still visible at once.
        #expect(written[0].hasSuffix(attempt))
    }

    @Test func aKeyThatGoesQuietStillReportsItsSuppressedCount() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let window: TimeInterval = 0.2
        let logger = AppLogger(directory: directory, foldWindow: window)

        for _ in 0 ..< 6 {
            logger.write("BLE CONNECT TIMEOUT")
        }
        Thread.sleep(forTimeInterval: window * 1.5)
        // A different message: the quiet key must still be flushed rather than lost.
        logger.write("BLE DISCONNECTED reason=user")
        logger.flush()

        let written = try lines(of: logger.logURL)
        #expect(written.count == 3)
        #expect(written.contains { $0.contains("LOG FOLD flushed key={BLE CONNECT TIMEOUT} folded_repeats=5") })
        #expect(written.contains { $0.contains("BLE DISCONNECTED reason=user") })
    }

    /// The messages an earlier heuristic ("key = tokens up to the first token containing
    /// `=`") merged on the real field log. Replaying that rule suppressed 78165 lines and
    /// 1586 of them differed from the line it kept, always after the first `=`. Every
    /// entry below is a verbatim pair from that log: same first assignment token, genuinely
    /// different diagnosis.
    private static let fieldMessagesSharingTheirFirstAssignment: [String] = [
        // 802 field lines. Only the target/previous device identity differs.
        "AUDIO CONFIGURE begin target={name=MiRemoteV 2ch id=88} previous={engine_running=false selected={none} actual_output={none} bound_to_selected=unknown default_input={name=MacBook Pro麦克风 id=83}}",
        "AUDIO CONFIGURE begin target={name=MiRemoteV 2ch id=103} previous={engine_running=true selected={name=MiRemoteV 2ch id=103} actual_output={name=外置耳机 id=434} bound_to_selected=false default_input={name=MiRemoteV 2ch id=103}}",
        // 164 field lines. The routing intent is the whole point of the line.
        "VOICE DESTINATION pending request=1 intent=application:com.example.target",
        "VOICE DESTINATION pending request=1 intent=shortcut",
        // 88 field lines. `bound_to_selected=false` is the discriminating fact and it sits
        // deep inside the state dump.
        "AUDIO REBIND begin reason=recovery_hardware_change state={engine_running=true selected={name=MiRemoteV 2ch id=103} actual_output={name=MiRemoteV 2ch id=103} bound_to_selected=true default_input={name=MiRemoteV 2ch id=103}}",
        "AUDIO REBIND begin reason=recovery_hardware_change state={engine_running=true selected={name=MiRemoteV 2ch id=103} actual_output={name=MacBook Pro扬声器 id=91} bound_to_selected=false default_input={name=MiRemoteV 2ch id=103}}",
        // 52 field lines. Everything after `applied=true` is what differs.
        "VOICE FN MAPPING applied=true neutralized=true power_suppressed=true suppression_scope=locations=1 matched=1 applied=1",
        "VOICE FN MAPPING applied=true neutralized=false power_suppressed=false suppression_scope=none matched=1 applied=1",
        // 42 field lines.
        "VOICE FN MAPPING rollback matched=2 applied=1 restored=1",
        "VOICE FN MAPPING rollback matched=2 applied=1 restored=0",
        // 46 field lines. Two different focus failures for one bundle.
        "APP FOCUS failed bundle=com.cmuxterm.app method=cmux_api reason=no_current_terminal",
        "APP FOCUS failed bundle=com.cmuxterm.app method=cmux_api reason=current_timeout",
        // 41 field lines. Same reason, different machine audio route.
        "AUDIO RELEASE completed reason=bluetooth_not_ready state={engine_running=false selected={none} default_input={name=MacBook Pro麦克风 id=83} default_output={name=MacBook Pro扬声器 id=76}}",
        "AUDIO RELEASE completed reason=bluetooth_not_ready state={engine_running=false selected={none} default_input={name=DJI Mic Mini-xx id=2021} default_output={name=DJI Mic Mini-xx id=2014}}",
    ]

    @Test func messagesThatDifferOnlyAfterTheFirstAssignmentAreEachWrittenInFull() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // One window covers the whole test, so anything that folds folds here.
        let logger = AppLogger(directory: directory, foldWindow: 60)

        let samples = Self.fieldMessagesSharingTheirFirstAssignment
        // Interleaved and repeated, the way the field log produced them: a rule that keys
        // on anything less than the full message collapses each pair onto its first half.
        for round in 0 ..< 3 {
            for message in (round.isMultiple(of: 2) ? samples : samples.reversed()) {
                logger.write(message)
            }
        }
        logger.flush()

        let written = try lines(of: logger.logURL)
        // Nothing here is opted in, so every single call is on disk.
        #expect(written.count == samples.count * 3)
        for message in samples {
            #expect(
                written.contains { $0.hasSuffix(message) },
                "\(message) never reached the log verbatim"
            )
        }
        // No line may be a prefix-merge of a sibling: no `folded_repeats` annotation and
        // no fold summary may appear for any of these classes.
        #expect(!written.contains { $0.contains("folded_repeats=") })
        #expect(!written.contains { $0.contains("LOG FOLD flushed") })
    }

    @Test func messagesOutsideTheFoldWhitelistAreNeverCollapsed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AppLogger(directory: directory, foldWindow: 60)

        // Byte-identical repeats of a message that is *not* opted in still land one per
        // call: the fold is opt-in, so silence is never the default.
        for _ in 0 ..< 50 {
            logger.write("AUDIO RELEASE completed reason=bluetooth_not_ready state={engine_running=false}")
        }
        // Same for a caller that names a fold key for a non-whitelisted class, which is
        // what the production release path does.
        for _ in 0 ..< 50 {
            logger.write(
                "AUDIO RELEASE skipped reason=bluetooth_not_ready still_required=true",
                foldKey: "AUDIO RELEASE skipped reason=bluetooth_not_ready"
            )
        }
        // Contrast: the one class that *is* opted in collapses.
        for _ in 0 ..< 50 {
            logger.write("BLE CONNECT TIMEOUT")
        }
        logger.flush()

        let written = try lines(of: logger.logURL)
        #expect(written.filter { $0.contains("AUDIO RELEASE completed") }.count == 50)
        #expect(written.filter { $0.contains("AUDIO RELEASE skipped") }.count == 50)
        #expect(written.filter { $0.contains("BLE CONNECT TIMEOUT") }.count == 1)
    }

    @Test func aDeclaredFoldKeyThatDoesNotDescribeItsMessageCannotMergeLines() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AppLogger(directory: directory, foldWindow: 60)

        // A whitelisted prefix, but the key omits `name=`. Honouring it would merge two
        // different remotes into one line, so the key is discarded instead.
        for name in ["小米蓝牙语音遥控器", "MI RC", "小米蓝牙语音遥控器", "MI RC"] {
            logger.write(
                "BLE CONNECTING source=target_identifier name=\(name)",
                foldKey: "BLE CONNECTING source=target_identifier"
            )
        }
        logger.flush()

        let written = try lines(of: logger.logURL)
        // Each distinct message is emitted the first time it is seen; the second copy of
        // each folds on its own full text, and no line is lost to the bad key.
        #expect(written.count == 2)
        #expect(written.contains { $0.hasSuffix("name=小米蓝牙语音遥控器") })
        #expect(written.contains { $0.hasSuffix("name=MI RC") })
    }

    @Test func onlyWhitelistedMessagesGetAFoldKeyAndTheKeyIsTheWholeMessage() {
        // Opted in: the key is the entire message, so equal keys mean equal bytes.
        #expect(
            LogFold.foldKey(for: "BLE CONNECTING source=target_identifier name=Remote")
                == "BLE CONNECTING source=target_identifier name=Remote"
        )
        #expect(LogFold.foldKey(for: "BLE CONNECT TIMEOUT") == "BLE CONNECT TIMEOUT")
        #expect(LogFold.foldKey(for: "BLE SCANNING") == "BLE SCANNING")

        // Not opted in: no key, therefore no fold, whatever the shape of the message.
        #expect(LogFold.foldKey(for: "AUDIO RELEASE completed reason=bluetooth_not_ready state={a=1}") == nil)
        #expect(LogFold.foldKey(for: "AUDIO CONFIGURE begin target={name=MiRemoteV 2ch id=88}") == nil)
        #expect(LogFold.foldKey(for: "VOICE DESTINATION pending request=1 intent=shortcut") == nil)
        #expect(LogFold.foldKey(for: "BLE DISCONNECTED reason=user") == nil)

        // A key can never be a truncation, because truncation is what would let two long
        // messages that share a prefix collide.
        let overlong = "BLE CONNECTING source=target_identifier name=" +
            String(repeating: "x", count: LogFold.keyScanLimit)
        #expect(LogFold.foldKey(for: overlong) == nil)
        for prefix in LogFold.foldableMessagePrefixes {
            #expect(prefix.count <= LogFold.keyScanLimit)
        }
    }

    // MARK: - 5. Idempotence gate

    @MainActor
    @Test func releasingAnAlreadyReleasedOutputEmitsNoDiagnosticLine() throws {
        let suiteName = "RuntimeLogGovernanceTests.gate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.selectedAudioDeviceUID.isEmpty)

        let model = BridgeAppModel(settings: settings)
        let firstReason = "gate_probe_first_\(UUID().uuidString)"
        let secondReason = "gate_probe_second_\(UUID().uuidString)"

        // Unique reasons keep the assertion immune to lines other suites write through
        // the shared logger.
        final class Sink {
            private let lock = NSLock()
            private var storage: [String] = []
            func record(_ line: String) {
                lock.lock(); storage.append(line); lock.unlock()
            }
            var lines: [String] {
                lock.lock(); defer { lock.unlock() }; return storage
            }
        }
        let sink = Sink()
        let token = AppLogger.shared.addWriteObserver { sink.record($0) }
        defer { AppLogger.shared.removeWriteObserver(token) }

        // First transition: nothing is bound yet, but the published state has not been
        // normalised either, so the real teardown runs and reports itself.
        model.applyAudioSettings(reason: firstReason)
        AppLogger.shared.flush()
        #expect(sink.lines.contains { $0.contains("AUDIO RELEASE completed reason=\(firstReason)") })

        // Second transition with nothing left to release: the bluetooth reconnect loop
        // drives two of these per attempt, and neither may reach the log.
        model.applyAudioSettings(reason: secondReason)
        AppLogger.shared.flush()
        #expect(!sink.lines.contains { $0.contains(secondReason) })
    }

    @Test func theGateRefusesToSkipWhileAnythingStillNeedsCleanup() {
        let allDone = VirtualAudioReleaseGate.hasNothingToRelease(
            engineHoldsDevice: false,
            pendingVoiceBufferCount: 0,
            publishedAudioReady: false,
            publishedStatusAlreadyReleased: true,
            defaultInputFallbackWouldRun: { false }
        )
        #expect(allDone)

        // A live engine, queued audio, stale published state or a pending default-input
        // fallback each force the full teardown.
        #expect(!VirtualAudioReleaseGate.hasNothingToRelease(
            engineHoldsDevice: true,
            pendingVoiceBufferCount: 0,
            publishedAudioReady: false,
            publishedStatusAlreadyReleased: true,
            defaultInputFallbackWouldRun: { false }
        ))
        #expect(!VirtualAudioReleaseGate.hasNothingToRelease(
            engineHoldsDevice: false,
            pendingVoiceBufferCount: 3,
            publishedAudioReady: false,
            publishedStatusAlreadyReleased: true,
            defaultInputFallbackWouldRun: { false }
        ))
        #expect(!VirtualAudioReleaseGate.hasNothingToRelease(
            engineHoldsDevice: false,
            pendingVoiceBufferCount: 0,
            publishedAudioReady: true,
            publishedStatusAlreadyReleased: true,
            defaultInputFallbackWouldRun: { false }
        ))
        #expect(!VirtualAudioReleaseGate.hasNothingToRelease(
            engineHoldsDevice: false,
            pendingVoiceBufferCount: 0,
            publishedAudioReady: false,
            publishedStatusAlreadyReleased: false,
            defaultInputFallbackWouldRun: { false }
        ))
        #expect(!VirtualAudioReleaseGate.hasNothingToRelease(
            engineHoldsDevice: false,
            pendingVoiceBufferCount: 0,
            publishedAudioReady: false,
            publishedStatusAlreadyReleased: true,
            defaultInputFallbackWouldRun: { true }
        ))
    }

    @Test func theDefaultInputProbeIsOnlyConsultedWhenTheCheapFactsAlreadyHold() {
        var probeCalls = 0
        _ = VirtualAudioReleaseGate.hasNothingToRelease(
            engineHoldsDevice: true,
            pendingVoiceBufferCount: 0,
            publishedAudioReady: false,
            publishedStatusAlreadyReleased: true,
            defaultInputFallbackWouldRun: { probeCalls += 1; return false }
        )
        // The probe performs a CoreAudio property read; a live engine short-circuits it.
        #expect(probeCalls == 0)

        _ = VirtualAudioReleaseGate.hasNothingToRelease(
            engineHoldsDevice: false,
            pendingVoiceBufferCount: 0,
            publishedAudioReady: false,
            publishedStatusAlreadyReleased: true,
            defaultInputFallbackWouldRun: { probeCalls += 1; return false }
        )
        #expect(probeCalls == 1)
    }
}
