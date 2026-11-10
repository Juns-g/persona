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
}
