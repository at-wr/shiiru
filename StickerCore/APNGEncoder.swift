import Foundation
import CoreGraphics
import zlib

public enum APNGEncoder {

    public struct Frame {
        public let image: CGImage
        public let delay: Double

        public init(image: CGImage, delay: Double) {
            self.image = image
            self.delay = delay
        }
    }

    public static func encode(
        frames: [Frame], width: Int, height: Int, byteBudget: Int? = nil, maxColors: Int = 256
    ) -> Data? {
        guard !frames.isEmpty else { return nil }

        var rasters: [[UInt8]] = []
        rasters.reserveCapacity(frames.count)
        for frame in frames {
            guard let raster = rasterize(frame.image, width: width, height: height) else { return nil }
            rasters.append(raster)
        }

        let palette = buildPalette(rasters: rasters, maxColors: min(256, max(8, maxColors)))

        var lut = [Int16](repeating: -1, count: 32 * 32 * 32 * 16)
        var indexedFrames: [(pixels: [UInt8], delay: Double)] = []
        indexedFrames.reserveCapacity(rasters.count)
        for (raster, frame) in zip(rasters, frames) {
            let indexed = quantize(
                raster: raster, width: width, height: height, palette: palette, lut: &lut
            )

            if indexed == indexedFrames.last?.pixels {
                indexedFrames[indexedFrames.count - 1].delay += frame.delay
            } else {
                indexedFrames.append((indexed, frame.delay))
            }
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data()
        ihdr.appendBigEndian(UInt32(width))
        ihdr.appendBigEndian(UInt32(height))
        ihdr.append(contentsOf: [8, 3, 0, 0, 0])
        png.appendChunk("IHDR", ihdr)

        var plte = Data()
        var trns = Data()
        for color in palette {
            plte.append(contentsOf: [color.r, color.g, color.b])
            trns.append(color.a)
        }
        png.appendChunk("PLTE", plte)
        png.appendChunk("tRNS", trns)

        var sequence: UInt32 = 0
        let animated = indexedFrames.count > 1
        if animated {
            var actl = Data()
            actl.appendBigEndian(UInt32(indexedFrames.count))
            actl.appendBigEndian(UInt32(0))
            png.appendChunk("acTL", actl)
        }

        var previous: [UInt8]?
        for (frameIndex, frame) in indexedFrames.enumerated() {
            let indexed = frame.pixels

            var rect = (x: 0, y: 0, w: width, h: height)
            if let previous {
                rect = diffRect(previous, indexed, width: width, height: height)
            }

            var overCandidate: [UInt8]?
            if let previous {
                var over = indexed
                var valid = true
                validity: for y in rect.y..<(rect.y + rect.h) {
                    let row = y * width
                    for x in rect.x..<(rect.x + rect.w) {
                        let offset = row + x
                        if previous[offset] == indexed[offset] {
                            over[offset] = 0
                        } else if palette[Int(indexed[offset])].a != 255,
                                  palette[Int(previous[offset])].a != 0 {
                            valid = false
                            break validity
                        }
                    }
                }
                if valid { overCandidate = over }
            }
            previous = indexed

            guard var (compressed, blendOp) = zlibCompress(
                scanlines(of: indexed, rect: rect, width: width)
            ).map({ ($0, UInt8(0)) }) else { return nil }
            if let overCandidate,
               let overCompressed = zlibCompress(scanlines(of: overCandidate, rect: rect, width: width)),
               overCompressed.count < compressed.count {
                (compressed, blendOp) = (overCompressed, 1)
            }

            if animated {
                var fctl = Data()
                fctl.appendBigEndian(sequence); sequence += 1
                fctl.appendBigEndian(UInt32(rect.w))
                fctl.appendBigEndian(UInt32(rect.h))
                fctl.appendBigEndian(UInt32(rect.x))
                fctl.appendBigEndian(UInt32(rect.y))
                fctl.appendBigEndian(UInt16(max(1, Int(frame.delay * 100).clamped(to: 1...65535))))
                fctl.appendBigEndian(UInt16(100))
                fctl.append(contentsOf: [0, blendOp])
                png.appendChunk("fcTL", fctl)
            }

            if frameIndex == 0 {
                png.appendChunk("IDAT", compressed)
            } else {
                var fdat = Data()
                fdat.appendBigEndian(sequence); sequence += 1
                fdat.append(compressed)
                png.appendChunk("fdAT", fdat)
            }
            if let byteBudget, png.count > byteBudget {
                return nil
            }
        }

        png.appendChunk("IEND", Data())
        return png
    }

    public static func encodeStatic(_ image: CGImage, width: Int, height: Int) -> Data? {
        encode(frames: [Frame(image: image, delay: 0)], width: width, height: height)
    }

    private static func rasterize(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let result: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard result else { return nil }

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[offset + 3]
            if alpha != 0, alpha != 255 {
                let scale = 255.0 / Double(alpha)
                pixels[offset] = UInt8(min(255, Double(pixels[offset]) * scale))
                pixels[offset + 1] = UInt8(min(255, Double(pixels[offset + 1]) * scale))
                pixels[offset + 2] = UInt8(min(255, Double(pixels[offset + 2]) * scale))
            }
        }
        return pixels
    }

