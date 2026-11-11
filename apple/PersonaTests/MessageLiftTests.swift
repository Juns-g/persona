import CoreGraphics
import Testing
@testable import Persona

/// Where a long-pressed message and its bar go (#603): the message stays put when it can, the bar goes under it, above
/// it when there is no room under it, and a message taller than the screen shows the part around the press with the bar
/// still on screen.
struct MessageLiftTests {
    /// An iPhone's screen inside its safe area, and the bar of five actions.
    private let bounds = CGRect(x: 0, y: 60, width: 390, height: 700)
    private let bar = CGSize(width: 302, height: 62)

    private func place(_ message: CGRect, press: CGFloat = 10, trailing: Bool = false) -> LiftLayout.Placement {
        LiftLayout.place(message: message, press: press, bar: bar, bounds: bounds, margin: 8, gap: 8, trailing: trailing)
    }

    @Test func aShortMessageStaysWhereItIsWithTheBarUnderIt() {
        let p = place(CGRect(x: 120, y: 300, width: 254, height: 44), trailing: true)
        #expect(p.preview == CGRect(x: 120, y: 300, width: 254, height: 44))
        #expect(p.below && p.offset == 0)
        #expect(p.bar.minY == 352)
        #expect(p.bar.maxX == 374, "your own message's bar lines up with its right edge")
    }

    @Test func atTheBottomTheBarGoesAbove() {
        let p = place(CGRect(x: 16, y: 690, width: 358, height: 50))
        #expect(!p.below)
        #expect(p.preview.minY == 690)
        #expect(p.bar.maxY == 682)
    }

    @Test func withRoomForNeitherTheMessageMovesUpForTheBar() {
        // Near the top and nearly as tall as the screen: no room above it, none under it.
        let p = place(CGRect(x: 16, y: 80, width: 358, height: 610))
        #expect(p.below)
        #expect(p.bar.maxY <= bounds.maxY - 8)
        #expect(p.preview.maxY + 8 == p.bar.minY)
    }

    @Test func aMessageTallerThanTheScreenShowsThePartAroundThePressAndTheBarStaysOnScreen() {
        let message = CGRect(x: 16, y: -900, width: 358, height: 2400)
        let p = place(message, press: 1300)
        #expect(abs(p.preview.height - (700 - 16 - 8 - 62)) < 0.5) // CGFloat sums: not exactly equal
        #expect(abs(p.offset + p.preview.height / 2 - 1300) < 1, "the press is in the middle of what shows")
        #expect(p.bar.minY >= bounds.minY && p.bar.maxY <= bounds.maxY)
        #expect(p.preview.minY >= bounds.minY + 8)
    }

    @Test func aPressNearEitherEndShowsThatEnd() {
        let message = CGRect(x: 16, y: 100, width: 358, height: 2400)
        #expect(place(message, press: 5).offset == 0)
        let end = place(message, press: 2395)
        #expect(end.offset + end.preview.height == 2400)
    }

    @Test func theBarStaysInsideTheScreenSideways() {
        let p = place(CGRect(x: 300, y: 300, width: 80, height: 40))
        #expect(p.bar.maxX <= bounds.maxX - 8)
        let q = place(CGRect(x: 16, y: 300, width: 80, height: 40), trailing: true)
        #expect(q.bar.minX >= bounds.minX + 8)
    }

    /// A selection handle held near a long lifted message's top or bottom edge scrolls it on that way (#3188).
    @Test func aHandleHeldAtAnEdgeScrollsThatWayFasterTheCloserItIs() {
        func speed(_ y: CGFloat, _ height: CGFloat = 600) -> CGFloat {
            LiftLayout.edgeScroll(at: y, height: height, band: 44, speed: 900)
        }
        #expect(speed(300) == 0, "in the middle it stays")
        #expect(speed(44) == 0 && speed(556) == 0, "just outside the bands")
        #expect(speed(22) == -450 && speed(578) == 450, "halfway into a band: half speed, up or down")
        #expect(speed(0) == -900 && speed(-80) == -900, "at the edge and past it: full speed")
        #expect(speed(600) == 900 && speed(700) == 900)
        // A short part: its bands are a third of it each, with the middle still at rest.
        #expect(speed(30, 90) == 0)
        #expect(speed(0, 90) == -900)
        #expect(speed(10, 0) == 0, "nothing shown, nothing to scroll")
    }

    /// The text view over selected words puts its lines on the chat's (#3188): each on the nearest row ahead, a line
    /// the chat has no row for passed over with the move before it, and after a picture the next line on the next row.
    @Test func theTextViewsLinesGoOnTheChats() {
        func snap(_ lines: [(CGFloat, Bool)], _ rows: [CGFloat]) -> [CGFloat] {
            LiftLayout.snap(lines.map { LiftLayout.SnapLine(baseline: $0.0, block: $0.1) }, to: rows, reach: 10).map(\.at)
        }
        // Its lines a little further apart than the chat's: each goes on the chat's.
        #expect(snap([(20, false), (44.7, false), (69.4, false)], [20, 44.3, 68.6]) == [20, 44.3, 68.6])
        // A rule the chat draws as no text: it keeps the move before it, the line after goes on its row.
        #expect(snap([(20, false), (40, false), (60, false)], [20, 61]) == [20, 40, 61])
        // A table: the chat's rows for it are not there; the line after it takes the next row, wherever it is.
        #expect(snap([(20, false), (60, true), (200, false), (224, false)], [20, 240, 264]) == [20, 60, 240, 264])
        // No rows: as laid out.
        #expect(snap([(20, false), (44, false)], []) == [20, 44])
    }

    /// A code block's first line under its title bar (`fresh`) takes the chat's next row, however far the bar put it.
    @Test func aCodeBlocksFirstLineGoesUnderItsBar() {
        let lines = [LiftLayout.SnapLine(baseline: 20), LiftLayout.SnapLine(baseline: 60, fresh: true), LiftLayout.SnapLine(baseline: 80)]
        #expect(LiftLayout.snap(lines, to: [20, 100, 120], reach: 10).map(\.at) == [20, 100, 120])
    }

    /// A folded quote (#3188): the chat shows as many of its lines as its card has rows; the text view's others are
    /// hidden at the card's bottom, and the line after the quote takes the next row (the paragraph after the card).
    @Test func aFoldedQuotesHiddenLinesAreNotOnTheChats() {
        let q = 7
        let lines = [LiftLayout.SnapLine(baseline: 20)]
            + (0..<6).map { LiftLayout.SnapLine(baseline: 52 + CGFloat($0) * 24, quote: q) }
            + [LiftLayout.SnapLine(baseline: 212)]
        // The card spans 36...130 and shows four lines (52, 76, 100, 124); the paragraph after it is at 160.
        let out = LiftLayout.snap(lines, to: [20, 52, 76, 100, 124, 160], folds: [36...130], reach: 10)
        #expect(out.map(\.at) == [20, 52, 76, 100, 124, 130, 130, 160])
        #expect(out.map(\.hidden) == [false, false, false, false, false, true, true, false])
        // Open (no fold): every line on its row.
        let open = LiftLayout.snap(lines, to: [20, 52, 76, 100, 124, 148, 172, 212], reach: 10)
        #expect(open.map(\.at) == [20, 52, 76, 100, 124, 148, 172, 212])
        #expect(!open.contains { $0.hidden })
    }
}
