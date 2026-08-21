import CoreAudio
import Testing
@testable import RemoteMic

@Suite("Virtual audio connection lifecycle")
struct VirtualAudioConnectionLifecycleTests {
    @Test func lastReadyBluetoothBridgeDisconnectsAndReleasesAudio() {
        #expect(!VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            mobileVoiceActive: false,
            testToneActive: false
        ))
    }

    @Test func anotherReadyBluetoothBridgeKeepsAudioActive() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 1,
            mobileVoiceActive: false,
            testToneActive: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 2,
            mobileVoiceActive: false,
            testToneActive: false
        ))
    }

    @Test func mobileVoiceOrTestToneKeepsAudioActiveWithoutBluetooth() {
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            mobileVoiceActive: true,
            testToneActive: false
        ))
        #expect(VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: 0,
            mobileVoiceActive: false,
            testToneActive: true
        ))
    }

    @Test func fallbackPrefersBuiltInInputAndExcludesVirtualDevice() {
        let virtual = AudioDeviceInfo(id: 1, uid: "virtual", name: "MiRemoteV 2ch")
        let usb = AudioDeviceInfo(id: 2, uid: "usb", name: "USB Microphone")
        let builtIn = AudioDeviceInfo(id: 3, uid: "built-in", name: "MacBook Microphone")

        let fallback = DefaultInputFallbackPolicy.preferredFallback(
            in: [virtual, usb, builtIn],
            excludingUID: virtual.uid,
            builtInDeviceIDs: [builtIn.id]
        )

        #expect(fallback == builtIn)
    }

    @Test func fallbackUsesAnotherInputWhenBuiltInInputIsUnavailable() {
        let virtual = AudioDeviceInfo(id: 1, uid: "virtual", name: "MiRemoteV 2ch")
        let usb = AudioDeviceInfo(id: 2, uid: "usb", name: "USB Microphone")

        let fallback = DefaultInputFallbackPolicy.preferredFallback(
            in: [virtual, usb],
            excludingUID: virtual.uid,
            builtInDeviceIDs: []
        )

        #expect(fallback == usb)
    }

    @Test func reconnectRestoresOnlyTheFallbackManagedByTheApp() {
        #expect(DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: "virtual",
            selectedVirtualUID: "virtual",
            managedFallbackUID: "built-in",
            currentDefaultUID: "built-in"
        ))
        #expect(!DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: "virtual",
            selectedVirtualUID: "virtual",
            managedFallbackUID: "built-in",
            currentDefaultUID: "usb-user-choice"
        ))
        #expect(!DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: "virtual",
            selectedVirtualUID: "another-virtual",
            managedFallbackUID: "built-in",
            currentDefaultUID: "built-in"
        ))
    }

    @Test func reconfiguringTheOutputMidDrainStillReportsTheDrainExactlyOnce() {
        let output = VirtualAudioOutput()
        output.registerPendingVoiceBuffer()
        var completionCount = 0
        // A long fallback keeps the audio side's own timer out of this test: the only way
        // the completion can arrive is through the interrupting path below.
        output.endSessionAfterDraining(maximumDelay: 60) { completionCount += 1 }
        #expect(completionCount == 0)

        output.endSession()

        #expect(completionCount == 1)
        #expect(output.pendingVoiceBufferCountForDiagnostics == 0)
        output.stop()
        #expect(completionCount == 1)
    }

    @Test func tearingTheEngineDownMidDrainStillReportsTheDrainExactlyOnce() {
        let output = VirtualAudioOutput()
        output.registerPendingVoiceBuffer()
        var completionCount = 0
        output.endSessionAfterDraining(maximumDelay: 60) { completionCount += 1 }

        output.stop()

        #expect(completionCount == 1)
        output.endSession()
        #expect(completionCount == 1)
    }

    @Test func aDrainCompletionThatTearsTheOutputDownAgainReportsOnlyOnce() {
        let output = VirtualAudioOutput()
        output.registerPendingVoiceBuffer()
        var completionCount = 0
        // Mirrors the release path, whose completion calls `stop()` on the same output.
        output.endSessionAfterDraining(maximumDelay: 60) { [weak output] in
            completionCount += 1
            output?.stop()
        }

        output.endSession()

        #expect(completionCount == 1)
    }

    @Test func aSecondDrainRequestDoesNotStrandTheFirstWaiter() {
        let output = VirtualAudioOutput()
        output.registerPendingVoiceBuffer()
        var firstCount = 0
        var secondCount = 0
        output.endSessionAfterDraining(maximumDelay: 60) { firstCount += 1 }

        output.endSessionAfterDraining(maximumDelay: 60) { secondCount += 1 }

        #expect(firstCount == 1)
        #expect(secondCount == 0)
        output.endSession()
        #expect(firstCount == 1)
        #expect(secondCount == 1)
    }
}
