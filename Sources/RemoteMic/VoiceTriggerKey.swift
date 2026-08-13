import CoreGraphics

/// The key the RC003 voice button emits while held, to trigger a dictation tool.
/// The audio itself always streams over BLE to the virtual mic; this only picks
/// the *signal* key. `.fn` reproduces the historical hard-coded behavior exactly.
enum VoiceTriggerKey: String, CaseIterable, Codable {
    case fn
    case rightCommand
    case rightOption
    case rightShift

    /// IOKit `UserKeyMapping` destination usage (path A: hardware remap of F5).
    /// High 16 bits = HID usage page, low bits = usage.
    var hidDestinationUsage: UInt64 {
        switch self {
        case .fn: return 0x0000_00FF_0000_0003 // Apple vendor top-case Fn/Globe
        case .rightCommand: return 0x0000_0007_0000_00E7 // Keyboard Right GUI
        case .rightOption: return 0x0000_0007_0000_00E6 // Keyboard Right Alt
        case .rightShift: return 0x0000_0007_0000_00E5 // Keyboard Right Shift
        }
    }

    /// Virtual key code for CGEvent injection (path B: tap/hold injection).
    var injectionKeyCode: CGKeyCode {
        switch self {
        case .fn: return 63 // kVK_Function
        case .rightCommand: return 54 // kVK_RightCommand
        case .rightOption: return 61 // kVK_RightOption
        case .rightShift: return 60 // kVK_RightShift
        }
    }

    /// Modifier flag paired with the injected key-down.
    var injectionFlags: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .rightShift: return .maskShift
        }
    }

    /// Localization key for the segmented selector label.
    var titleKey: String {
        switch self {
        case .fn: return "button_mapping.voice_trigger.fn"
        case .rightCommand: return "button_mapping.voice_trigger.right_command"
        case .rightOption: return "button_mapping.voice_trigger.right_option"
        case .rightShift: return "button_mapping.voice_trigger.right_shift"
        }
    }

    /// Right-side modifiers are real modifiers; Fn is the Apple Globe/Fn usage.
    var isModifier: Bool { self != .fn }
}

enum VoiceKeyModePolicy {
    /// Right-side modifier triggers are emitted by software injection tied to the
    /// ATVV stream (down on start, up on stop), never by a hardware key remap: a
    /// remapped modifier that misses a key-up gets stuck (a stuck Command toggles
    /// VoiceOver via Command-F5, makes the system laggy, and never cleanly releases).
    static func usesModifierHoldInjection(trigger: VoiceTriggerKey) -> Bool {
        trigger.isModifier
    }

    /// Fn-tap (Typeless) injection is driven by the remote's audio draining, so it
    /// only applies to the Fn trigger while streaming the remote microphone.
    static func usesFnTapInjection(
        fnTapEnabled: Bool,
        usesRemoteMicrophone: Bool,
        trigger: VoiceTriggerKey
    ) -> Bool {
        fnTapEnabled && usesRemoteMicrophone && !trigger.isModifier
    }

    /// The hardware F5 key must be neutralized (F5→0) whenever the trigger is
    /// emitted by injection instead of a hardware remap.
    static func neutralizesHardwareVoiceKey(
        fnTapEnabled: Bool,
        usesRemoteMicrophone: Bool,
        trigger: VoiceTriggerKey
    ) -> Bool {
        usesModifierHoldInjection(trigger: trigger)
            || usesFnTapInjection(
                fnTapEnabled: fnTapEnabled,
                usesRemoteMicrophone: usesRemoteMicrophone,
                trigger: trigger
            )
    }
}