    struct PaletteColor { var r: UInt8; var g: UInt8; var b: UInt8; var a: UInt8 }

    private static func buildPalette(rasters: [[UInt8]], maxColors: Int) -> [PaletteColor] {

        var samples: [(UInt8, UInt8, UInt8, UInt8)] = []
        let totalPixels = rasters.reduce(0) { $0 + $1.count / 4 }
        let step = max(1, totalPixels / 200_000)
        var counter = 0
        for raster in rasters {
            for offset in stride(from: 0, to: raster.count, by: 4) {
                counter += 1
                if counter % step != 0 { continue }
                if raster[offset + 3] < 8 { continue }
                samples.append((raster[offset], raster[offset + 1], raster[offset + 2], raster[offset + 3]))
            }
        }

        var palette: [PaletteColor] = [PaletteColor(r: 0, g: 0, b: 0, a: 0)]
        guard !samples.isEmpty else { return palette }

        var boxes: [[(UInt8, UInt8, UInt8, UInt8)]] = [samples]
        while boxes.count < maxColors - 1 {

            var bestBox = -1
            var bestRange = -1
            var bestChannel = 0
            for (index, box) in boxes.enumerated() where box.count > 1 {
                var minimums = [255, 255, 255, 255], maximums = [0, 0, 0, 0]
                for pixel in box {
                    let channels = [Int(pixel.0), Int(pixel.1), Int(pixel.2), Int(pixel.3)]
                    for channel in 0..<4 {
                        minimums[channel] = min(minimums[channel], channels[channel])
                        maximums[channel] = max(maximums[channel], channels[channel])
                    }
                }
                for channel in 0..<4 {
                    let range = maximums[channel] - minimums[channel]
                    if range > bestRange {
                        bestRange = range
                        bestBox = index
                        bestChannel = channel
                    }
                }
            }
            guard bestBox >= 0, bestRange > 0 else { break }

            var box = boxes.remove(at: bestBox)
            box.sort { lhs, rhs in
                let lhsChannels = [lhs.0, lhs.1, lhs.2, lhs.3]
                let rhsChannels = [rhs.0, rhs.1, rhs.2, rhs.3]
                return lhsChannels[bestChannel] < rhsChannels[bestChannel]
            }
            let middle = box.count / 2
            boxes.append(Array(box[..<middle]))
            boxes.append(Array(box[middle...]))
        }

        for box in boxes where !box.isEmpty {
            var sumR = 0, sumG = 0, sumB = 0, sumA = 0
            for pixel in box {
                sumR += Int(pixel.0); sumG += Int(pixel.1)
                sumB += Int(pixel.2); sumA += Int(pixel.3)
            }
            palette.append(PaletteColor(
                r: UInt8(sumR / box.count), g: UInt8(sumG / box.count),
                b: UInt8(sumB / box.count), a: UInt8(sumA / box.count)
            ))
        }

        refine(palette: &palette, samples: samples)
        return palette
    }

    private static func refine(palette: inout [PaletteColor], samples: [(UInt8, UInt8, UInt8, UInt8)]) {
        guard palette.count > 2 else { return }

        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, a = 0.0, weight = 0.0 }
        var histogram: [Int: Bucket] = [:]
        for pixel in samples {
            let key = ((Int(pixel.0) >> 3) << 12) | ((Int(pixel.1) >> 3) << 7)
                | ((Int(pixel.2) >> 3) << 2) | (Int(pixel.3) >> 6)
            var bucket = histogram[key] ?? Bucket()
            bucket.r += Double(pixel.0); bucket.g += Double(pixel.1)
            bucket.b += Double(pixel.2); bucket.a += Double(pixel.3)
            bucket.weight += 1
            histogram[key] = bucket
        }
        let buckets = histogram.values.map { bucket in
            (r: bucket.r / bucket.weight, g: bucket.g / bucket.weight,
             b: bucket.b / bucket.weight, a: bucket.a / bucket.weight, w: bucket.weight)
        }

