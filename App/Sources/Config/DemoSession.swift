import UIKit
import TDLibKit
import StickerCore

enum DemoSession {

    // Fictional 555-01xx number (reserved, never allocated) — documented
    // in App Review notes as the demo login.
    static let phoneDigits = "15555550100"
    static let displayPhone = "+1 555 555 0100"
    static let changed = Notification.Name("ShiiruDemoSessionChanged")

    private static let flagKey = "demoSessionActive"

    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: flagKey)
    }

    @MainActor
    static func activate() async {
        await Task.detached(priority: .userInitiated) {
            installAllPacks()
        }.value
        UserDefaults.standard.set(true, forKey: flagKey)
        StickerSyncEngine.shared.adoptStorePhases()
        NotificationCenter.default.post(name: changed, object: nil)
        Haptics.success()
    }

    @MainActor
    static func deactivate() {
        UserDefaults.standard.set(false, forKey: flagKey)
        SharedStickerStore.shared.removeAll()
        StickerSyncEngine.shared.resetAllPhases()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    @MainActor
    static func setPack(id: String, enabled: Bool) {
        if enabled, let pack = packs.first(where: { $0.id == id }) {
            install(pack)
        } else if !enabled {
            SharedStickerStore.shared.removePack(id: id)
        }
        StickerSyncEngine.shared.markDemoPhase(id: id, synced: enabled)
    }

    static var sampleSets: [StickerSetInfo] {
        packs.map { pack in
            StickerSetInfo(
                covers: [],
                id: TdInt64(Int64(pack.id)!),
                isAllowedAsChatEmojiStatus: false,
                isArchived: false,
                isInstalled: true,
                isOfficial: false,
                isOwned: false,
                isViewed: true,
                name: pack.name,
                needsRepainting: false,
                size: pack.faces.count,
                stickerType: .stickerTypeRegular,
                thumbnail: nil,
                thumbnailOutline: nil,
                title: pack.title
            )
        }
    }

    private enum Expression { case happy, joy, calm }
    private enum Motion { case none, bounce, wobble, pulse, blink }

    private struct Face {
        let color: UIColor
        let expression: Expression
        let motion: Motion
        let emoji: String
    }

    private struct Pack {
        let id: String
        let name: String
        let title: String
        let faces: [Face]
        var isAnimated: Bool { faces.contains { $0.motion != .none } }
    }

    private static let packs: [Pack] = [
        Pack(id: "9101", name: "shiiru_demo_faces", title: "Demo Faces", faces: [
            Face(color: UIColor(hex: 0xB59CF0), expression: .happy, motion: .none, emoji: "😊"),
            Face(color: UIColor(hex: 0x80AEEA), expression: .joy, motion: .none, emoji: "😄"),
            Face(color: UIColor(hex: 0xF0A2C0), expression: .calm, motion: .none, emoji: "😌"),
            Face(color: UIColor(hex: 0x8FD6A3), expression: .happy, motion: .none, emoji: "🙂"),
            Face(color: UIColor(hex: 0xF3C583), expression: .joy, motion: .none, emoji: "😀"),
            Face(color: UIColor(hex: 0x9BD8DE), expression: .calm, motion: .none, emoji: "😶"),
        ]),
        Pack(id: "9102", name: "shiiru_demo_motion", title: "Demo Motion", faces: [
            Face(color: UIColor(hex: 0x80AEEA), expression: .happy, motion: .bounce, emoji: "😊"),
            Face(color: UIColor(hex: 0xF0A2C0), expression: .joy, motion: .wobble, emoji: "😄"),
            Face(color: UIColor(hex: 0x8FD6A3), expression: .happy, motion: .pulse, emoji: "🙂"),
            Face(color: UIColor(hex: 0xB59CF0), expression: .calm, motion: .blink, emoji: "😉"),
        ]),
    ]

    static func installAllPacks() {
        for pack in packs { install(pack) }
    }

    private static func install(_ pack: Pack) {
        let store = SharedStickerStore.shared
        guard let directory = try? store.prepareDirectory(named: pack.id) else { return }
        var manifestStickers: [StickerManifest.Sticker] = []
        for (index, face) in pack.faces.enumerated() {
            guard let data = stickerData(for: face) else { continue }
            let fileName = String(format: "demo-%03d.png", index)
            do {
                try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            } catch { continue }
            manifestStickers.append(StickerManifest.Sticker(
                fileName: fileName,
                emoji: face.emoji,
                isAnimated: face.motion != .none
            ))
        }
        store.upsert(pack: StickerManifest.Pack(
            id: pack.id,
            name: pack.name,
            title: pack.title,
            isAnimated: pack.isAnimated,
            converterVersion: StickerConverter.pipelineVersion,
            stickers: manifestStickers
        ))
    }

    private static func stickerData(for face: Face) -> Data? {
        if face.motion == .none {
            guard let frame = render(face: face, progress: 0, side: 512) else { return nil }
            return APNGEncoder.encodeStatic(frame, width: 512, height: 512)
        }

        let frameCount = 24
        for side in [512, 448, 384, 320] {
            var frames: [APNGEncoder.Frame] = []
            for index in 0..<frameCount {
                guard let frame = render(
                    face: face, progress: CGFloat(index) / CGFloat(frameCount), side: side
                ) else { continue }
                frames.append(APNGEncoder.Frame(image: frame, delay: 1.0 / 24.0))
            }
            if let data = APNGEncoder.encode(
                frames: frames, width: side, height: side,
                byteBudget: StickerConverter.maxFileSize
            ), data.count <= StickerConverter.maxFileSize {
                return data
            }
        }
        return nil
    }

    private static func render(face: Face, progress: CGFloat, side: Int) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let ink = UIColor(white: 0.16, alpha: 1).cgColor

        let image = renderer.image { context in
            let ctx = context.cgContext
            let wave = sin(progress * 2 * .pi)

            let canvasScale = CGFloat(side) / 512
            ctx.scaleBy(x: canvasScale, y: canvasScale)
            ctx.translateBy(x: 256, y: 256)
            switch face.motion {
            case .bounce: ctx.translateBy(x: 0, y: -44 * abs(wave))
            case .wobble: ctx.rotate(by: 0.13 * wave)
            case .pulse:
                let scale = 1 + 0.07 * wave
                ctx.scaleBy(x: scale, y: scale)
            case .none, .blink: break
            }

            let bodyRect = CGRect(x: -196, y: -196, width: 392, height: 392)
            let body = UIBezierPath(roundedRect: bodyRect, cornerRadius: 118)
            ctx.saveGState()
            ctx.addPath(body.cgPath)
            ctx.clip()
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            face.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let lighter = UIColor(
                red: min(1, red + 0.14), green: min(1, green + 0.14),
                blue: min(1, blue + 0.14), alpha: 1
            )
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [lighter.cgColor, face.color.cgColor] as CFArray,
                locations: [0, 1]
            )!
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: bodyRect.minY),
                end: CGPoint(x: 0, y: bodyRect.maxY),
                options: []
            )
            ctx.restoreGState()
            ctx.addPath(body.cgPath)
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(18)
            ctx.strokePath()

            var eyeScale: CGFloat = 1
            if face.motion == .blink {
                let distance = abs(progress - 0.5)
                eyeScale = distance < 0.08 ? max(0.15, distance * 12) : 1
            }
            ctx.setFillColor(ink)
            for x in [-72.0, 72.0] {
                let eyeHeight = 62 * eyeScale
                ctx.fillEllipse(in: CGRect(x: x - 21, y: -46 - eyeHeight / 2, width: 42, height: eyeHeight))
            }

            switch face.expression {
            case .happy:
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(20)
                ctx.setLineCap(.round)
                ctx.addArc(
                    center: CGPoint(x: 0, y: 26),
                    radius: 72,
                    startAngle: 0.2 * .pi,
                    endAngle: 0.8 * .pi,
                    clockwise: false
                )
                ctx.strokePath()
            case .joy:
                ctx.fillEllipse(in: CGRect(x: -46, y: 48, width: 92, height: 66))
            case .calm:
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(20)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: -46, y: 78))
                ctx.addLine(to: CGPoint(x: 46, y: 78))
                ctx.strokePath()
            }
        }
        return image.cgImage
    }
}
