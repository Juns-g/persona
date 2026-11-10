import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import Persona

/// The live screen's cheaper paths (#3067): the damage a frame copies (RFBRegion), the frame sink copying only that
/// into the buffers it reuses, the outbox folding pointer motion, and the next update asked for as an update starts.
struct RFBFrameTests {
    // MARK: RFBRegion

    @Test func regionMergesWhatOverlapsOrTouchesAndKeepsTheRest() {
        var r = RFBRegion()
        r.add(CGRect(x: 0, y: 0, width: 10, height: 10))
        r.add(CGRect(x: 5, y: 5, width: 10, height: 10)) // overlaps: one rectangle around both
        #expect(r.rects == [CGRect(x: 0, y: 0, width: 15, height: 15)])
        r.add(CGRect(x: 15, y: 0, width: 5, height: 5)) // touches its right edge: joins
        #expect(r.rects == [CGRect(x: 0, y: 0, width: 20, height: 15)])
        r.add(CGRect(x: 100, y: 100, width: 4, height: 4)) // far away: its own
        #expect(r.rects.count == 2)
        r.add(CGRect(x: 1, y: 1, width: 2, height: 2)) // inside one: nothing new
        #expect(r.rects.count == 2)
        r.add(.null)
        r.add(CGRect(x: 3, y: 3, width: 0, height: 9))
        #expect(r.rects.count == 2, "empty rectangles are left out")
        #expect(r.area == 20 * 15 + 16)
        #expect(r.clipped(to: CGRect(x: 0, y: 0, width: 10, height: 10)).rects == [CGRect(x: 0, y: 0, width: 10, height: 10)])
    }

    @Test func regionFoldsIntoItsBoundsPastMost() {
        var r = RFBRegion()
        for i in 0...RFBRegion.most { r.add(CGRect(x: i * 10, y: i * 10, width: 2, height: 2)) }
        #expect(r.rects.count == 1)
        #expect(r.rects.first == CGRect(x: 0, y: 0, width: RFBRegion.most * 10 + 2, height: RFBRegion.most * 10 + 2))
    }

    // MARK: RFBOutbox

    private func pointer(_ x: UInt8, _ buttons: UInt8) -> [UInt8] { [5, buttons, 0, x, 0, 1] }

    @Test func outboxFoldsWaitingMotionButNotPressesReleasesOrNotches() {
        let o = RFBOutbox()
        o.send(pointer(1, 0))
        o.send(pointer(2, 1)) // pressed: kept
        o.send(pointer(3, 1))
        o.send(pointer(4, 1))
        o.send(pointer(5, 1)) // three moves while pressed: the last one stands for them
        #expect(o.waiting == [pointer(1, 0), pointer(2, 1), pointer(5, 1)])
        o.send(pointer(6, 0)) // released where it was let go
        o.send(pointer(7, 0)) // then a move: not folded into the release
        o.send(pointer(8, 0))
        #expect(o.waiting.suffix(2) == [pointer(6, 0), pointer(8, 0)])
        o.send([4, 1, 0, 0, 0, 0, 0, 0x61])
        o.send(pointer(9, 0)) // after a key: its own
        #expect(o.waiting.suffix(2) == [[4, 1, 0, 0, 0, 0, 0, 0x61], pointer(9, 0)])
        for _ in 0..<2 { o.send(pointer(9, 8)); o.send(pointer(9, 0)) } // two wheel notches: all four go
        #expect(o.waiting.suffix(4) == [pointer(9, 8), pointer(9, 0), pointer(9, 8), pointer(9, 0)])
    }

    @Test func outboxHandsOverInOrderAndEndsOnFinishOrCancel() async {
        let o = RFBOutbox()
        o.send([1])
        o.send([2])
        #expect(await o.next() == [1])
        #expect(await o.next() == [2])
        let waiting = Task { await o.next() }
        try? await Task.sleep(for: .milliseconds(50))
        o.send([3]) // straight to the one waiting
        #expect(await waiting.value == [3])
        let cancelled = Task { await o.next() }
        try? await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        #expect(await cancelled.value == nil, "a cancelled wait ends (the client's task group would wait for it forever)")
        let other = RFBOutbox()
        other.send([9])
        other.finish()
        #expect(await other.next() == nil, "finished: what waited is dropped")
        other.send([10])
        #expect(other.waiting.isEmpty)
    }

    // MARK: The client and the sink

