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

    static let pipelineVersion = 11

    /// Total decoded pixels across all frames the transcript renderer may
    /// hold at once. Sized so that even 90-frame stickers keep a canvas at
    /// or above the display floor (Messages renders animated stickers
    /// proportionally to their pixel size — small canvases display small).
    static let playbackPixelBudget = 12_000_000

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

    static func convertStaticImage(at path: String, fillCanvas fill: Bool = false) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ShiiruError.conversionFailed }

        if fill {
            // Custom emoji: crop the padding, then upscale to the full
            // canvas — Messages renders stickers at a fixed transcript
            // size, so small canvases only add blur, never smallness.
            image = fillCanvas([image], side: 512).first ?? image
            image = scale(image, toFit: 512, exact: true) ?? image
        }

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
    static func convertTGS(
        at path: String,
        fillCanvas fill: Bool = false,
        profile: TranscodeProfile = TranscodePreset.balanced.profile
    ) async throws -> Output {
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try gunzip(raw)
        let animation = try LottieAnimation.from(data: json)

        let duration = min(animation.duration, 3.0)
        let targetFrames = max(2, Int((duration * min(30, animation.framerate)).rounded()))
        var planner = StickerEncodePlanner(
            sourceFPS: animation.framerate,
            budget: maxFileSize,
            maxSide: min(playbackSideCap(frameCount: targetFrames), profile.sideCap),
            minSide: profile.minSide,
            fpsFloor: profile.fpsFloor
        )
        var plan: (side: Int, fps: Double)? = (planner.side, planner.fps)

        let aspect = animation.size.width / max(animation.size.height, 1)

        var firstFrame: CGImage?
        while let attempt = plan {
            try Task.checkCancellation()
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
            var cgFrames = frames.compactMap { $0.cgImage }
            if fill {
                // Custom emoji: crop away the shared transparent padding so
                // the glyph fills the sticker instead of floating in it.
                cgFrames = fillCanvas(cgFrames, side: attempt.side)
            }
            guard let canvas = cgFrames.first else { break }
            firstFrame = firstFrame ?? canvas

            let data = await Task.detached(priority: .userInitiated, operation: {
                APNGEncoder.encode(
                    frames: cgFrames.map { APNGEncoder.Frame(image: $0, delay: delay) },
                    width: canvas.width,
                    height: canvas.height,
                    byteBudget: maxFileSize * 5 / 2
                )
            }).value
            if let data, data.count <= maxFileSize {
                return labeledOutput(data)
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

    static func convertWebm(
        at path: String,
        fillCanvas fill: Bool = false,
        profile: TranscodeProfile = TranscodePreset.balanced.profile
    ) throws -> Output {
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
            maxSide: min(playbackSideCap(frameCount: targetFrames), profile.sideCap),
            minSide: profile.minSide,
            fpsFloor: profile.fpsFloor
        )
        var plan: (side: Int, fps: Double)? = (planner.side, planner.fps)

        var firstFrame: CGImage?
        while let attempt = plan {
            try Task.checkCancellation()
            let count = min(decoded.count, max(2, Int((duration * attempt.fps).rounded())))
            let picked = (0..<count).map { decoded[$0 * decoded.count / count] }
            let delay = duration / Double(picked.count)
            var images = picked.map(\.image)
            if fill { images = fillCanvas(images, side: attempt.side) }
            let frames: [APNGEncoder.Frame] = images.compactMap { image in
                guard let scaled = scale(image, toFit: attempt.side, exact: true) else { return nil }
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
                return labeledOutput(data)
            }
            plan = planner.next(measuredSize: data?.count)
        }

        // Emergency tiers: keeping the animation beats both display size
        // and palette fidelity; how the two trade off comes from the
        // user's transcode preset. Overshooting attempts skip a rung so
        // dense stickers don't crawl the whole ladder to find their tier.
        let lastStands = profile.lastStands
        var standIndex = 0
        while standIndex < lastStands.count {
            try Task.checkCancellation()
            let stand = lastStands[standIndex]
            let count = min(decoded.count, max(2, Int((duration * stand.fps).rounded())))
            let picked = (0..<count).map { decoded[$0 * decoded.count / count] }
            let delay = duration / Double(picked.count)
            var images = picked.map(\.image)
            if fill { images = fillCanvas(images, side: stand.side) }
            let frames: [APNGEncoder.Frame] = images.compactMap { image in
                guard let scaled = scale(image, toFit: stand.side, exact: true) else { return nil }
                return APNGEncoder.Frame(image: scaled, delay: delay)
            }
            guard let first = frames.first, frames.count > 1 else { break }
            let data = APNGEncoder.encode(
                frames: frames,
                width: first.image.width,
                height: first.image.height,
                byteBudget: maxFileSize * 2,
                maxColors: stand.colors
            )
            if let data, data.count <= maxFileSize {
                return labeledOutput(data)
            }
            let overshoot = data.map { Double($0.count) / Double(maxFileSize) } ?? 3
            standIndex += overshoot > 2 ? 2 : 1
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

    /// Labels encoded output by what the encoder actually wrote, not by the
    /// frame count that went in: APNGEncoder merges frames that quantize
    /// identically, so a subtle animation can collapse to a single frame.
    /// Marking that file animated leaves the panel waiting on frames that
    /// don't exist.
    private static func labeledOutput(_ data: Data) -> Output {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1
        else { return .png(data) }
        return .apng(data)
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

    /// MP4 saved animations: decode sequentially with AVAssetReader — one
    /// hardware decoder session for the whole clip — and encode as APNG.
    /// The old AVAssetImageGenerator path opened a fresh decoder per
    /// sampled frame (thousands of one-shot sessions per pack), which was
    /// the dominant cost of a GIF sync.
    static func convertVideo(at path: String) async throws -> Output {
        let url = URL(fileURLWithPath: path)
        // AVFoundation wants a recognizable extension.
        let linked = url.deletingPathExtension().appendingPathExtension("mp4")
        if linked != url, !FileManager.default.fileExists(atPath: linked.path) {
            try? FileManager.default.linkItem(at: url, to: linked)
        }
        let asset = AVURLAsset(url: FileManager.default.fileExists(atPath: linked.path) ? linked : url)
        let seconds = min((try? await asset.load(.duration).seconds) ?? 3, 5)
        guard seconds > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first
        else { throw ShiiruError.conversionFailed }
        let transform = (try? await track.load(.preferredTransform)) ?? .identity

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ShiiruError.conversionFailed }

        let targetFPS = 18.0
        var sampled: [(image: CGImage, time: Double)] = []
        var nextTime = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time >= nextTime else { continue }
            nextTime = time + 1 / targetFPS
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  let image = cgImage(from: buffer, transform: transform)
            else { continue }
            sampled.append((scale(image, toFit: 512) ?? image, time))
        }
        guard !sampled.isEmpty else { throw ShiiruError.conversionFailed }
        // Delays come from actual presentation times so sources slower than
        // the sampling grid keep their pacing. (Sorted defensively: decoded
        // frames arrive in decode order, which differs from presentation
        // order for streams with frame reordering.)
        sampled.sort { $0.time < $1.time }
        var frames: [(CGImage, Double)] = []
        for (index, frame) in sampled.enumerated() {
            let end = index + 1 < sampled.count ? sampled[index + 1].time : seconds
            frames.append((frame.image, max(end - frame.time, 0.02)))
        }
        return try encodeFrameLadder(frames)
    }

    private static func cgImage(from buffer: CVPixelBuffer, transform: CGAffineTransform) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                  data: base,
                  width: CVPixelBufferGetWidth(buffer),
                  height: CVPixelBufferGetHeight(buffer),
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let image = context.makeImage()
        else { return nil }
        return oriented(image, transform: transform)
    }

    /// Applies the track's preferredTransform the way
    /// AVAssetImageGenerator's appliesPreferredTrackTransform did. Telegram
    /// GIF MP4s are transcoded server-side and carry no rotation; this
    /// covers the occasional camera-shot saved animation.
    private static func oriented(_ image: CGImage, transform: CGAffineTransform) -> CGImage? {
        guard transform != .identity else { return image }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let rect = CGRect(x: 0, y: 0, width: width, height: height).applying(transform)
        guard let context = CGContext(
            data: nil,
            width: Int(rect.width.rounded()), height: Int(rect.height.rounded()),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.translateBy(x: -rect.origin.x, y: -rect.origin.y)
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Shared quality ladder over pre-decoded frames. Size-first attempts
    /// keep the full palette; the emergency tiers then trade color depth
    /// away, because any animation beats a static fallback (dense
    /// photographic GIFs never fit 500 KB at 256 colors).
    private static func encodeFrameLadder(_ source: [(CGImage, Double)]) throws -> Output {
        guard !source.isEmpty else { throw ShiiruError.conversionFailed }
        let attempts: [(side: Int, maxFrames: Int, colors: Int)] = [
            (448, 60, 256), (408, 45, 256), (384, 36, 256), (352, 27, 256),
            (320, 20, 256), (320, 14, 256),
            (320, 14, 128), (320, 12, 96), (288, 12, 64),
            (256, 10, 48), (224, 8, 48),
        ]
        let totalDuration = source.reduce(0) { $0 + $1.1 }
        var firstFrame: CGImage?
        for attempt in attempts {
            try Task.checkCancellation()
            // Round the sampling step up: dividing down lets a 40-frame
            // source keep 20 frames on a 14-frame rung, making the rung a
            // repeat of the previous one instead of a smaller attempt.
            let step = max(1, (source.count + attempt.maxFrames - 1) / attempt.maxFrames)
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
                byteBudget: maxFileSize,
                maxColors: attempt.colors
            ), data.count <= maxFileSize {
                return labeledOutput(data)
            }
        }
        if let first = firstFrame,
           let data = APNGEncoder.encodeStatic(first, width: first.width, height: first.height),
           data.count <= maxFileSize {
            return .png(data)
        }
        throw ShiiruError.conversionFailed
    }

    // MARK: - Emoji canvas filling

    /// Union alpha bounding box across frames (sampled every other pixel).
    private static func contentBounds(of frames: [CGImage]) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for image in frames {
            let w = image.width, h = image.height
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(
                    data: raw.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { continue }
            for y in stride(from: 0, to: h, by: 2) {
                for x in stride(from: 0, to: w, by: 2) where pixels[(y * w + x) * 4 + 3] > 12 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: max(0, minX - 3), y: max(0, minY - 3),
            width: min(frames[0].width, maxX - minX + 7),
            height: min(frames[0].height, maxY - minY + 7)
        )
    }

    /// Custom emoji ship on canvases their artwork often barely occupies;
    /// crop every frame to the shared content box (plus a small margin) and
    /// upscale so the glyph fills the sticker instead of floating in it.
    static func fillCanvas(_ frames: [CGImage], side: Int) -> [CGImage] {
        guard let bounds = contentBounds(of: frames) else { return frames }
        let canvas = CGFloat(frames[0].width)
        // Leave well-composed art alone.
        if bounds.width >= canvas * 0.86 && bounds.height >= canvas * 0.86 { return frames }
        return frames.map { image in
            guard let cropped = image.cropping(to: bounds),
                  let scaled = scale(cropped, toFit: side, exact: true)
            else { return image }
            return scaled
        }
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
