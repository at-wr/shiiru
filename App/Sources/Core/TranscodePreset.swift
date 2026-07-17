import Foundation

/// User-selectable trade-off for animated sticker conversion.
///
/// iMessage caps every sticker file at 500 KB, and Messages renders
/// animated stickers proportionally to their pixel size — a busy video
/// sticker cannot keep full display size, fluid motion, and rich color all
/// at once inside the budget. The preset decides what gives way first.
enum TranscodePreset: String, CaseIterable {

    /// Middle ground (default): canvas floor 320 px, frame rate may drop
    /// to 12–8 fps on the densest stickers.
    case balanced

    /// Motion first: holds 16+ fps, letting heavy stickers shrink instead
    /// (they display smaller in the transcript, like pre-1.0 builds).
    case smoothMotion = "smooth"

    /// Size first: canvas floor 384 px; the busiest stickers may play
    /// noticeably choppier.
    case bigAndSharp = "sharp"

    /// User-tuned floors (canvas / frame rate / palette).
    case custom

    static var current: TranscodePreset {
        get {
            UserDefaults.standard.string(forKey: "transcodePreset")
                .flatMap(TranscodePreset.init(rawValue:)) ?? .balanced
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "transcodePreset")
        }
    }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .smoothMotion: return "Smooth Motion"
        case .bigAndSharp: return "Big & Sharp"
        case .custom: return "Custom"
        }
    }

    /// Settings row icon mirrors the chosen intensity.
    var symbolName: String {
        switch self {
        case .smoothMotion: return "dial.low.fill"
        case .balanced: return "dial.medium.fill"
        case .bigAndSharp: return "dial.high.fill"
        case .custom: return "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .balanced:
            return "Trades size and smoothness evenly."
        case .smoothMotion:
            return "Keeps animation fluid. Stickers may display smaller."
        case .bigAndSharp:
            return "Largest display size. Stickers may play choppier."
        case .custom:
            return "Custom canvas, frame-rate, and color floors."
        }
    }

    // MARK: - Custom knobs

    static let canvasFloorChoices = [192, 224, 256, 288, 320, 352, 384, 416]
    static let fpsFloorChoices: [Double] = [8, 10, 12, 16, 20]
    static let colorFloorChoices = [32, 48, 64, 96, 128]

    static var customCanvasFloor: Int {
        get { defaulted("customCanvasFloor", fallback: 320, allowed: canvasFloorChoices) }
        set { UserDefaults.standard.set(newValue, forKey: "customCanvasFloor") }
    }

    static var customFPSFloor: Double {
        get { defaulted("customFPSFloor", fallback: 12, allowed: fpsFloorChoices) }
        set { UserDefaults.standard.set(newValue, forKey: "customFPSFloor") }
    }

    static var customColorFloor: Int {
        get { defaulted("customColorFloor", fallback: 48, allowed: colorFloorChoices) }
        set { UserDefaults.standard.set(newValue, forKey: "customColorFloor") }
    }

    private static func defaulted<Value: Equatable>(
        _ key: String, fallback: Value, allowed: [Value]
    ) -> Value {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Value,
              allowed.contains(stored)
        else { return fallback }
        return stored
    }

    // MARK: - Encoder parameters

    var profile: TranscodeProfile {
        switch self {
        case .balanced:
            // The tail keeps eroding the canvas so no sticker falls back
            // to a static frame while any animation still fits.
            return TranscodeProfile(
                minSide: 320,
                lastStands: [
                    (320, 12, 128), (320, 12, 96), (320, 12, 64),
                    (320, 10, 48), (288, 10, 48), (288, 8, 48),
                    (256, 8, 48), (224, 8, 48),
                ]
            )
        case .smoothMotion:
            return TranscodeProfile(
                minSide: 192,
                fpsFloor: 16,
                lastStands: [
                    (256, 16, 96), (224, 16, 64), (192, 16, 64),
                    (192, 12, 64), (160, 12, 64), (160, 10, 48),
                ]
            )
        case .bigAndSharp:
            // Even here, any animation beats a static fallback: the final
            // rungs erode the canvas after size-first attempts run dry.
            return TranscodeProfile(
                minSide: 384,
                lastStands: [
                    (448, 10, 64), (448, 8, 48), (416, 8, 48), (384, 8, 48),
                    (352, 8, 48), (320, 8, 48), (288, 8, 48), (256, 8, 48), (224, 8, 48),
                ]
            )
        case .custom:
            return TranscodeProfile.custom(
                canvasFloor: Self.customCanvasFloor,
                fpsFloor: Self.customFPSFloor,
                colorFloor: Self.customColorFloor
            )
        }
    }
}

/// Concrete encoder parameters, decoupled from the user-facing preset so
/// special content classes can override them.
struct TranscodeProfile {
    /// Smallest canvas the planner may shrink to before sacrificing fps.
    let minSide: Int
    /// Hard canvas ceiling (below the global 512 when upscaling is futile).
    var sideCap: Int = 512
    /// Lowest frame rate the planner may resample down to. The emergency
    /// ladder is allowed to dip below it as a final anti-static resort.
    var fpsFloor: Double = 12
    /// Emergency ladder for video stickers that outgrow the planner:
    /// ordered attempts of (canvas, fps, palette size).
    let lastStands: [(side: Int, fps: Double, colors: Int)]

    /// Custom emoji always favor motion, regardless of the user preset:
    /// choppy emoji read as broken, and their 100 px source art gains
    /// nothing from canvases beyond ~288 px — the saved bytes go to frame
    /// rate instead.
    static let emoji = TranscodeProfile(
        minSide: 192,
        sideCap: 288,
        fpsFloor: 16,
        lastStands: [
            (256, 16, 96), (224, 16, 64), (224, 12, 64), (192, 12, 64),
        ]
    )

    /// Builds a profile from the three user-tunable floors; the emergency
    /// ladder degrades palette first, then dips fps and erodes the canvas
    /// so nothing falls back to a static frame while animation still fits.
    static func custom(canvasFloor: Int, fpsFloor: Double, colorFloor: Int) -> TranscodeProfile {
        var rungs: [(side: Int, fps: Double, colors: Int)] = []
        for colors in [128, 96, 64, 48, 32] where colors >= colorFloor {
            rungs.append((canvasFloor, fpsFloor, colors))
        }
        let emergencyFPS = max(8, fpsFloor - 4)
        var side = canvasFloor - 32
        while side >= 192 {
            rungs.append((side, emergencyFPS, colorFloor))
            side -= 32
        }
        if rungs.isEmpty { rungs = [(canvasFloor, fpsFloor, colorFloor)] }
        return TranscodeProfile(
            minSide: canvasFloor,
            fpsFloor: fpsFloor,
            lastStands: rungs
        )
    }
}
