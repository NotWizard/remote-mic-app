import Foundation
import Testing
@testable import RemoteMic

// The upstream suite also drove WatchBluetoothRemoteServer's internal session state.
// That type now comes from the fork-local stub, so exercising it would assert against
// fake behavior. Only the wiring assertions below still mean something here; they
// catch an upstream merge silently dropping the watch voice path or its audio logging.
@Suite("Apple Watch voice wiring")
struct WatchBluetoothVoiceJourneyTests {
    @Test func bridgeRoutesWatchVoiceStartAndLogsAudio() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridgeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        #expect(bridgeSource.contains(
            "completion(self?.startPhoneVoice(source: .nearbyWatch) ?? .unavailable)"
        ))
        #expect(bridgeSource.contains("MOBILE VOICE audio source="))
        #expect(bridgeSource.contains("MOBILE VOICE audio_summary source="))
        #expect(bridgeSource.contains("accepted=\\(accepted)"))
    }
}
