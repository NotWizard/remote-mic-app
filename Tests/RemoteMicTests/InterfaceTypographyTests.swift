import CoreGraphics
import SwiftUI
import Testing
@testable import RemoteMic

/// `AGENTS.md` sets a 12pt floor for Chinese interface text and forbids using
/// `minimumScaleFactor` to shrink it below that. Before this suite the rule was only
/// enforceable by re-reading fifty-odd call sites, so it drifted: `.caption` (10pt) and
/// `.subheadline` (11pt) were in use throughout the settings window.
///
/// These tests assert on the values the views actually resolve their sizes from, so a
/// token edited to 11pt fails here rather than shipping.
@Suite("Interface typography")
struct InterfaceTypographyTests {
    @Test func everyTextTokenClearsTheTwelvePointFloor() {
        #expect(!InterfaceTextStyle.allCases.isEmpty)

        for style in InterfaceTextStyle.allCases {
            #expect(
                style.pointSize >= InterfaceTypography.minimumPointSize,
                Comment(rawValue: "\(style.rawValue) is \(style.pointSize)pt")
            )
        }
    }

    /// The floor itself is the rule, so it must not be quietly relaxed either.
    @Test func theDeclaredFloorMatchesTheRepositoryRule() {
        #expect(InterfaceTypography.minimumPointSize == 12)
    }

    /// A token whose size clears the floor is still wrong if it renders at a different
    /// size than it advertises, so the resolved `Font` is compared against a font built
    /// from the token's own numbers.
    @Test func tokenFontsResolveToTheirDeclaredSizeAndWeight() {
        for style in InterfaceTextStyle.allCases {
            #expect(style.font == .system(size: style.pointSize, weight: style.weight))
        }
    }

    /// Distinct roles must stay distinct, otherwise a later edit can collapse the set to
    /// one token and the call sites lose the hierarchy they were converted to preserve.
    @Test func tokensCoverTheRolesTheSettingsWindowNeeds() {
        let signatures = InterfaceTextStyle.allCases.map { "\($0.pointSize)-\($0.weight)" }
        #expect(Set(signatures).count == InterfaceTextStyle.allCases.count)

        #expect(InterfaceTextStyle.caption.weight == .regular)
        #expect(InterfaceTextStyle.captionMedium.weight == .medium)
        #expect(InterfaceTextStyle.captionStrong.weight == .semibold)
        #expect(InterfaceTextStyle.captionHeavy.weight == .bold)
        #expect(InterfaceTextStyle.body.pointSize > InterfaceTextStyle.caption.pointSize)
        #expect(InterfaceTextStyle.bodyStrong.weight == .semibold)
    }

    /// The statistics value is the only shrink-to-fit text in the app. `AGENTS.md` allows
    /// that only while the shrunk result still clears the floor, and the shrunk result is
    /// the product of two numbers that used to sit in unrelated lines of a view body.
    @Test func theShrinkableStatisticValueCannotShrinkBelowTheFloor() {
        #expect(InterfaceTypography.shrinkableValueMinimumScaleFactor > 0)
        #expect(InterfaceTypography.shrinkableValueMinimumScaleFactor <= 1)
        #expect(
            InterfaceTypography.shrinkableValueFloorPointSize
                >= InterfaceTypography.minimumPointSize,
            Comment(rawValue: "shrinks to \(InterfaceTypography.shrinkableValueFloorPointSize)pt")
        )
    }
}

/// The mapping page draws the remote photo as a fixed-size frame pinned to the centre of
/// the canvas, with the configuration cards layered on top of it and connector lines drawn
/// to the photo's button hotspots. The card width therefore has to yield to the photo, not
/// the other way round: the photo cannot shrink without moving every connector anchor.
@Suite("Remote mapping canvas geometry")
struct RemoteMappingCanvasGeometryTests {
    /// Canvas widths the settings window actually produces. The mapping page sits inside a
    /// 108pt sidebar plus a 1pt divider, and its content stack adds 22pt of padding on each
    /// side, so the canvas is the window width less 153pt.
    private static let sidebarAndPaddingInset: CGFloat = 153

    private static func canvasWidth(forWindowWidth windowWidth: CGFloat) -> CGFloat {
        windowWidth - sidebarAndPaddingInset
    }

