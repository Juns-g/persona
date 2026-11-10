import XCTest

/// A long press lifts the message over the dimmed chat with its bar next to it (#603), against scripts/mock/mock_hub.py
/// with MOCK_MESSAGE_LIFT=1: a short message, the newest one just above the composer, and the middle of an answer taller
/// than the screen, whose bar must be on screen without scrolling; and an answer in Persona's conversation, in its box.
/// An answer taller than the screen scrolls inside the lift to its first line, with the bar staying put, in an Agents
/// chat and in Persona's conversation, and a selection handle dragged to its top edge scrolls it on (#3188).
/// PERSONA_LIFT_SCHEME: light or dark, or "light,dark": the tests of #3188 run in each, one after the other.
/// PERSONA_LIFT_KEEP_GOING=1: a test goes on past a failure (to record a build without the fix to its end).
final class MessageLiftUITests: XCTestCase {
    private var app: XCUIApplication!
    private var hub = ""
    private let short = "macbook/a1f3c2d4-0000-4000-8000-0000000c1e08"
    private let long = "macbook/a1f3c2d4-0000-4000-8000-0000000c1e09"
    /// The same long answer in a Persona conversation.
    private let askLong = "server/b2e4d6f8-0000-4000-8000-0000000c1e09"
    /// An answer a little shorter than a small phone's screen, in another.
    private let askMid = "server/b2e4d6f8-0000-4000-8000-0000000c1e0a"
    private let schemes = (ProcessInfo.processInfo.environment["PERSONA_LIFT_SCHEME"] ?? "light").split(separator: ",").map(String.init)
    private var scheme = "light"

    override func setUpWithError() throws {
        continueAfterFailure = ProcessInfo.processInfo.environment["PERSONA_LIFT_KEEP_GOING"] == "1"
        scheme = schemes.first ?? "light"
        guard let hub = ProcessInfo.processInfo.environment["PERSONA_MOCK_HUB"] else {
            throw XCTSkip("needs scripts/mock/mock_hub.py (PERSONA_MOCK_HUB)")
        }
        self.hub = hub
        app = XCUIApplication()
    }

    private func launch(_ chat: String, _ extra: [String] = []) {
        let pair = "persona://pair?url=" + hub.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&token=mock"
        app.launchArguments = ["-pairURL", pair, "-tab", "dev", "-openSession", chat, "-ui.scheme", scheme] + extra
        app.launchPinned()
    }