    private static func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }

    private static func raw(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ bgra: [UInt8]) -> [UInt8] {
        var b: [UInt8] = [0, 0] + u16(1)
        b += u16(x) + u16(y) + u16(w) + u16(h) + RFBAuth.be32(0)
        for _ in 0..<(w * h) { b += bgra }
        return b
    }

    private static func greeting(_ w: Int, _ h: Int) -> [[UInt8]] {
        [Array("RFB 003.889\n".utf8), [1, 1], RFBAuth.be32(0), u16(w) + u16(h) + [UInt8](repeating: 0, count: 16) + RFBAuth.be32(0)]
    }

    /// Frames copied after the first two (each into a buffer the pool had not given before) copy only what changed
    /// since that buffer was last filled, and the picture the layers get is the framebuffer, pixel for pixel.
    @Test func sinkCopiesOnlyWhatChangedAndStaysExact() async throws {
        let w = 64, h = 48
        var script = Self.greeting(w, h)
        script.append(Self.raw(0, 0, w, h, [10, 20, 30, 0]))
        for (i, (x, y)) in [(0, 0), (40, 30), (60, 0), (10, 40), (30, 20), (0, 44)].enumerated() {
            script.append(Self.raw(x, y, 4, 4, [UInt8(50 + i * 20), 0, UInt8(200 - i * 20), 0]))
        }
        let t = PacedTransport(script, every: .milliseconds(40))
        let client = RFBClient(transport: t) { nil }
        let sink = RFBFrameSink()
        sink.attach(client) { _, _ in }
        client.start()
        for _ in 0..<300 where !t.done { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(150)) // the last copy
        let full = w * h * 4
        #expect(sink.copied > 2 * full, "the first two buffers are filled whole: \(sink.copied)")
        #expect(sink.copied < 2 * full + full / 4, "the rest only what changed: \(sink.copied)")
        let pb = try #require(sink.latestBuffer)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(pb)), row = CVPixelBufferGetBytesPerRow(pb)
        var wrong = 0
        client.withFramebuffer { fb in
            for y in 0..<h {
                for x in 0..<w where memcmp(base + y * row + x * 4, fb.pixels + (y * w + x) * 4, 4) != 0 { wrong += 1 }
            }
        }
        #expect(wrong == 0, "every pixel as the framebuffer has it")
        client.close()
    }

    /// The next incremental request goes out as soon as an update's header is in, before its rectangles: the
    /// transport holds the rectangle back until it has seen that request.
    @Test func nextUpdateIsAskedBeforeThisOneIsRead() async throws {
        var script = Self.greeting(8, 8)
        let update = Self.raw(0, 0, 8, 8, [1, 2, 3, 0])
        script.append(Array(update.prefix(4))) // the header alone
        script.append(Array(update.dropFirst(4)))
        let t = PacedTransport(script, every: .milliseconds(5)) { sent, next in
            // The rectangle (the script's sixth part) only once an incremental request followed the whole-screen one.
            next < 5 || sent.contains { $0.count == 10 && $0[0] == 3 && $0[1] == 1 }
        }
        let client = RFBClient(transport: t) { nil }
        let frames = Counter()
        client.onFrame = { _, _ in frames.add() }
        client.start()
        for _ in 0..<200 where frames.n == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(frames.n == 1, "the update was drawn: its request went out before it was read")
        client.close()
    }

    /// EndOfContinuousUpdates and Fence (#3067: asked for with ContinuousUpdates): taken, a Fence request answered
    /// with its data and no flags, the session going on.
    @Test func fenceIsAnsweredAndEndOfContinuousUpdatesTaken() async throws {
        var script = Self.greeting(4, 4)
        script.append([150])
        script.append([248, 0, 0, 0] + RFBAuth.be32(0x8000_0002) + [3, 7, 8, 9])
        script.append(Self.raw(0, 0, 1, 1, [1, 2, 3, 0]))
        let t = PacedTransport(script, every: .milliseconds(5))
        let client = RFBClient(transport: t) { nil }
        let frames = Counter()
        client.onFrame = { _, _ in frames.add() }
        client.start()
        for _ in 0..<200 where frames.n == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(frames.n == 1, "still reading after both")
        #expect(t.sent.contains([248, 0, 0, 0, 0, 0, 0, 0, 3, 7, 8, 9]))
        client.close()
    }

    // MARK: Tight

    /// Tight (#3067) as Python's zlib (sync-flushed, as servers do) and Go's JPEG made it: a fill, a two-colour and a
    /// four-colour palette on one stream, copy compressed and as it is, gradient, a JPEG, and a stream started again.
    @Test func tightDrawsWhatWasEncoded() async throws {
        let update = [UInt8](Data(base64Encoded: "AAAACAAAAAAACgAKAAAAB4DIZDIACgAAABAACAAAAAdQAQEAAAD///8PeJz6z8Dw/z8SBgAAAP//ABoAAAAGAAYAAAAHUAED/wAAAP8AAAD///8AFmJgZGJmYAQTTGCCGUwwIIsDAAAA//8AAAAKAAgABAAAAAcAQXicBMFBAQAwDAIxfudiSlBSJSipEpRU0RKJJyxGRKyoOCHzjM2YmDU1ZxRecJiQsKHhgsorLlNStrRc+QAAAP//AAgACgADAAEAAAAHAAECAwQFBgcICQAMAAoACAAEAAAAB2ACEXic4uLiYsEGGKgEAAAAAP//ABgACAAQAAwAAAAHkNgE/9j/2wCEAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYGBwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgoBAgICAgICBQMDBQoHBgcKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCv/AABEIAAwAEAMBIgACEQEDEQH/xAGiAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+gEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoLEQACAQIEBAMEBwUEBAABAncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/2gAMAwEAAhEDEQA/ALlFFFf2Qf59n//ZAAAAEAAEAAQAAAAHAQ54nOJMPs5JCgIAAAD//w==")!)
        let t = PacedTransport(Self.greeting(40, 20) + [update], every: .milliseconds(5))
        let client = RFBClient(transport: t) { nil }
        let seen = Pixels()
        client.onFrame = { fb, _ in
            var p: [String: [UInt8]] = [:]
            for (x, y) in [(5, 5), (10, 0), (18, 0), (10, 1), (18, 1), (26, 0), (27, 0), (26, 1), (28, 0), (29, 0), (3, 11),
                           (10, 10), (12, 10), (19, 13), (30, 14), (1, 17)] { p["\(x),\(y)"] = fb.pixel(x, y) }
            seen.set(p)
        }
        client.start()
        for _ in 0..<200 where seen.get.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let p = seen.get
        #expect(p["5,5"] == [50, 100, 200, 255], "fill, R G B on the wire")
        #expect(p["10,0"] == [255, 255, 255, 255] && p["18,0"] == [0, 0, 0, 255], "two colours, a bit a pixel")
        #expect(p["10,1"] == [0, 0, 0, 255] && p["18,1"] == [255, 255, 255, 255], "the next row")
        #expect(p["26,0"] == [0, 0, 255, 255] && p["27,0"] == [0, 255, 0, 255] && p["26,1"] == [0, 255, 0, 255], "four colours, same stream")
        #expect(p["28,0"] == [255, 0, 0, 255] && p["29,0"] == [0, 255, 255, 255])
        #expect(p["3,11"] == [7, 60, 90, 255], "copy, compressed")
        #expect(p["10,10"] == [9, 8, 7, 255], "copy, under 12 bytes")
        #expect(p["12,10"] == [10, 10, 10, 255] && p["19,13"] == [38, 38, 38, 255], "gradient")
        let jpeg = try #require(p["30,14"])
        #expect(abs(Int(jpeg[0]) - 220) <= 6 && abs(Int(jpeg[1]) - 160) <= 6 && abs(Int(jpeg[2]) - 40) <= 6, "JPEG: \(jpeg)")
        #expect(p["1,17"] == [199, 99, 9, 255], "a stream started again")
        client.close()
    }
}

