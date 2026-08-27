import Foundation
import SayAllMacRemoteCore
import Testing
@testable import RemoteMic

// The upstream suite also drove WatchBluetoothRemoteServer's internal session state. That
// type now comes from the fork-local stub, so exercising it would assert against fake
// behaviour. What is still real on this side of the boundary is what `BridgeAppModel` does
// with a watch voice session, and that is what this suite now drives.
@Suite("Apple Watch voice wiring")
struct WatchBluetoothVoiceJourneyTests {
    /// Records every line the shared logger actually writes. `AppLogger` notifies observers
    /// synchronously from the writing thread, so the lock is required.
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

    /// The watch can hold the voice channel, and while it does the iPhone is the one refused.
    ///
    /// This replaces four substring assertions on `BridgeAppModel.swift`: that the file
    /// contained `completion(self?.startPhoneVoice(source: .nearbyWatch) ?? .unavailable)`,
    /// `MOBILE VOICE audio source=`, `MOBILE VOICE audio_summary source=` and
    /// `accepted=\(accepted)`. Those asserted the spelling of a callback body and of three
    /// log format strings; none of them would notice the watch losing the channel.
    ///
    /// Deliberately the mirror image of
    /// `SettingsPageRegressionTests.oneMobileVoiceSourceOwnsTheChannelAndTheOthersAreRefused`,
    /// which has the iPhone holding it. Between them, an implementation that hard-codes one
    /// winner fails one of the two.
    ///
    /// `startPhoneVoice` is only called with the channel already held: the busy arbitration
    /// is its first gate, so a refused request touches no hardware, whereas an admitted one
    /// would bind the virtual audio device and latch a real modifier key.
    @MainActor
    @Test func watchVoiceHoldsTheChannelAndItsAudioIsAccountedFor() throws {
        let suiteName = "WatchBluetoothVoiceJourneyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = BridgeAppModel(settings: AppSettings(defaults: defaults), hidRuntimePermissions: { false })
        let sink = LogSink()
        let token = AppLogger.shared.addWriteObserver { sink.record($0) }
        defer { AppLogger.shared.removeWriteObserver(token) }

        // The watch holds the channel.
        model.activeMobileVoiceSource = .nearbyWatch

        // Now it is the iPhone that is refused, and it does not take the channel over.
        #expect(model.startPhoneVoice(source: .nearbyPhone) == .busy)
        #expect(model.activeMobileVoiceSource == .nearbyWatch)
        AppLogger.shared.flush()
        #expect(sink.count(
            of: "MOBILE VOICE start_rejected reason=busy requested=iphone active=watch"
        ) == 1)

        // The watch's own audio is accepted and accounted for sample by sample. There is no
        // audio device in a test process, so the write is reported as rejected rather than
        // played — that accounting is exactly what the old `accepted=\(accepted)` assertion
        // only checked the spelling of.
        model.receivePhoneAudio([100, -100, 0, 5], source: .nearbyWatch)
        AppLogger.shared.flush()
        #expect(sink.lines.contains {
            $0.contains("MOBILE VOICE audio source=watch batches=1 samples=4 nonzero=3")
                && $0.contains("accepted=false enqueue_failures=1")
        })

        // iPhone audio arriving while the watch holds the channel is dropped, not mixed in.
        model.receivePhoneAudio([1], source: .nearbyPhone)
        AppLogger.shared.flush()
        #expect(sink.count(
            of: "MOBILE VOICE audio_dropped reason=source_mismatch requested=iphone " +
                "active=watch count=1"
        ) == 1)
        #expect(sink.count(of: "MOBILE VOICE audio source=iphone") == 0)

        // Only the watch can end the watch's session.
        model.stopPhoneVoice(source: .nearbyPhone)
        #expect(model.activeMobileVoiceSource == .nearbyWatch)
        AppLogger.shared.flush()
        #expect(sink.count(of: "MOBILE VOICE stop_ignored requested=iphone active=watch") == 1)
        #expect(sink.count(of: "MOBILE VOICE stopped source=watch") == 0)

        // Positive control: its own stop releases the channel and closes the account.
        model.stopPhoneVoice(source: .nearbyWatch)
        AppLogger.shared.flush()
        #expect(model.activeMobileVoiceSource == nil)
        #expect(sink.count(of: "MOBILE VOICE stopped source=watch") == 1)
        #expect(sink.lines.contains {
            $0.contains("MOBILE VOICE audio_summary source=watch reason=voice_stop")
                && $0.contains("batches=1")
                && $0.contains("samples=4")
                && $0.contains("source_mismatches=1")
        })
    }
}
