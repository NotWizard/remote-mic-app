import SwiftUI

// ponytail: fork-local stub for the private SayAllMacRemoteUI module. The real
// module renders the web pairing QR flow against a relay server this fork cannot
// reach, so the sheet just states that the feature is unavailable here.

/// Marker protocol the app conforms `BridgeAppModel` to. The real module reads
/// session state through it; the placeholder view needs no requirements.
public protocol WebRemoteSessionModel: AnyObject {}

public struct WebRemoteSessionLocalization: Sendable {
    public let locale: Locale
    public let text: @Sendable (String) -> String

    public init(locale: Locale, text: @escaping @Sendable (String) -> String) {
        self.locale = locale
        self.text = text
    }
}

public struct WebRemoteSessionView: View {
    private let localization: WebRemoteSessionLocalization

    public init(model: some WebRemoteSessionModel, localization: WebRemoteSessionLocalization) {
        self.localization = localization
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(localization.text("connection.web.unavailable"))
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(minWidth: 320, minHeight: 200)
    }
}
