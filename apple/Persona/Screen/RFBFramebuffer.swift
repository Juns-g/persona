import Compression
import CoreGraphics
import Foundation
import ImageIO

/// The Mac's screen as the native client holds it (RFBClient): BGRA, 4 bytes a pixel, rows packed, which is the
/// pixel format the client asks for (32 bits, depth 24, little-endian, red at bit 16) and what CVPixelBuffer's
/// 32BGRA takes as is. The encodings write into it: Raw, CopyRect, ZRLE, Tight.
nonisolated final class RFBFramebuffer: @unchecked Sendable {
    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: UnsafeMutablePointer<UInt8>
    var bytesPerRow: Int { width * 4 }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = .allocate(capacity: max(1, width * height * 4))
        pixels.initialize(repeating: 0, count: max(1, width * height * 4))
    }

    deinit { pixels.deallocate() }

    /// A new size (DesktopSize): black again.
    func resize(width: Int, height: Int) {
        pixels.deallocate()
        self.width = width
        self.height = height
        pixels = .allocate(capacity: max(1, width * height * 4))
        pixels.initialize(repeating: 0, count: max(1, width * height * 4))
    }

    private func inside(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bool {
        x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height
    }

    /// Raw: w·h pixels of 4 bytes, the client's format.
    func raw(x: Int, y: Int, w: Int, h: Int, _ data: UnsafeRawBufferPointer) {
        guard inside(x, y, w, h), data.count >= w * h * 4, let src = data.baseAddress else { return }
        for row in 0..<h {
            (pixels + ((y + row) * width + x) * 4).update(from: src.advanced(by: row * w * 4).assumingMemoryBound(to: UInt8.self), count: w * 4)
        }
    }

    /// CopyRect: from (sx, sy) to (x, y), overlapping or not.
    func copy(x: Int, y: Int, w: Int, h: Int, from sx: Int, _ sy: Int) {
        guard inside(x, y, w, h), inside(sx, sy, w, h) else { return }
        let rows = sy < y ? Array((0..<h).reversed()) : Array(0..<h)
        for row in rows {
            let to = pixels + ((y + row) * width + x) * 4, from = pixels + ((sy + row) * width + sx) * 4
            memmove(to, from, w * 4) // the rows may overlap
        }
    }

    func fill(x: Int, y: Int, w: Int, h: Int, b: UInt8, g: UInt8, r: UInt8) {
        guard inside(x, y, w, h) else { return }
        for row in 0..<h {
            var p = pixels + ((y + row) * width + x) * 4
            for _ in 0..<w {
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
                p += 4
            }
        }
    }

    func set(_ x: Int, _ y: Int, b: UInt8, g: UInt8, r: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return } // defense in depth: draw checks the rectangle
        let p = pixels + (y * width + x) * 4
        p[0] = b; p[1] = g; p[2] = r; p[3] = 255
    }

    /// The pixel at (x, y), BGRA (tests).
    func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(UnsafeBufferPointer(start: pixels + (y * width + x) * 4, count: 4)) }
}

/// One zlib stream that lasts the connection (ZRLE's, Tight's four): each rectangle's compressed part inflates to that
/// rectangle's bytes (the server flushes the stream at the end of each). Compression's ZLIB is raw DEFLATE, so the
/// stream's two-byte header is skipped first.
nonisolated final class RFBInflater {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var started = false
    private var headerLeft = 2
    private var out = [UInt8](repeating: 0, count: 1 << 16)

    deinit { if started { compression_stream_destroy(&stream) } }

    /// A new stream from the next byte on (Tight's reset bits).
    func reset() {
        if started { compression_stream_destroy(&stream) }
        started = false
        headerLeft = 2
    }

    /// The inflated bytes of one rectangle's compressed part.
    func inflate(_ compressed: [UInt8]) throws -> [UInt8] {
        if !started {
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw RFBZRLE.Failure.inflate }
            started = true
        }
        var input = compressed[...]
        let skip = min(headerLeft, input.count)
        input = input.dropFirst(skip)
        headerLeft -= skip
        var result: [UInt8] = []
        try input.withUnsafeBufferPointer { src in
            stream.src_ptr = src.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = src.count
            repeat {
                let produced = try out.withUnsafeMutableBufferPointer { dst -> Int in
                    stream.dst_ptr = dst.baseAddress!
                    stream.dst_size = dst.count
                    let status = compression_stream_process(&stream, 0)
                    guard status != COMPRESSION_STATUS_ERROR else { throw RFBZRLE.Failure.inflate }
                    return dst.count - stream.dst_size
                }
                result.append(contentsOf: out[0..<produced])
                if produced < out.count && stream.src_size == 0 { break }
            } while true
        }
        return result
    }
}