        for _ in 0..<3 {
            var sums = [(r: Double, g: Double, b: Double, a: Double, w: Double)](
                repeating: (0, 0, 0, 0, 0), count: palette.count
            )
            for bucket in buckets {
                var best = 1
                var bestDistance = Double.infinity
                for index in 1..<palette.count {
                    let color = palette[index]
                    let dr = bucket.r - Double(color.r), dg = bucket.g - Double(color.g)
                    let db = bucket.b - Double(color.b), da = bucket.a - Double(color.a)
                    let distance = dr * dr + dg * dg + db * db + da * da * 2
                    if distance < bestDistance {
                        bestDistance = distance
                        best = index
                    }
                }
                sums[best].r += bucket.r * bucket.w; sums[best].g += bucket.g * bucket.w
                sums[best].b += bucket.b * bucket.w; sums[best].a += bucket.a * bucket.w
                sums[best].w += bucket.w
            }

            for index in 1..<palette.count where sums[index].w > 0 {
                palette[index] = PaletteColor(
                    r: UInt8((sums[index].r / sums[index].w).rounded()),
                    g: UInt8((sums[index].g / sums[index].w).rounded()),
                    b: UInt8((sums[index].b / sums[index].w).rounded()),
                    a: UInt8((sums[index].a / sums[index].w).rounded())
                )
            }
        }
    }

    private static func quantize(
        raster: [UInt8], width: Int, height: Int, palette: [PaletteColor], lut: inout [Int16]
    ) -> [UInt8] {
        var indexed = [UInt8](repeating: 0, count: width * height)

        var errors = [Double](repeating: 0, count: (width + 2) * 2 * 4)

        func nearest(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> UInt8 {

            let key = ((r >> 3) << 12) | ((g >> 3) << 7) | ((b >> 3) << 2) | (a >> 6)
            let cached = lut[key]
            if cached >= 0 { return UInt8(cached) }
            var best = 0
            var bestDistance = Int.max
            for (index, color) in palette.enumerated() {
                let dr = r - Int(color.r), dg = g - Int(color.g)
                let db = b - Int(color.b), da = a - Int(color.a)
                let distance = dr * dr + dg * dg + db * db + da * da * 2
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            lut[key] = Int16(best)
            return UInt8(best)
        }

        let rowStride = (width + 2) * 4
        for y in 0..<height {
            let currentRow = (y % 2) * rowStride
            let nextRow = ((y + 1) % 2) * rowStride

            for i in 0..<rowStride { errors[nextRow + i] = 0 }

            for x in 0..<width {
                let pixelOffset = (y * width + x) * 4
                let errorOffset = currentRow + (x + 1) * 4
                let alpha = Int(raster[pixelOffset + 3])

                if alpha < 8 {
                    indexed[y * width + x] = 0
                    continue
                }

                let r = (Double(raster[pixelOffset]) + errors[errorOffset]).clampedByte
                let g = (Double(raster[pixelOffset + 1]) + errors[errorOffset + 1]).clampedByte
                let b = (Double(raster[pixelOffset + 2]) + errors[errorOffset + 2]).clampedByte
                let a = (Double(alpha) + errors[errorOffset + 3]).clampedByte

                let paletteIndex = nearest(r, g, b, a)
                indexed[y * width + x] = paletteIndex
                let chosen = palette[Int(paletteIndex)]

                let deltas = [
                    Double(r) - Double(chosen.r),
                    Double(g) - Double(chosen.g),
                    Double(b) - Double(chosen.b),
                    Double(a) - Double(chosen.a),
                ]
                for channel in 0..<4 {
                    let error = deltas[channel]
                    errors[currentRow + (x + 2) * 4 + channel] += error * 7 / 16
                    errors[nextRow + x * 4 + channel] += error * 3 / 16
                    errors[nextRow + (x + 1) * 4 + channel] += error * 5 / 16
                    errors[nextRow + (x + 2) * 4 + channel] += error * 1 / 16
                }
            }
        }
        return indexed
    }

    private static func scanlines(of pixels: [UInt8], rect: (x: Int, y: Int, w: Int, h: Int), width: Int) -> Data {
        var data = Data(capacity: rect.h * (rect.w + 1))
        for row in rect.y..<(rect.y + rect.h) {
            data.append(0)
            pixels.withUnsafeBufferPointer { buffer in
                data.append(
                    UnsafeBufferPointer(
                        start: buffer.baseAddress! + row * width + rect.x,
                        count: rect.w
                    )
                )
            }
        }
        return data
    }

    private static func diffRect(
        _ old: [UInt8], _ new: [UInt8], width: Int, height: Int
    ) -> (x: Int, y: Int, w: Int, h: Int) {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where old[row + x] != new[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return (0, 0, 1, 1) }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    private static func zlibCompress(_ data: Data) -> Data? {
        let input = [UInt8](data)
        var outputSize = uLongf(compressBound(uLong(input.count)))
        var output = [UInt8](repeating: 0, count: Int(outputSize))
        let status = compress2(&output, &outputSize, input, uLong(input.count), Z_BEST_COMPRESSION)
        guard status == Z_OK else { return nil }
        return Data(output[0..<Int(outputSize)])
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    mutating func appendBigEndian(_ value: UInt16) {
        append(contentsOf: [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendChunk(_ type: String, _ payload: Data) {
        appendBigEndian(UInt32(payload.count))
        var body = Data(type.utf8)
        body.append(payload)
        append(body)
        appendBigEndian(Self.crc32(body))
    }

    static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Double {
    var clampedByte: Int { Swift.min(255, Swift.max(0, Int(self.rounded()))) }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