    @Test func theCentredRemotePhotoIsNeverCoveredByTheCards() {
        // Sweep every width from far below the repository's 800pt regression-gate window up
        // past the production minimum, because the old formula only failed on the narrow end.
        for windowWidth in stride(from: CGFloat(600), through: CGFloat(2000), by: 1) {
            let canvasWidth = Self.canvasWidth(forWindowWidth: windowWidth)
            let clearance = RemoteMappingLayout.cardToRemoteClearance(for: canvasWidth)
            #expect(
                clearance >= RemoteMappingLayout.centerChannelGap,
                Comment(rawValue: "window \(windowWidth)pt leaves \(clearance)pt clearance")
            )
        }
    }

    /// The two specific widths that matter: the window size `AGENTS.md` requires settings
    /// changes to be verified at, and the size the shipping window actually opens at.
    @Test func bothTheRegressionGateAndProductionWidthsKeepThePhotoClear() {
        let gateCanvas = Self.canvasWidth(forWindowWidth: 800)
        let productionCanvas = Self.canvasWidth(forWindowWidth: 1020)

        #expect(RemoteMappingLayout.cardToRemoteClearance(for: gateCanvas) >= 29)
        #expect(RemoteMappingLayout.cardToRemoteClearance(for: productionCanvas) >= 29)

        // Production is wide enough to afford the full card, so this change must not have
        // altered what today's users see.
        #expect(
            RemoteMappingLayout.cardWidth(for: productionCanvas)
                == RemoteMappingLayout.preferredCardWidth
        )
    }

    /// Narrow canvases have to give the width back from the cards, and the amount given back
    /// has to be exactly what the channel needs — a card that keeps its preferred width is
    /// how the original squeeze happened.
    @Test func narrowCanvasesShrinkTheCardsRatherThanTheChannel() {
        let narrowCanvas = Self.canvasWidth(forWindowWidth: 800)
        let cardWidth = RemoteMappingLayout.cardWidth(for: narrowCanvas)

        #expect(cardWidth < RemoteMappingLayout.preferredCardWidth)
        #expect(cardWidth > 0)
        #expect(
            cardWidth * 2 + RemoteMappingLayout.centerChannelWidth <= narrowCanvas + 0.001
        )
    }

    /// Degenerate widths must not produce a negative card or a covered photo.
    @Test func thePhotoStaysClearEvenWhenThereIsNoRoomForCards() {
        for canvasWidth in [CGFloat(0), 100, 202, 260, 261] {
            let cardWidth = RemoteMappingLayout.cardWidth(for: canvasWidth)
            #expect(cardWidth >= 0)
            #expect(
                cardWidth * 2 + RemoteMappingLayout.centerChannelWidth <= max(
                    canvasWidth,
                    RemoteMappingLayout.centerChannelWidth
                ) + 0.001
            )
        }
    }

    /// The channel is derived from the photo it protects, so resizing the photo cannot
    /// silently invalidate the reservation.
    @Test func theCentreChannelIsDerivedFromThePhotoItProtects() {
        #expect(
            RemoteMappingLayout.centerChannelWidth
                == RemoteMappingLayout.remoteSize.width
                    + RemoteMappingLayout.centerChannelGap * 2
        )
        #expect(RemoteMappingLayout.centerChannelGap > 0)
    }

    /// The card edge is where the connector arrows terminate, so the clearance helper has to
    /// describe the same edge the drawing code uses rather than a parallel calculation.
    @Test func theClearanceHelperMeasuresTheEdgeTheConnectorsPointAt() {
        let canvasWidth = Self.canvasWidth(forWindowWidth: 900)
        let cardWidth = RemoteMappingLayout.cardWidth(for: canvasWidth)
        let leftEdge = RemoteMappingLayout.cardEdgePoint(
            side: .left,
            targetY: 0.5,
            canvasWidth: canvasWidth,
            cardWidth: cardWidth
        )
        let rightEdge = RemoteMappingLayout.cardEdgePoint(
            side: .right,
            targetY: 0.5,
            canvasWidth: canvasWidth,
            cardWidth: cardWidth
        )
        let photoLeadingEdge = canvasWidth / 2 - RemoteMappingLayout.remoteSize.width / 2
        let photoTrailingEdge = canvasWidth / 2 + RemoteMappingLayout.remoteSize.width / 2
        let clearance = RemoteMappingLayout.cardToRemoteClearance(for: canvasWidth)

        #expect(photoLeadingEdge - leftEdge.x == clearance)
        #expect(rightEdge.x - photoTrailingEdge == clearance)
    }
}
