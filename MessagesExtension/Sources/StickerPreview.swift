import UIKit
import ImageIO

/// Lightweight sticker preview rendering for the panel grid.
///
/// MSStickerView is deliberately avoided here: its preview cache is keyed by
/// file name and goes stale (rdar://27751901, packs visually mixing up), and
/// it decodes every animation frame at full resolution (~23 MB for a 500 KB
/// sticker, rdar://35688045) — a handful of animating cells could OOM the
/// extension. Instead previews are decoded down-sampled with ImageIO and
/// animated by one shared display link across all visible cells, the same
/// strategy Telegram's entity keyboard uses.
enum StickerPreview {

    /// Longest side, in pixels, for animation frames. Playback runs slightly
    /// below cell resolution; the static thumbnail stays sharp at rest.
    static let animationPixelSide: CGFloat = 160

    struct Animation {
        let frames: [CGImage]
        /// Accumulated timestamps: time at which frame i ends.
        let frameEnds: [Double]
        let duration: Double

        var cost: Int {
            frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        }

        func frameIndex(at time: Double) -> Int {
            let t = time.truncatingRemainder(dividingBy: duration)
            // Frame counts are small (<= 90); linear scan is cheap and
            // avoids per-tick allocations.
            for (index, end) in frameEnds.enumerated() where t < end {
                return index
            }
            return frames.count - 1
        }
    }

    // Messages extensions run under a much lower memory ceiling than apps;
    // both caches together stay well below it and NSCache additionally
    // responds to memory pressure.
    private static let thumbnailCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 16 << 20
        return cache
    }()

    private static let animationCache: NSCache<NSURL, Box<Animation>> = {
        let cache = NSCache<NSURL, Box<Animation>>()
        cache.totalCostLimit = 32 << 20
        return cache
    }()

    final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private static let decodeQueue = DispatchQueue(
        label: "dev.alany.shiiru.sticker-decode", qos: .userInitiated, attributes: .concurrent
    )

    static func cachedThumbnail(for url: URL) -> UIImage? {
        thumbnailCache.object(forKey: url as NSURL)
    }

    /// Decodes a down-sampled static thumbnail (first frame) off-main.
    static func thumbnail(for url: URL, pixelSide: CGFloat, completion: @escaping (UIImage?) -> Void) {
        if let cached = thumbnailCache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }
        decodeQueue.async {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSide,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let image = UIImage(cgImage: cg)
            thumbnailCache.setObject(
                image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height
            )
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Decodes all frames of an animated sticker, down-sampled for playback.
    /// Returns nil for static images.
    static func animation(for url: URL, completion: @escaping (Animation?) -> Void) {
        if let cached = animationCache.object(forKey: url as NSURL) {
            completion(cached.value)
            return
        }
        decodeQueue.async {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let count = CGImageSourceGetCount(source)
            guard count > 1 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: animationPixelSide,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            var frames: [CGImage] = []
            var ends: [Double] = []
            var total: Double = 0
            frames.reserveCapacity(count)
            ends.reserveCapacity(count)
            for index in 0..<count {
                guard let cg = CGImageSourceCreateThumbnailAtIndex(
                    source, index, options as CFDictionary
                ) else { continue }
                total += frameDelay(source: source, index: index)
                frames.append(cg)
                ends.append(total)
            }
            guard frames.count > 1, total > 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let animation = Animation(frames: frames, frameEnds: ends, duration: total)
            animationCache.setObject(
                Box(animation), forKey: url as NSURL, cost: animation.cost
            )
            DispatchQueue.main.async { completion(animation) }
        }
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        else { return 0.1 }
        for dictionaryKey in [kCGImagePropertyPNGDictionary, kCGImagePropertyGIFDictionary] {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let unclamped = (dictionary[kCGImagePropertyAPNGUnclampedDelayTime]
                ?? dictionary[kCGImagePropertyGIFUnclampedDelayTime]) as? Double
            let clamped = (dictionary[kCGImagePropertyAPNGDelayTime]
                ?? dictionary[kCGImagePropertyGIFDelayTime]) as? Double
            if let delay = unclamped ?? clamped {
                return max(delay, 0.02)
            }
        }
        return 0.1
    }
}