/// ZRLE (encoding 16): one zlib stream for the whole connection, each rectangle a length and its part of it, which
/// inflates to 64×64 tiles of 3-byte pixels (CPIXEL: the low three bytes of the client's format, B G R) in one of
/// raw, solid, packed palette, plain RLE or palette RLE.
nonisolated final class RFBZRLE {
    enum Failure: Error { case inflate, tile }

    private let stream = RFBInflater()

    /// The inflated bytes of one rectangle's compressed part.
    func inflate(_ compressed: [UInt8]) throws -> [UInt8] { try stream.inflate(compressed) }

    /// Draws a rectangle's inflated tiles. A rectangle that does not fit the framebuffer is the server's error; so
    /// is data that ends inside a tile or a palette index past the palette. Pixels are written straight into the
    /// framebuffer, a row at a time (#3067: per-pixel calls took most of the decode).
    func draw(_ data: [UInt8], x: Int, y: Int, w: Int, h: Int, into fb: RFBFramebuffer) throws {
        guard x >= 0, y >= 0, w >= 0, h >= 0, x + w <= fb.width, y + h <= fb.height else { throw Failure.tile }
        try data.withUnsafeBufferPointer { buffer in
            guard let src = buffer.baseAddress else {
                if w > 0, h > 0 { throw Failure.tile }
                return
            }
            let count = buffer.count, stride = fb.width * 4
            var at = 0
            func byte() throws -> UInt8 {
                guard at < count else { throw Failure.tile }
                defer { at += 1 }
                return src[at]
            }
            func run() throws -> Int {
                var n = 1
                while true {
                    let b = Int(try byte())
                    n += b
                    if b != 255 { return n }
                }
            }
            /// Up to 127 palette colours as BGRA words.
            var palette = [UInt32](repeating: 0, count: 128)
            func readPalette(_ n: Int) throws {
                guard at + n * 3 <= count else { throw Failure.tile }
                for i in 0..<n {
                    palette[i] = UInt32(src[at]) | UInt32(src[at + 1]) << 8 | UInt32(src[at + 2]) << 16 | 0xff00_0000
                    at += 3
                }
            }
            /// n pixels of colour c from pixel k of the tile on, across its rows.
            func fill(_ tile: UnsafeMutablePointer<UInt8>, tw: Int, from k: Int, _ n: Int, _ c: UInt32) {
                var k = k, left = n
                while left > 0 {
                    let row = k / tw, col = k % tw, span = min(left, tw - col)
                    let p = UnsafeMutableRawPointer(tile + row * stride + col * 4).assumingMemoryBound(to: UInt32.self)
                    for i in 0..<span { p[i] = c }
                    k += span
                    left -= span
                }
            }
            var ty = y
            while ty < y + h {
                let th = min(64, y + h - ty)
                var tx = x
                while tx < x + w {
                    let tw = min(64, x + w - tx), area = tw * th
                    let tile = fb.pixels + ty * stride + tx * 4
                    let sub = try byte()
                    switch sub {
                    case 0:
                        guard at + area * 3 <= count else { throw Failure.tile }
                        for j in 0..<th {
                            var p = tile + j * stride, s = src + at + j * tw * 3
                            for _ in 0..<tw {
                                p[0] = s[0]; p[1] = s[1]; p[2] = s[2]; p[3] = 255
                                p += 4; s += 3
                            }
                        }
                        at += area * 3
                    case 1:
                        try readPalette(1)
                        fill(tile, tw: tw, from: 0, area, palette[0])
                    case 2...16:
                        let n = Int(sub), bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4, mask = (1 << bits) - 1
                        try readPalette(n)
                        let rowBytes = (tw * bits + 7) / 8
                        guard at + rowBytes * th <= count else { throw Failure.tile }
                        for j in 0..<th {
                            let p = UnsafeMutableRawPointer(tile + j * stride).assumingMemoryBound(to: UInt32.self), r = src + at + j * rowBytes
                            for i in 0..<tw {
                                let bit = i * bits
                                let index = Int(r[bit >> 3] >> UInt8(8 - bits - bit & 7)) & mask
                                guard index < n else { throw Failure.tile }
                                p[i] = palette[index]
                            }
                        }
                        at += rowBytes * th
                    case 128:
                        var i = 0
                        while i < area {
                            try readPalette(1)
                            let c = palette[0], n = try run()
                            fill(tile, tw: tw, from: i, min(n, area - i), c)
                            i += n
                        }
                    case 130...255:
                        let n = Int(sub - 128)
                        try readPalette(n)
                        var i = 0
                        while i < area {
                            let v = try byte()
                            let length = v & 128 != 0 ? try run() : 1
                            let index = Int(v & 127)
                            guard index < n else { throw Failure.tile }
                            fill(tile, tw: tw, from: i, min(length, area - i), palette[index])
                            i += length
                        }
                    default:
                        throw Failure.tile
                    }
                    tx += 64
                }
                ty += 64
            }
        }
    }
}

