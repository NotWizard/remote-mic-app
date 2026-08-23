import AppKit
import Foundation
import Testing
@testable import RemoteMic

/// `AGENTS.md` requires every settings page to be checked at the production
/// minimum window size without clipping or changing the window geometry, and
/// requires Chinese text never to render below 12pt. Until now none of that was
/// ever exercised: the audit fix that raised 53 sub-floor labels shipped with the
/// interface never rendered even once.
///
/// The app already contains an offscreen renderer that builds the real
/// `SettingsView` over a real `BridgeAppModel`, so these tests drive it directly.
///
/// **Two limits, both found by running this and both load-bearing when reading
/// the results:**
///
/// 1. Roughly half the interface strings go through SwiftUI's `Text("some.key")`,
///    which resolves against the *main* bundle. In a test process that is the test
///    runner, which carries no `.lproj` resources, so those strings render as raw
///    keys. The shipping app resolves them correctly — `SettingsView` sets
///    `\.locale` from the localization store and the app bundle has the tables.
///    Consequence: **these tests cannot verify typography or wording.** They check
///    layout and geometry only. Faithful screenshots need the app binary, which
///    needs a real GUI session.
/// 2. The renderer starts from a fresh defaults suite, so the statistics page is
///    an empty state with very little on it. A "did anything draw" check applied
///    to every page therefore fails for reasons that are not defects, which is why
///    that check is scoped to the mapping page below.
@Suite("Settings page rendering")
struct SettingsPageRenderingTests {
    private static let pageCount = 5

    private struct Rendered {
        var name: String
        var pixelWidth: Int
        var pixelHeight: Int
        var distinctLuminanceBuckets: Int
    }

    @MainActor
    private func render(
        size: String,
        language: String,
        appearance: String = "light"
    ) throws -> [Rendered] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SettingsRender-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try SettingsScreenshotRenderer.renderAll(
            to: directory,
            sizeValue: size,
            appearanceName: appearance,
            languageName: language
        )

        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".png") }
            .sorted()

        return try names.map { name in
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let image = try #require(NSBitmapImageRep(data: data))
            // A page that failed to lay out comes back as one flat colour. Bucket
            // the luminance of a sparse grid so "blank" is distinguishable from
            // "actually drew something" without depending on exact pixels.
            var buckets = Set<Int>()
            let stepX = max(1, image.pixelsWide / 40)
            let stepY = max(1, image.pixelsHigh / 40)
            for x in stride(from: 0, to: image.pixelsWide, by: stepX) {
                for y in stride(from: 0, to: image.pixelsHigh, by: stepY) {
                    guard let colour = image.colorAt(x: x, y: y) else { continue }
                    let luminance =
                        0.299 * colour.redComponent
                        + 0.587 * colour.greenComponent
                        + 0.114 * colour.blueComponent
                    buckets.insert(Int(luminance * 32))
                }
            }
            return Rendered(
                name: name,
                pixelWidth: image.pixelsWide,
                pixelHeight: image.pixelsHigh,
                distinctLuminanceBuckets: buckets.count
            )
        }
    }

    @MainActor
    @Test(arguments: ["zh-Hans", "en"])
    func everyPageRendersAtTheProductionMinimumWindow(language: String) throws {
        let pages = try render(size: "1020x772", language: language)

        #expect(pages.count == Self.pageCount)
        for page in pages {
            // The renderer may draw at a backing scale, so compare the ratio
            // rather than raw pixels; what matters is that the page did not force
            // a different aspect than the size it was handed.
            #expect(page.pixelWidth > 0 && page.pixelHeight > 0)
            let ratio = Double(page.pixelWidth) / Double(page.pixelHeight)
            let expected = 1020.0 / 772.0
            #expect(abs(ratio - expected) < 0.01, "\(page.name) forced a different geometry")
        }
        try assertMappingPageDrewItsIllustration(pages)
    }

    /// `AGENTS.md`'s gate names a narrower window than the production minimum, and
    /// users cannot drag the window that small, so this is the only way the narrow
    /// layout gets exercised at all. It is also the size at which the mapping
    /// page's configuration cards used to paint over the remote illustration.
    @MainActor
    @Test(arguments: ["zh-Hans", "en"])
    func everyPageStillRendersAtTheNarrowGateSize(language: String) throws {
        let pages = try render(size: "800x650", language: language)

        #expect(pages.count == Self.pageCount)
        for page in pages {
            let ratio = Double(page.pixelWidth) / Double(page.pixelHeight)
            let expected = 800.0 / 650.0
            #expect(abs(ratio - expected) < 0.01, "\(page.name) forced a different geometry")
        }
        try assertMappingPageDrewItsIllustration(pages)
    }

    /// Dark mode uses different materials, and the typography change touched every
    /// page, so a page that only breaks in dark appearance would otherwise ship.
    @MainActor
    @Test func everyPageRendersInDarkAppearance() throws {
        let pages = try render(size: "1020x772", language: "zh-Hans", appearance: "dark")

        #expect(pages.count == Self.pageCount)
        try assertMappingPageDrewItsIllustration(pages)
    }

    /// The mapping page carries the remote photograph, which is real artwork and
    /// does not depend on string resolution, so it is the one page whose pixels
    /// mean something in a test process.
    private func assertMappingPageDrewItsIllustration(_ pages: [Rendered]) throws {
        let mapping = try #require(pages.first { $0.name.hasPrefix("mapping") })
        #expect(
            mapping.distinctLuminanceBuckets > 4,
            "mapping page drew no illustration (\(mapping.distinctLuminanceBuckets) tones)"
        )
    }
}
