import CoreGraphics
import SwiftUI

/// Single source of truth for interface text sizes.
///
/// `AGENTS.md` forbids Chinese interface text from rendering below 12pt, and forbids
/// using `minimumScaleFactor` to shrink it under that floor. The macOS semantic styles
/// cannot satisfy the rule: `.caption`, `.caption2` and `.footnote` resolve to 10pt and
/// `.subheadline` to 11pt. Repeating `.system(size: 12)` at every call site does satisfy
/// it, but only until the next edit, because nothing checks the literals.
///
/// So views name a token from this table instead of naming a semantic style or repeating
/// a size. The floor is then a property of six values that `InterfaceTypographyTests`
/// checks once, rather than something a reviewer has to re-read at fifty-odd call sites.
enum InterfaceTextStyle: String, CaseIterable {
    /// Secondary detail lines. Replaces `.caption`, `.caption2` and `.footnote`.
    case caption
    /// Detail that needs a little more presence than `caption` without changing size.
    case captionMedium
    /// Inline labels, badges and pill text.
    case captionStrong
    /// Counter digits and warning glyph text that must read at a glance.
    case captionHeavy
    /// Primary body copy. Replaces `.subheadline`.
    case body
    /// Row, card and panel titles. Replaces `.subheadline.weight(.semibold)`.
    case bodyStrong

    var pointSize: CGFloat {
        switch self {
        case .caption, .captionMedium, .captionStrong, .captionHeavy:
            return 12
        case .body, .bodyStrong:
            return 13
        }
    }

    var weight: Font.Weight {
        switch self {
        case .caption, .body:
            return .regular
        case .captionMedium:
            return .medium
        case .captionStrong, .bodyStrong:
            return .semibold
        case .captionHeavy:
            return .bold
        }
    }

    var font: Font {
        .system(size: pointSize, weight: weight)
    }
}

/// Typography limits that are not themselves text styles.
enum InterfaceTypography {
    /// The floor from `AGENTS.md`: no Chinese interface text may render smaller than this.
    static let minimumPointSize: CGFloat = 12

    /// Statistics cards show a single numeral that must stay on one line, so it is the one
    /// place allowed to shrink to fit. `AGENTS.md` permits that only while the shrunk text
    /// still clears the floor, so the size and the factor live together here and
    /// `shrinkableValueFloorPointSize` is asserted against `minimumPointSize` in tests.
    /// Reading them from two unrelated literals in a view body made the rule unverifiable.
    static let shrinkableValuePointSize: CGFloat = 21
    static let shrinkableValueMinimumScaleFactor: CGFloat = 0.75

    /// The smallest size the shrinkable value can actually reach on screen.
    static var shrinkableValueFloorPointSize: CGFloat {
        shrinkableValuePointSize * shrinkableValueMinimumScaleFactor
    }
}

extension Font {
    static var appCaption: Font { InterfaceTextStyle.caption.font }
    static var appCaptionMedium: Font { InterfaceTextStyle.captionMedium.font }
    static var appCaptionStrong: Font { InterfaceTextStyle.captionStrong.font }
    static var appCaptionHeavy: Font { InterfaceTextStyle.captionHeavy.font }
    static var appBody: Font { InterfaceTextStyle.body.font }
    static var appBodyStrong: Font { InterfaceTextStyle.bodyStrong.font }
}