/// Tight (encoding 7, #3067): per rectangle a fill colour, a JPEG, or pixels through one of four zlib streams after a
/// filter (copy, a palette of up to 256 colours, or gradient prediction). Pixels here are TPIXELs: 3 bytes, R G B,
/// which is what a 32-bit depth-24 format with 8 bits a colour sends. The JPEG is what makes it lossy: the server
/// sends one for a photo-like area when the client asked for a quality level (-32 + 0…9), and lossless data otherwise.
nonisolated final class RFBTight {
    enum Failure: Error { case rect, filter, data, jpeg }

    private let streams = [RFBInflater(), RFBInflater(), RFBInflater(), RFBInflater()]

    /// The compression control byte's low four bits: streams to start again before this rectangle.
    func reset(_ control: UInt8) {
        for i in 0..<4 where control & (1 << i) != 0 { streams[i].reset() }
    }

    func inflate(_ compressed: [UInt8], stream: Int) throws -> [UInt8] { try streams[stream & 3].inflate(compressed) }

    /// The bytes a basic rectangle's data takes after its filter: data under 12 bytes comes as it is, the rest compressed.
    static func size(filter: UInt8, colours: Int, w: Int, h: Int) -> Int {
        switch filter {
        case 1: colours == 2 ? (w + 7) / 8 * h : w * h
        default: w * h * 3
        }
    }

    private static func check(_ fb: RFBFramebuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int) throws {
        guard x >= 0, y >= 0, w >= 0, h >= 0, x + w <= fb.width, y + h <= fb.height else { throw Failure.rect }
    }

    /// A basic rectangle's data drawn: `filter` 0 copy, 1 palette (`palette`: its colours, 3 bytes each), 2 gradient.
    static func draw(filter: UInt8, _ data: [UInt8], palette: [UInt8], x: Int, y: Int, w: Int, h: Int, into fb: RFBFramebuffer) throws {
        try check(fb, x, y, w, h)
        let colours = palette.count / 3
        guard data.count >= size(filter: filter, colours: colours, w: w, h: h) else { throw Failure.data }
        let row = fb.bytesPerRow
        try data.withUnsafeBufferPointer { src in
            switch filter {
            case 0:
                for j in 0..<h {
                    var p = fb.pixels + (y + j) * row + x * 4
                    var s = j * w * 3
                    for _ in 0..<w {
                        p[0] = src[s + 2]; p[1] = src[s + 1]; p[2] = src[s]; p[3] = 255
                        p += 4; s += 3
                    }
                }
            case 1:
                guard (1...256).contains(colours) else { throw Failure.filter }
                for j in 0..<h {
                    var p = fb.pixels + (y + j) * row + x * 4
                    for i in 0..<w {
                        let index = colours == 2 ? Int(src[j * ((w + 7) / 8) + i / 8] >> (7 - UInt8(i % 8))) & 1 : Int(src[j * w + i])
                        guard index < colours else { throw Failure.data }
                        p[0] = palette[index * 3 + 2]; p[1] = palette[index * 3 + 1]; p[2] = palette[index * 3]; p[3] = 255
                        p += 4
                    }
                }
            case 2:
                // Each colour predicted from the pixels left, above and above-left (0 outside the rectangle), clamped;
                // the data is the difference, modulo 256.
                var above = [Int](repeating: 0, count: (w + 1) * 3), here = above
                for j in 0..<h {
                    var p = fb.pixels + (y + j) * row + x * 4
                    for i in 0..<w {
                        for k in 0..<3 {
                            let predicted = min(max(here[i * 3 + k] + above[(i + 1) * 3 + k] - above[i * 3 + k], 0), 255)
                            here[(i + 1) * 3 + k] = (predicted + Int(src[(j * w + i) * 3 + k])) & 255
                        }
                        p[0] = UInt8(here[(i + 1) * 3 + 2]); p[1] = UInt8(here[(i + 1) * 3 + 1]); p[2] = UInt8(here[(i + 1) * 3]); p[3] = 255
                        p += 4
                    }
                    swap(&above, &here)
                    for k in 0..<3 { here[k] = 0 }
                }
            default:
                throw Failure.filter
            }
        }
    }

    /// A JPEG drawn into its rectangle, through ImageIO, straight into the framebuffer's memory.
    static func jpeg(_ data: [UInt8], x: Int, y: Int, w: Int, h: Int, into fb: RFBFramebuffer) throws {
        try check(fb, x, y, w, h)
        guard w > 0, h > 0 else { return }
        guard let source = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let context = CGContext(data: fb.pixels + y * fb.bytesPerRow + x * 4, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: fb.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure.jpeg }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
}
