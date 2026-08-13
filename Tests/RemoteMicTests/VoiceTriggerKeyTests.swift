import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice trigger key")
struct VoiceTriggerKeyTests {
    @Test func fnMatchesTheHistoricalHardwareAndInjectionConstants() {
        #expect(VoiceTriggerKey.fn.hidDestinationUsage == 0x0000_00FF_0000_0003)
        #expect(VoiceTriggerKey.fn.injectionKeyCode == 63)
        #expect(VoiceTriggerKey.fn.injectionFlags == .maskSecondaryFn)
    }

    @Test func rightModifiersUseStandardUsagesKeyCodesAndFlags() {
        #expect(VoiceTriggerKey.rightCommand.hidDestinationUsage == 0x0000_0007_0000_00E7)
        #expect(VoiceTriggerKey.rightCommand.injectionKeyCode == 54)
        #expect(VoiceTriggerKey.rightCommand.injectionFlags == .maskCommand)

        #expect(VoiceTriggerKey.rightOption.hidDestinationUsage == 0x0000_0007_0000_00E6)
        #expect(VoiceTriggerKey.rightOption.injectionKeyCode == 61)
        #expect(VoiceTriggerKey.rightOption.injectionFlags == .maskAlternate)

        #expect(VoiceTriggerKey.rightShift.hidDestinationUsage == 0x0000_0007_0000_00E5)
        #expect(VoiceTriggerKey.rightShift.injectionKeyCode == 60)
        #expect(VoiceTriggerKey.rightShift.injectionFlags == .maskShift)
    }

    @Test func roundTripsThroughRawValueAndHasTitleKeys() {
        for trigger in VoiceTriggerKey.allCases {
            #expect(VoiceTriggerKey(rawValue: trigger.rawValue) == trigger)
            #expect(!trigger.titleKey.isEmpty)
        }
    }

    @Test func setFunctionKeyPressedInjectsTheSelectedTriggerKeyCodeAndFlags() {
        var posted: [(CGKeyCode, Bool, CGEventFlags)] = []
        let poster: KeyboardInjector.KeyStatePoster = { code, isDown, flags in
            posted.append((code, isDown, flags))
            return true
        }

        _ = KeyboardInjector.setFunctionKeyPressed(
            true,
            trigger: .rightOption,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        )
        _ = KeyboardInjector.setFunctionKeyPressed(
            false,
            trigger: .rightOption,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        )

        #expect(posted.count == 2)
        #expect(posted[0].0 == 61)
        #expect(posted[0].1 == true)
        #expect(posted[0].2 == .maskAlternate)
        #expect(posted[1].0 == 61)
        #expect(posted[1].1 == false)
        #expect(posted[1].2 == [])
    }

    @Test func exportImportRoundTripsTheSelectedTrigger() throws {
        let exportSuite = "RemoteMicTests.VoiceTrigger.export.\(UUID().uuidString)"
        let importSuite = "RemoteMicTests.VoiceTrigger.import.\(UUID().uuidString)"
        let exportDefaults = try #require(UserDefaults(suiteName: exportSuite))
        let importDefaults = try #require(UserDefaults(suiteName: importSuite))
        defer {
            exportDefaults.removePersistentDomain(forName: exportSuite)
            importDefaults.removePersistentDomain(forName: importSuite)
        }

        let source = AppSettings(defaults: exportDefaults)
        #expect(source.voiceTriggerKey == .fn)
        source.voiceTriggerKey = .rightCommand
        let data = try source.exportedConfigurationData()

        let destination = AppSettings(defaults: importDefaults)
        try destination.importConfiguration(from: data)
        #expect(destination.voiceTriggerKey == .rightCommand)
    }

    @Test func fnTapInjectionOnlyWhenUsingRemoteMicrophone() {
        #expect(VoiceKeyModePolicy.usesFnTapInjection(fnTapEnabled: true, usesRemoteMicrophone: true))
        #expect(!VoiceKeyModePolicy.usesFnTapInjection(fnTapEnabled: true, usesRemoteMicrophone: false))
        #expect(!VoiceKeyModePolicy.usesFnTapInjection(fnTapEnabled: false, usesRemoteMicrophone: true))
        #expect(!VoiceKeyModePolicy.usesFnTapInjection(fnTapEnabled: false, usesRemoteMicrophone: false))
    }

    @Test func voiceKeyUsesRemoteMicrophoneDefaultsOnAndRoundTrips() throws {
        let exportSuite = "RemoteMicTests.VoiceMic.export.\(UUID().uuidString)"
        let importSuite = "RemoteMicTests.VoiceMic.import.\(UUID().uuidString)"
        let exportDefaults = try #require(UserDefaults(suiteName: exportSuite))
        let importDefaults = try #require(UserDefaults(suiteName: importSuite))
        defer {
            exportDefaults.removePersistentDomain(forName: exportSuite)
            importDefaults.removePersistentDomain(forName: importSuite)
        }

        let source = AppSettings(defaults: exportDefaults)
        #expect(source.voiceKeyUsesRemoteMicrophone)
        source.voiceKeyUsesRemoteMicrophone = false
        let data = try source.exportedConfigurationData()

        let destination = AppSettings(defaults: importDefaults)
        try destination.importConfiguration(from: data)
        #expect(!destination.voiceKeyUsesRemoteMicrophone)
    }
}
