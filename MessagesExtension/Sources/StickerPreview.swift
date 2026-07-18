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

    /// Ceiling, in pixels, for animation frame decode. Playback runs below
    /// cell resolution (the static thumbnail stays sharp at rest); small
    /// cells pass their own side so a 44 pt emoji doesn't pay for 160 px
    /// frames it can't show.
    static let animationPixelSide: CGFloat = 160

    /// Playback frame budget: Telegram video stickers decode to ~90 frames,
    /// indistinguishable from 24 at panel cell sizes — and the frame buffer
    /// is what the animation budget is spent on.
    static let animationFrameCap = 24

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
    // both caches together stay below it and NSCache additionally responds
    // to memory pressure. The thumbnail limit is sized for scroll-back: a
    // sticker-mode thumbnail is ~300 KB, and a fast flick through a large
    // pack must still find the previous screens cached on the way back —
    // a miss shows as a blank cell until the async decode lands.
    private static let thumbnailCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    private static let animationCache: NSCache<NSString, Box<Animation>> = {
        let cache = NSCache<NSString, Box<Animation>>()
        cache.totalCostLimit = 32 << 20
        return cache
    }()

    /// Cache key carries the decode size: the same sticker can be shown at
    /// emoji and sticker resolutions in different modes.
    private static func animationKey(_ url: URL, side: CGFloat) -> NSString {
        "\(url.path)#\(Int(side))" as NSString
    }

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

    /// Decodes an animated sticker for playback, down-sampled to `pixelSide`
    /// and resampled to at most `animationFrameCap` frames (skipped frames
    /// donate their display time to the survivor, so total duration and
    /// pacing are preserved). Returns nil for static images.
    static func animation(
        for url: URL,
        pixelSide: CGFloat = animationPixelSide,
        completion: @escaping (Animation?) -> Void
    ) {
        let side = min(max(pixelSide, 32), animationPixelSide)
        let key = animationKey(url, side: side)
        if let cached = animationCache.object(forKey: key) {
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
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            var originalEnds: [Double] = []
            originalEnds.reserveCapacity(count)
            var total: Double = 0
            for index in 0..<count {
                total += frameDelay(source: source, index: index)
                originalEnds.append(total)
            }
            let step = max(1, (count + animationFrameCap - 1) / animationFrameCap)
            var frames: [CGImage] = []
            var ends: [Double] = []
            for start in stride(from: 0, to: count, by: step) {
                guard let cg = CGImageSourceCreateThumbnailAtIndex(
                    source, start, options as CFDictionary
                ) else { continue }
                frames.append(cg)
                ends.append(originalEnds[min(start + step, count) - 1])
            }
            guard frames.count > 1, total > 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let animation = Animation(frames: frames, frameEnds: ends, duration: total)
            animationCache.setObject(
                Box(animation), forKey: key, cost: animation.cost
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
    /// Visible previews that asked for a slot while all were taken. When a
    /// slot frees they are revived in turn — without this, a cell denied
    /// once would stay on its static frame until the next scroll recycled
    /// it, even with the animator sitting mostly idle.
    private let waiting = NSHashTable<StickerPreviewView>.weakObjects()

    /// Admission is budgeted by frame-buffer bytes, not by count: a 44 pt
    /// emoji preview costs ~750 KB while a GIF-mosaic cell costs megabytes,
    /// and a flat count sized for the expensive case left most of a dense
    /// emoji grid frozen on its static frame. Within the budget the whole
    /// grid animates; the count ceiling is only a CPU backstop.
    static let budgetBytes = 40 << 20
    static let maxConcurrent = 96

    private var spentBytes: Int {
        views.allObjects.reduce(0) { $0 + $1.animationCost }
    }

    /// Claims an animation slot for `cost` bytes (estimated before decode,
    /// exact after), or queues the view for revival when room frees up.
    func requestSlot(_ view: StickerPreviewView, cost: Int) -> Bool {
        if views.contains(view) { return true }
        if views.count < Self.maxConcurrent, spentBytes + cost <= Self.budgetBytes {
            waiting.remove(view)
            return true
        }
        waiting.add(view)
        return false
    }

    func register(_ view: StickerPreviewView) {
        waiting.remove(view)
        views.add(view)
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func unregister(_ view: StickerPreviewView) {
        let held = views.contains(view)
        views.remove(view)
        waiting.remove(view)
        if views.count == 0 {
            displayLink?.invalidate()
            displayLink = nil
        }
        // Budget freed → give every waiter one shot at it; a cheap emoji
        // slot opening admits several cheaper waiters at once, and any
        // still-denied view just re-queues itself.
        guard held else { return }
        for next in waiting.allObjects {
            waiting.remove(next)
            next.resumeAnimationIfNeeded()
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
    /// Decode side for playback frames; the cell passes its own size so
    /// tiny emoji cells don't pay full-resolution costs.
    private var animationPixelSide = StickerPreview.animationPixelSide

    /// Live frame-buffer bytes this view holds — what it's charged against
    /// the animator's budget while registered.
    var animationCost: Int { animation?.cost ?? 0 }

    /// Pre-decode admission estimate (side² × RGBA × frame cap).
    private var estimatedAnimationCost: Int {
        let side = Int(min(animationPixelSide, StickerPreview.animationPixelSide))
        return side * side * 4 * StickerPreview.animationFrameCap
    }
    /// True between resume and pause: the cell is on screen and should
    /// tick. Async decode completions must not register a preview whose
    /// cell went back to the reuse pool — pooled cells keep their window,
    /// so a window check alone lets off-screen phantoms hoard animator
    /// slots and freshly shown stickers then sit on their static frame.
    private var wantsTicks = false

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

    func configure(
        url: URL,
        pixelSide: CGFloat,
        animated: Bool,
        animationPixelSide: CGFloat = StickerPreview.animationPixelSide
    ) {
        self.animationPixelSide = animationPixelSide
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
        wantsTicks = true
        if let animation {
            guard StickerAnimator.shared.requestSlot(self, cost: animation.cost) else { return }
            StickerAnimator.shared.register(self)
            return
        }
        guard !loadingAnimation, let url,
              StickerAnimator.shared.requestSlot(self, cost: estimatedAnimationCost) else { return }
        loadingAnimation = true
        StickerPreview.animation(for: url, pixelSide: animationPixelSide) { [weak self] animation in
            guard let self else { return }
            self.loadingAnimation = false
            guard self.url == url, self.wantsTicks, self.window != nil, let animation else { return }
            // Admission re-checked with the exact cost; a denied view keeps
            // its frames in the shared cache only, so waiters never hold
            // untracked memory while parked.
            guard StickerAnimator.shared.requestSlot(self, cost: animation.cost) else { return }
            self.animation = animation
            if self.startTime == 0 { self.startTime = CACurrentMediaTime() }
            StickerAnimator.shared.register(self)
        }
    }

    /// Off-screen: stop ticking and drop the frame buffer (the shared cache
    /// keeps it warm for a quick resume), but stay resumable.
    func pauseAnimating() {
        wantsTicks = false
        StickerAnimator.shared.unregister(self)
        animation = nil
    }

    /// Full reset ahead of reconfiguring with a different sticker.
    func stopAnimating() {
        wantsTicks = false
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
            wantsTicks = false
            StickerAnimator.shared.unregister(self)
        } else {
            resumeAnimationIfNeeded()
        }
    }
}
