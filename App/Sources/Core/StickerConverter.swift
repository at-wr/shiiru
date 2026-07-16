import Foundation
import AVFoundation
import StickerCore
import UIKit
import ImageIO
import UniformTypeIdentifiers
import Compression
import Lottie

enum StickerConverter {

    static let maxFileSize = 500_000

    static let pipelineVersion = 7

    static let playbackPixelBudget = 8_000_000

    static func playbackSideCap(frameCount: Int) -> Int {
        min(512, Int(Double(playbackPixelBudget / max(frameCount, 1)).squareRoot()))
    }

    enum Output {
        case png(Data)
        case apng(Data)
        /// Pass-through GIF (MSSticker accepts GIF natively).
        case gif(Data)

        var data: Data {
            switch self {
            case .png(let data), .apng(let data), .gif(let data): return data
            }
        }

        var isAnimated: Bool {
            switch self {
            case .png: return false
            case .apng, .gif: return true
            }
        }

        var fileExtension: String {
            if case .gif = self { return "gif" }
            return "png"
        }
    }

    static func convertStaticImage(at path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ShiiruError.conversionFailed }

        if let scaled = scale(image, toFit: 512),
           let lossless = encodePNG(frames: [(scaled, 0)], loopCount: nil),
           lossless.count <= maxFileSize {
            return lossless
        }
        for side in [512, 408, 320] {
            guard let scaled = scale(image, toFit: side) else { continue }
            if let quantized = APNGEncoder.encodeStatic(
                scaled, width: scaled.width, height: scaled.height
            ), quantized.count <= maxFileSize {
                return quantized
            }
        }
        throw ShiiruError.conversionFailed
    }

    @MainActor
    static func convertTGS(at path: String) async throws -> Output {
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try gunzip(raw)
        let animation = try LottieAnimation.from(data: json)

        let duration = min(animation.duration, 3.0)
        let targetFrames = max(2, Int((duration * min(30, animation.framerate)).rounded()))
        var planner = StickerEncodePlanner(
            sourceFPS: animation.framerate,
            budget: maxFileSize,
            maxSide: playbackSideCap(frameCount: targetFrames)
        )
        var plan: (side: Int, fps: Double)? = (planner.side, planner.fps)

        let aspect = animation.size.width / max(animation.size.height, 1)

        var firstFrame: CGImage?
        while let attempt = plan {
            let frameCount = max(2, Int((duration * attempt.fps).rounded()))
            let delay = duration / Double(frameCount)
            let side = CGFloat(attempt.side)
            let width = aspect >= 1 ? attempt.side : max(1, Int((side * aspect).rounded()))
            let height = aspect >= 1 ? max(1, Int((side / aspect).rounded())) : attempt.side
            let frames = await renderFrames(
                animation: animation,
                width: width,
                height: height,
                count: frameCount
            )
            guard !frames.isEmpty else { break }
            let cgFrames = frames.compactMap { $0.cgImage }
            firstFrame = firstFrame ?? cgFrames.first

            let data = await Task.detached(priority: .userInitiated, operation: {
                APNGEncoder.encode(
                    frames: cgFrames.map { APNGEncoder.Frame(image: $0, delay: delay) },
                    width: width,
                    height: height,
                    byteBudget: maxFileSize * 5 / 2
                )
            }).value
            if let data, data.count <= maxFileSize {
                return .apng(data)
            }
            plan = planner.next(measuredSize: data?.count)
        }

        if let first = firstFrame {
            let data = await Task.detached(priority: .userInitiated, operation: {
                APNGEncoder.encodeStatic(first, width: first.width, height: first.height)
            }).value
            if let data, data.count <= maxFileSize {
                return .png(data)
            }
        }
        throw ShiiruError.conversionFailed
    }

    @MainActor
    private static func renderFrames(animation: LottieAnimation, width: Int, height: Int, count: Int) async -> [UIImage] {
        let configuration = LottieConfiguration(renderingEngine: .mainThread)
        let view = LottieAnimationView(animation: animation, configuration: configuration)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .stop
        view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: view.bounds.size, format: format)

        var frames: [UIImage] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            view.currentProgress = CGFloat(index) / CGFloat(count)
            view.forceDisplayUpdate()
            let image = renderer.image { context in
                view.layer.render(in: context.cgContext)
            }
            frames.append(image)

            await Task.yield()
        }
        return frames
    }

    static func convertWebm(at path: String) throws -> Output {
        guard let decoded = WebmStickerDecoder.decodeFrames(atPath: path, maxFrames: 90),
              !decoded.isEmpty
        else { throw ShiiruError.conversionFailed }

        var duration = max(decoded.last!.timestamp, 0.1)

        if decoded.count > 4, duration < Double(decoded.count) / 60.0 {
            duration = Double(decoded.count) / 30.0
        }

        let sourceFPS = Double(decoded.count) / duration
        let targetFrames = max(2, Int((duration * min(30, sourceFPS)).rounded()))
        var planner = StickerEncodePlanner(
            sourceFPS: sourceFPS,
            budget: maxFileSize,
            maxSide: playbackSideCap(frameCount: targetFrames)
        )
        var plan: (side: Int, fps: Double)? = (planner.side, planner.fps)

        var firstFrame: CGImage?
        while let attempt = plan {

            let count = min(decoded.count, max(2, Int((duration * attempt.fps).rounded())))
            let picked = (0..<count).map { decoded[$0 * decoded.count / count] }
            let delay = duration / Double(picked.count)
            let frames: [APNGEncoder.Frame] = picked.compactMap { frame in
                guard let scaled = scale(frame.image, toFit: attempt.side, exact: true) else { return nil }
                return APNGEncoder.Frame(image: scaled, delay: delay)
            }
            guard let first = frames.first else { break }
            firstFrame = firstFrame ?? first.image
            let data = APNGEncoder.encode(
                frames: frames,
                width: first.image.width,
                height: first.image.height,
                byteBudget: maxFileSize * 5 / 2
            )
            if let data, data.count <= maxFileSize {
                return frames.count > 1 ? .apng(data) : .png(data)
            }
            plan = planner.next(measuredSize: data?.count)
        }

        let lastStands: [(side: Int, fps: Double, colors: Int)] = [
            (192, 12, 128), (160, 16, 96), (160, 12, 128), (160, 12, 96), (160, 12, 64),
        ]
        for stand in lastStands {
            let count = min(decoded.count, max(2, Int((duration * stand.fps).rounded())))
            let picked = (0..<count).map { decoded[$0 * decoded.count / count] }
            let delay = duration / Double(picked.count)
            let frames: [APNGEncoder.Frame] = picked.compactMap { frame in
                guard let scaled = scale(frame.image, toFit: stand.side, exact: true) else { return nil }
                return APNGEncoder.Frame(image: scaled, delay: delay)
            }
            if let first = frames.first, frames.count > 1,
               let data = APNGEncoder.encode(
                   frames: frames,
                   width: first.image.width,
                   height: first.image.height,
                   byteBudget: maxFileSize,
                   maxColors: stand.colors
               ), data.count <= maxFileSize {
                return .apng(data)
            }
        }

        if let first = firstFrame,
           let data = APNGEncoder.encodeStatic(first, width: first.width, height: first.height),
           data.count <= maxFileSize {
            return .png(data)
        }
        throw ShiiruError.conversionFailed
    }

    private static func encodePNG(frames: [(CGImage, Double)], loopCount: Int?) -> Data? {
        guard !frames.isEmpty else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, frames.count, nil
        ) else { return nil }

        if let loopCount {
            let properties = [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGLoopCount: loopCount
                ]
            ] as CFDictionary
            CGImageDestinationSetProperties(destination, properties)
        }

        for (image, delay) in frames {
            var frameProperties: CFDictionary?
            if frames.count > 1 {
                frameProperties = [
                    kCGImagePropertyPNGDictionary: [
                        kCGImagePropertyAPNGDelayTime: delay,
                        kCGImagePropertyAPNGUnclampedDelayTime: delay
                    ]
                ] as CFDictionary
            }
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func scale(_ image: CGImage, toFit side: Int, exact: Bool = false) -> CGImage? {
        let width = image.width, height = image.height
        if !exact, max(width, height) <= side { return image }
        if exact, max(width, height) == side { return image }
        let ratio = CGFloat(side) / CGFloat(max(width, height))
        let newSize = CGSize(
            width: (CGFloat(width) * ratio).rounded(),
            height: (CGFloat(height) * ratio).rounded()
        )
        guard let context = CGContext(
            data: nil,
            width: Int(newSize.width), height: Int(newSize.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: newSize))
        return context.makeImage()
    }


    // MARK: - Saved GIFs (animated GIF / MP4 in, GIF or APNG out)

    /// Animated GIF: pass through untouched when already within the sticker
    /// budget (best quality), otherwise re-encode through the APNG ladder.
    static func convertAnimatedImage(at path: String) throws -> Output {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw ShiiruError.conversionFailed }

        let count = CGImageSourceGetCount(source)
        if count > 1, data.count <= maxFileSize {
            return .gif(data)
        }

        var frames: [(CGImage, Double)] = []
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            var delay = 0.1
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
            frames.append((image, max(delay, 0.02)))
        }
        return try encodeFrameLadder(frames)
    }

    /// MP4 saved animations: decode with AVFoundation, encode as APNG.
    static func convertVideo(at path: String) async throws -> Output {
        let url = URL(fileURLWithPath: path)
        // AVFoundation wants a recognizable extension.
        let linked = url.deletingPathExtension().appendingPathExtension("mp4")
        if linked != url, !FileManager.default.fileExists(atPath: linked.path) {
            try? FileManager.default.linkItem(at: url, to: linked)
        }
        let asset = AVURLAsset(url: FileManager.default.fileExists(atPath: linked.path) ? linked : url)
        let seconds = min((try? await asset.load(.duration).seconds) ?? 3, 5)
        guard seconds > 0 else { throw ShiiruError.conversionFailed }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 512, height: 512)

        let fps = 18.0
        let frameCount = max(2, Int(seconds * fps))
        let delay = seconds / Double(frameCount)
        var frames: [(CGImage, Double)] = []
        for index in 0..<frameCount {
            let time = CMTime(seconds: Double(index) * delay, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                frames.append((image, delay))
            }
        }
        return try encodeFrameLadder(frames)
    }

    /// Shared quality ladder over pre-decoded frames.
    private static func encodeFrameLadder(_ source: [(CGImage, Double)]) throws -> Output {
        guard !source.isEmpty else { throw ShiiruError.conversionFailed }
        let attempts: [(side: Int, maxFrames: Int)] = [
            (408, 60), (352, 45), (320, 36), (288, 27), (256, 20)
        ]
        let totalDuration = source.reduce(0) { $0 + $1.1 }
        var firstFrame: CGImage?
        for attempt in attempts {
            let step = max(1, source.count / attempt.maxFrames)
            let picked = stride(from: 0, to: source.count, by: step).map { source[$0] }
            let delay = totalDuration / Double(picked.count)
            let frames: [APNGEncoder.Frame] = picked.compactMap { frame, _ in
                guard let scaled = scale(frame, toFit: attempt.side, exact: true) else { return nil }
                return APNGEncoder.Frame(image: scaled, delay: delay)
            }
            guard let first = frames.first else { continue }
            firstFrame = firstFrame ?? first.image
            if let data = APNGEncoder.encode(
                frames: frames,
                width: first.image.width,
                height: first.image.height,
                byteBudget: maxFileSize
            ), data.count <= maxFileSize {
                return frames.count > 1 ? .apng(data) : .png(data)
            }
        }
        if let first = firstFrame,
           let data = APNGEncoder.encodeStatic(first, width: first.width, height: first.height),
           data.count <= maxFileSize {
            return .png(data)
        }
        throw ShiiruError.conversionFailed
    }

    static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 8 else {

            return data
        }
        let flags = data[3]
        var offset = 10
        if flags & 0x04 != 0 {
            let extraLength = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < data.count - 8 else { throw ShiiruError.conversionFailed }

        let isize = data.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let capacity = max(Int(isize), 64 * 1024)

        let deflated = data.subdata(in: offset..<(data.count - 8))
        let result = deflated.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data? in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            let written = compression_decode_buffer(
                buffer, capacity,
                input.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
                nil, COMPRESSION_ZLIB
            )
            guard written > 0 else { return nil }
            return Data(bytes: buffer, count: written)
        }
        guard let result else { throw ShiiruError.conversionFailed }
        return result
    }
}
