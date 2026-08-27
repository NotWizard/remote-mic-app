import Combine
import Foundation
import SayAllMacRemoteCore
import Testing
@testable import RemoteMic

/// Behaviour coverage for the main-actor isolation of `BridgeAppModel` (A8).
///
/// The model publishes 22 `@Published` properties that SwiftUI observes, and correctness used
/// to rest on hand-placed `DispatchQueue.main` hops at each callback entry point. One entry
/// point had none: `webRemoteClient.onStateChange` assigned `webRemoteState` on whatever
/// thread the relay delivered on.
///
/// Neither test below reads the source file. The first pins the runtime consequence of the
/// missing hop; the second pins the isolation that replaced the convention, by observing
/// which thread a published mutation actually executes on.
@Suite("Bridge model main-actor isolation")
struct BridgeAppModelIsolationTests {
    /// Counts `objectWillChange` emissions and records the thread each one arrived on.
    ///
    /// `@Published` sends `objectWillChange` synchronously from the mutating context, so the
    /// recorded thread is the thread that performed the mutation. `@unchecked Sendable` with a
    /// lock is deliberate: the whole point is to observe an emission that may arrive off the
    /// main thread when the isolation is missing.
    private final class PublishRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []

        func record(isMainThread: Bool) {
            lock.lock()
            threads.append(isMainThread)
            lock.unlock()
        }

        /// One entry per publish; `true` means it happened on the main thread.
        var mainThreadFlags: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return threads
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
        let name = "BridgeAppModelIsolationTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return SettingsScope(settings: AppSettings(defaults: defaults), defaults: defaults, name: name)
    }

    /// The regression test for the defect itself.
    ///
    /// `WebRemoteRelayClient.stop()` invokes `onStateChange` synchronously, on the calling
    /// thread — the same shape as the relay delivering a session state from its own transport
    /// queue. With the hop in place no publish may happen inside `disableWebRemoteConnection()`;
    /// it has to arrive on a later main-actor turn. Remove the hop and the second expectation
    /// fails, because the publish lands inside the call again.
    @MainActor
    @Test func webSessionStateFromTheTransportIsPublishedOnALaterMainActorTurn() async throws {
        let scope = try Self.scopedSettings("webState")
        defer { scope.tearDown() }
        let model = BridgeAppModel(settings: scope.settings, hidRuntimePermissions: { false })
        let recorder = PublishRecorder()
        let subscription = model.objectWillChange.sink { _ in
            recorder.record(isMainThread: Thread.isMainThread)
        }
        defer { subscription.cancel() }

        #expect(recorder.mainThreadFlags.isEmpty)

        model.disableWebRemoteConnection()

        // The transport callback already ran, inside the call above. If it published there,
        // the property was written from the delivering thread — the defect under test.
        #expect(recorder.mainThreadFlags.isEmpty)

        // The main queue is FIFO, so this block drains after the model's own hop.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(recorder.mainThreadFlags == [true])
        #expect(model.webRemoteState == .disabled)
    }

    /// The isolation itself, observed rather than asserted against source text.
    ///
    /// `selectDoubaoAudioDevice()` publishes `doubaoAudioStatus` when no compatible device is
    /// listed, which is always the case for a model that was never started. Reaching it from a
    /// detached task means the call starts off the main thread; while the model is main-actor
    /// isolated the `await` hops first, so the publish is recorded on the main thread. Remove
    /// the isolation and the same call runs on the detached task's thread, so the recorded flag
    /// flips to `false`.
    @Test func aPublishedMutationStartedOffTheMainThreadStillExecutesThere() async throws {
        let scope = try Self.scopedSettings("hop")
        defer { scope.tearDown() }
        let recorder = PublishRecorder()
        let model = await MainActor.run { BridgeAppModel(settings: scope.settings, hidRuntimePermissions: { false }) }
        let subscription = await MainActor.run {
            model.objectWillChange.sink { _ in
                recorder.record(isMainThread: Thread.isMainThread)
            }
        }
        defer { subscription.cancel() }

        await Task.detached {
            #expect(!Thread.isMainThread)
            await model.selectDoubaoAudioDevice()
        }.value

        #expect(recorder.mainThreadFlags == [true])
        let publishedKey = await MainActor.run { model.doubaoAudioStatus.key }
        #expect(publishedKey == "audio.compatibility.device_missing")
    }
}