nonisolated private final class Pixels: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: [UInt8]] = [:]
    var get: [String: [UInt8]] { lock.withLock { seen } }
    func set(_ p: [String: [UInt8]]) { lock.withLock { seen = p } }
}

nonisolated private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var n: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// A server that says each part of its script `every` apart, then closes; `gate` (what was sent, the part's index)
/// holds a part back until it says yes, and the connection fails if it never does.
nonisolated private final class PacedTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[UInt8]]
    private var _sent: [[UInt8]] = []
    private var at = 0
    private let every: Duration
    private let gate: @Sendable ([[UInt8]], Int) -> Bool
    var sent: [[UInt8]] { lock.withLock { _sent } }
    var done: Bool { lock.withLock { at >= script.count } }

    init(_ script: [[UInt8]], every: Duration, gate: @escaping @Sendable ([[UInt8]], Int) -> Bool = { _, _ in true }) {
        self.script = script
        self.every = every
        self.gate = gate
    }

    func send(_ bytes: [UInt8]) async throws { lock.withLock { _sent.append(bytes) } }

    func receive() async throws -> [UInt8] {
        try await Task.sleep(for: every)
        for _ in 0..<100 where !lock.withLock({ gate(_sent, at) }) { try await Task.sleep(for: .milliseconds(10)) }
        // Still shut after a second: the client never sent what the gate waits for, and the server hangs up.
        guard lock.withLock({ gate(_sent, at) }) else { throw URLError(.timedOut) }
        return try lock.withLock {
            guard at < script.count else { throw URLError(.networkConnectionLost) }
            defer { at += 1 }
            return script[at]
        }
    }

    func close() {}
}