/// One display link driving every animating preview; each tick advances all
/// registered views. Registering/unregistering follows cell visibility.
final class StickerAnimator {

    static let shared = StickerAnimator()

    private var displayLink: CADisplayLink?
    private let views = NSHashTable<StickerPreviewView>.weakObjects()

    /// Playback capacity guard: beyond this many simultaneously animating
    /// previews (dense emoji grids), extra cells stay on their static frame.
    static let maxConcurrent = 28

    var canAnimateMore: Bool { views.count < Self.maxConcurrent }

    func register(_ view: StickerPreviewView) {
        views.add(view)
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func unregister(_ view: StickerPreviewView) {
        views.remove(view)
        if views.count == 0 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        for view in views.allObjects {
            view.step(now: now)
        }
    }
}

/// Renders one sticker preview: a sharp static thumbnail immediately, then
/// down-sampled animation frames while visible.
final class StickerPreviewView: UIView {

    private var url: URL?
    private var animation: StickerPreview.Animation?
    private var startTime: CFTimeInterval = 0
    private var displayedFrame = -1
    private var wantsAnimation = false
    private var loadingAnimation = false

    var contentModeFill = false {
        didSet { layer.contentsGravity = contentModeFill ? .resizeAspectFill : .resizeAspect }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.contentsGravity = .resizeAspect
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(url: URL, pixelSide: CGFloat, animated: Bool) {
        guard self.url != url else {
            wantsAnimation = animated
            if animated { resumeAnimationIfNeeded() }
            return
        }
        stopAnimating()
        self.url = url
        layer.contents = StickerPreview.cachedThumbnail(for: url)?.cgImage

        StickerPreview.thumbnail(for: url, pixelSide: pixelSide) { [weak self] image in
            guard let self, self.url == url, self.displayedFrame < 0 else { return }
            self.layer.contents = image?.cgImage
        }
        wantsAnimation = animated
        if animated { resumeAnimationIfNeeded() }
    }

    /// Called when the cell becomes visible; loads frames lazily.
    func resumeAnimationIfNeeded() {
        guard wantsAnimation, window != nil else { return }
        guard animation == nil else {
            StickerAnimator.shared.register(self)
            return
        }
        guard !loadingAnimation, StickerAnimator.shared.canAnimateMore, let url else { return }
        loadingAnimation = true
        StickerPreview.animation(for: url) { [weak self] animation in
            guard let self else { return }
            self.loadingAnimation = false
            guard self.url == url, self.wantsAnimation, let animation else { return }
            self.animation = animation
            if self.startTime == 0 { self.startTime = CACurrentMediaTime() }
            guard self.window != nil, StickerAnimator.shared.canAnimateMore else { return }
            StickerAnimator.shared.register(self)
        }
    }

    /// Off-screen: stop ticking and drop the frame buffer (the shared cache
    /// keeps it warm for a quick resume), but stay resumable.
    func pauseAnimating() {
        StickerAnimator.shared.unregister(self)
        animation = nil
    }

    /// Full reset ahead of reconfiguring with a different sticker.
    func stopAnimating() {
        StickerAnimator.shared.unregister(self)
        animation = nil
        wantsAnimation = false
        displayedFrame = -1
        startTime = 0
    }

    func step(now: CFTimeInterval) {
        guard let animation else { return }
        let index = animation.frameIndex(at: now - startTime)
        guard index != displayedFrame, index < animation.frames.count else { return }
        displayedFrame = index
        layer.contents = animation.frames[index]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            StickerAnimator.shared.unregister(self)
        } else {
            resumeAnimationIfNeeded()
        }
    }
}