    @MainActor private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "lift-\(name)-\(scheme)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func text(_ s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    @MainActor private func press(_ words: String) {
        let e = text(words)
        XCTAssertTrue(e.waitForExistence(timeout: 20), "missing: \(words)")
        sleep(1) // the chat settles at its newest
        e.press(forDuration: 0.8)
        sleep(1)
    }

    /// A short message of yours in the middle of the chat.
    @MainActor func testAShortMessage() throws {
        launch(short)
        press("可以，就这么改")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "复制")).firstMatch.exists || app.staticTexts["复制"].exists)
        shot("short")
    }

    /// The newest answer, just above the composer: no room under it for the bar.
    @MainActor func testTheNewestAnswerAboveTheComposer() throws {
        launch(short)
        press("收到，都提交了")
        shot("bottom")
    }

    private func launchPersona(_ chat: String, _ extra: [String] = []) {
        let pair = "persona://pair?url=" + hub.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&token=mock"
        app.launchArguments = ["-pairURL", pair, "-app.tab", "assistant", "-tab", "assistant",
                               "-openAssistant", chat, "-openChatsFresh", "YES", "-ui.scheme", scheme] + extra
        app.launchPinned()
    }

    /// An answer in Persona's own conversation, which draws it in a box (the new conversation layout, on by default):
    /// lifted in that box, with no card around it.
    @MainActor func testAnAnswerInPersonasConversation() throws {
        launchPersona("server/b2e4d6f8-0000-4000-8000-000000000001")
        press("博客迁移已经做完")
        XCTAssertTrue(app.staticTexts["复制"].firstMatch.exists, "no bar")
        shot("persona")
    }

    /// The middle of an answer taller than the screen: the bar is on screen.
    @MainActor func testTheMiddleOfALongAnswer() throws {
        launch(long)
        XCTAssertTrue(text("有问题的话告诉我").waitForExistence(timeout: 20))
        sleep(1)
        // Back a little, so the answer runs past both ends of the screen.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        sleep(1)
        let copy = app.staticTexts["复制"].firstMatch
        XCTAssertTrue(copy.exists && app.frame.contains(copy.frame), "the bar's Copy is on screen")
        shot("long")
    }

    // MARK: A lifted answer taller than the screen scrolls (#3188)

    /// Runs `body` in each of PERSONA_LIFT_SCHEME's schemes, the app launched again for each.
    @MainActor private func inEachScheme(_ body: () throws -> Void) rethrows {
        for s in schemes {
            scheme = s
            app = XCUIApplication()
            try body()
        }
    }

    /// The lifted copy (`MessageLiftLayer`).
    private var lifted: XCUIElement { app.descendants(matching: .any)["message-lift"].firstMatch }
    /// The long answer's first line, its heading, in the lifted copy.
    private var firstLine: XCUIElement { lifted.staticTexts["改动和验证"].firstMatch }

    /// `e` shows inside the lifted copy's frame (not cut off above or below it).
    private func shows(_ e: XCUIElement) -> Bool {
        e.exists && lifted.frame.insetBy(dx: -1, dy: -1).contains(e.frame)
    }

    /// Long-presses the long answer's last line, just above the composer: the lift opens at its end.
    @MainActor private func liftTheLongAnswerAtItsEnd() { liftAt("有问题的话告诉我") }

    /// Long-presses the line with these words, the newest answer's last.
    @MainActor private func liftAt(_ words: String) {
        let end = text(words)
        XCTAssertTrue(end.waitForExistence(timeout: 20), "missing the answer")
        sleep(2) // the chat settles at its newest; the header folds
        // Rows of the flipped chat list may report flipped frames: press by the centre, in the window.
        let window = app.windows.firstMatch.frame
        var f = end.frame
        if !window.contains(CGPoint(x: f.midX, y: f.midY)) { f.origin.y = window.height - f.maxY }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["复制"].firstMatch.waitForExistence(timeout: 3), "no bar")
        sleep(1)
    }

    /// Drags down on the lifted copy, above the bar, until its first line shows (at most `tries` times).
    @MainActor private func scrollToTheTop(tries: Int = 8) {
        let bar = app.buttons["复制"].firstMatch.frame
        for _ in 0..<tries {
            if shows(firstLine) { return }
            let top = max(lifted.exists ? lifted.frame.minY : 0, app.frame.height * 0.2)
            let from = CGPoint(x: app.frame.midX, y: top + 30), to = CGPoint(x: app.frame.midX, y: bar.minY - 30)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: from.x, dy: from.y))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)))
            sleep(1)
        }
    }

    @MainActor private func checkTheLongAnswerScrollsToItsFirstLine(_ name: String) {
        liftTheLongAnswerAtItsEnd()
        let bar = app.buttons["复制"].firstMatch.frame
        XCTAssertTrue(lifted.waitForExistence(timeout: 3), "no lifted copy:\n\(app.debugDescription)")
        XCTAssertTrue(app.frame.contains(bar), "the bar is on screen")
        XCTAssertFalse(shows(firstLine), "opens around the press, at the end, not at the first line")
        let pressed = lifted.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "有问题的话告诉我")).firstMatch
        XCTAssertTrue(shows(pressed), "the pressed line shows")
        shot(name + "-end")
        scrollToTheTop()
        XCTAssertTrue(shows(firstLine), "the lifted answer scrolls to its first line:\n\(lifted.debugDescription)")
        XCTAssertEqual(app.buttons["复制"].firstMatch.frame, bar, "the bar stays where it is")
        // Nothing over it (Persona's top bar was): a tap on the first line lands on it.
        XCTAssertTrue(firstLine.isHittable, "the first line is covered")
        shot(name + "-top")
    }

    /// In an Agents chat.
    @MainActor func testALongAnswerScrollsToItsFirstLine() throws {
        inEachScheme {
            launch(long)
            checkTheLongAnswerScrollsToItsFirstLine("scroll")
        }
    }

    /// In Persona's conversation, whose top bar floats over the chat: the lifted copy is drawn over the bar too.
    @MainActor func testALongAnswerInPersonasConversationScrollsToItsFirstLine() throws {
        inEachScheme {
            launchPersona(askLong)
            checkTheLongAnswerScrollsToItsFirstLine("persona-scroll")
        }
    }

    /// The case reported (#3188): an answer that fits beside the bar, so it lifts whole and does not scroll, pressed while
    /// its top is where Persona's top bar floats. The lift is drawn over the bar, the whole page dimmed: the bar, under
    /// the dimming, takes no taps (in the build before, it was over the answer's first lines).
    @MainActor func testAnAnswerUnderPersonasTopBarLiftsOverIt() throws {
        inEachScheme {
            launchPersona(askMid)
            let avatar = app.buttons["persona-avatar"].firstMatch
            XCTAssertTrue(avatar.waitForExistence(timeout: 20), "no top bar")
            liftAt("要我先带你看哪一块")
            XCTAssertTrue(lifted.waitForExistence(timeout: 3), "no lifted copy")
            XCTAssertFalse(avatar.isHittable, "the top bar is over the lifted message")
            shot("persona-mid")
        }
    }

    /// Select Text on the long answer lifted at its end, then the selection's end handle dragged to the lifted copy's
    /// top edge and held there: the copy scrolls on up to its first line, as a text view does.
    @MainActor func testAHandleAtTheTopEdgeScrollsTheLiftedAnswer() throws {
        try inEachScheme {
            launch(long)
            liftTheLongAnswerAtItsEnd()
            app.buttons["选择文本"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            let words = app.textViews["lift-text"]
            XCTAssertTrue(words.waitForExistence(timeout: 5), "选择文本 did not select the words in place")
            sleep(1)
            // A paragraph's frame hugs its words: the end handle is under the last one's end.
            let last = try XCTUnwrap(words.textViews.allElementsBoundByIndex.last { !$0.label.isEmpty }, "no paragraphs:\n\(words.debugDescription)").frame
            let top = words.frame.minY, edge = lifted.frame.minY
            XCTAssertLessThan(top, edge - 200, "the words start well out of sight")
            shot("handle-start")
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: last.maxX - 1, dy: last.maxY + 4))
                .press(forDuration: 0.5, thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: edge + 4)),
                       withVelocity: .default, thenHoldForDuration: 4)
            sleep(1)
            XCTAssertGreaterThanOrEqual(words.frame.minY, edge, "held at the top edge, the handle scrolled the lifted copy up to its first line")
            XCTAssertTrue(app.textViews["lift-text"].exists, "still selecting")
            shot("handle-top")
        }
    }
}
