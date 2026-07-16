#!/usr/bin/env swift

import AppKit

let root = FileManager.default.currentDirectoryPath
let iconPackage = "\(root)/App/Resources/AppIcon.icon"
let appIconDir = "\(root)/App/Resources/Assets.xcassets/AppIcon.appiconset"
let glassDir = "\(root)/App/Resources/Assets.xcassets/AppIconGlass.imageset"
let msgIconDir = "\(root)/MessagesExtension/Resources/Assets.xcassets/iMessage App Icon.stickersiconset"

if CommandLine.arguments.count > 1 {
    let source = (CommandLine.arguments[1] as NSString).expandingTildeInPath
    try? FileManager.default.removeItem(atPath: iconPackage)
    try! FileManager.default.copyItem(atPath: source, toPath: iconPackage)
    print("imported \(source)")
}

let tmp = NSTemporaryDirectory() + "shiiru-icon-flatten"
try? FileManager.default.removeItem(atPath: tmp)
try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW)

func flatten(package: String, workDir: String) -> [CGImage] {
    try! FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    let actool = Process()
    actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    actool.arguments = [
        "actool", package,
        "--compile", workDir,
        "--app-icon", (package as NSString).lastPathComponent.replacingOccurrences(of: ".icon", with: ""),
        "--platform", "iphoneos",
        "--minimum-deployment-target", "16.0",
        "--target-device", "iphone",
        "--output-partial-info-plist", workDir + "/partial.plist",
    ]
    actool.standardOutput = Pipe()
    try! actool.run()
    actool.waitUntilExit()
    guard actool.terminationStatus == 0 else { fatalError("actool failed for \(package)") }

    guard let catalogClass = NSClassFromString("CUICatalog") else { fatalError("CUICatalog unavailable") }
    typealias AllocIMP = @convention(c) (AnyClass, Selector) -> NSObject
    let allocSel = NSSelectorFromString("alloc")
    let allocIMP = unsafeBitCast(
        method_getImplementation(class_getClassMethod(catalogClass, allocSel)!), to: AllocIMP.self
    )
    let rawCatalog = allocIMP(catalogClass, allocSel)
    let initSel = NSSelectorFromString("initWithURL:error:")
    typealias InitIMP = @convention(c) (NSObject, Selector, NSURL, UnsafeMutableRawPointer?) -> NSObject?
    let initIMP = unsafeBitCast(rawCatalog.method(for: initSel), to: InitIMP.self)
    guard let catalog = initIMP(rawCatalog, initSel, NSURL(fileURLWithPath: workDir + "/Assets.car"), nil) else {
        fatalError("cannot open compiled Assets.car")
    }

    typealias ImageIMP = @convention(c) (NSObject, Selector) -> Unmanaged<CGImage>?
    var variants: [CGImage] = []
    if let names = catalog.perform(NSSelectorFromString("allImageNames"))?
        .takeUnretainedValue() as? [String],
       let iconName = names.first(where: { !$0.contains("/") && !$0.contains("_Assets") }),
       let images = catalog.perform(NSSelectorFromString("imagesWithName:"), with: iconName)?
        .takeUnretainedValue() as? [NSObject] {
        for named in images {
            let imageSel = NSSelectorFromString("image")
            guard named.responds(to: imageSel) else { continue }
            let imageIMP = unsafeBitCast(named.method(for: imageSel), to: ImageIMP.self)
            guard let cg = imageIMP(named, imageSel)?.takeUnretainedValue(), cg.width >= 512 else { continue }
            variants.append(cg)
        }
    }
    guard !variants.isEmpty else { fatalError("no flattened icon variants found for \(package)") }
    return variants
}

func scaledPackage(factor: Double) -> String {
    let path = tmp + "/Scaled.icon"
    try? FileManager.default.removeItem(atPath: path)
    try! FileManager.default.copyItem(atPath: iconPackage, toPath: path)
    var json = try! JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: path + "/icon.json"))
    ) as! [String: Any]
    var groups = json["groups"] as! [[String: Any]]
    for groupIndex in groups.indices {
        var layers = groups[groupIndex]["layers"] as! [[String: Any]]
        for layerIndex in layers.indices {
            var position = layers[layerIndex]["position"] as? [String: Any] ?? [:]
            position["scale"] = (position["scale"] as? Double ?? 1) * factor
            if let translation = position["translation-in-points"] as? [Double] {
                position["translation-in-points"] = translation.map { $0 * factor }
            }
            layers[layerIndex]["position"] = position
        }
        groups[groupIndex]["layers"] = layers
    }
    json["groups"] = groups
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path + "/icon.json"))
    return path
}

let variants = flatten(package: iconPackage, workDir: tmp + "/app")

func stats(_ image: CGImage) -> (opaqueCorner: Bool, colorSpread: Int, brightness: Int) {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let corner = (5 * width + 5) * 4
    var spread = 0, brightness = 0
    for point in [(width / 2, height / 8), (width / 8, height / 2), (width / 2, height - height / 8)] {
        let offset = (point.1 * width + point.0) * 4
        let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
        spread += max(r, g, b) - min(r, g, b)
        brightness += r + g + b
    }
    return (pixels[corner + 3] == 255, spread, brightness)
}
func pickLight(_ variants: [CGImage]) -> CGImage {
    variants
        .map { (image: $0, stats: stats($0)) }
        .filter { $0.stats.opaqueCorner && $0.stats.colorSpread > 20 }
        .max { $0.stats.brightness < $1.stats.brightness }?
        .image ?? variants[0]
}

let light = pickLight(variants)

let messagesLight = pickLight(flatten(
    package: scaledPackage(factor: 0.72),
    workDir: tmp + "/messages"
))

func write(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func render(_ source: CGImage, width: Int, height: Int) -> CGImage {
    let sourceWidth = CGFloat(source.width), sourceHeight = CGFloat(source.height)
    let targetAspect = CGFloat(width) / CGFloat(height)
    var cropSize = CGSize(width: sourceWidth, height: sourceWidth / targetAspect)
    if cropSize.height > sourceHeight {
        cropSize = CGSize(width: sourceHeight * targetAspect, height: sourceHeight)
    }
    let cropped = source.cropping(to: CGRect(
        x: (sourceWidth - cropSize.width) / 2,
        y: (sourceHeight - cropSize.height) / 2,
        width: cropSize.width,
        height: cropSize.height
    ))!
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

write(render(light, width: 1024, height: 1024), to: "\(appIconDir)/icon-1024.png")

try? FileManager.default.createDirectory(atPath: glassDir, withIntermediateDirectories: true)
write(render(light, width: 512, height: 512), to: "\(glassDir)/AppIconGlass.png")

let messagesSizes: [(String, Int, Int)] = [
    ("icon-58.png", 58, 58),
    ("icon-87.png", 87, 87),
    ("icon-120x90.png", 120, 90),
    ("icon-180x135.png", 180, 135),
    ("icon-134x100.png", 134, 100),
    ("icon-148x110.png", 148, 110),
    ("icon-54x40.png", 54, 40),
    ("icon-81x60.png", 81, 60),
    ("icon-64x48.png", 64, 48),
    ("icon-96x72.png", 96, 72),
    ("icon-1024x768.png", 1024, 768),
]
for (name, w, h) in messagesSizes {
    write(render(messagesLight, width: w, height: h), to: "\(msgIconDir)/\(name)")
}
