import AppKit
import CoreText
import ImageIO
import SwiftUI
@testable import BetterShot

@MainActor
func checkScreenshotComposition() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func source(_ color: NSColor, name: String, width: Int, height: Int) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = directory.appendingPathComponent(name + ".png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return url
    }
    let red = try source(.red, name: "Window A", width: 800, height: 400)
    let blue = try source(.blue, name: "Window B", width: 400, height: 600)
    try checkFeatureAnnouncement(screenshot: red, replacement: blue, directory: directory)
    var defaults = AnnotationBackgroundSettings()
    defaults.style = .solid(.graphite)
    let model = ScreenshotCompositionModel(defaultLook: defaults)
    model.importImages([red, blue])
    precondition(model.document.screenshots.count == 2 && model.selection?.name == "Window B.png")
    precondition(model.document.screenshots[0].image.width == 800, "Original image resolution must survive import")
    let importedRevision = model.document.revision
    model.beginEditing()
    model.updateSelected { $0.shadow = 0.2 }
    model.updateSelected { $0.shadow = 0.7 }
    model.endEditing()
    model.undo()
    precondition(model.document.revision == importedRevision, "One drag must undo as one edit")
    model.redo()
    precondition(model.selection?.shadow == 0.7)
    for layout in ScreenshotCompositionLayout.allCases {
        model.change { $0.arrange(layout) }
        for item in model.document.screenshots {
            precondition(model.document.contentRect.contains(item.frame))
            let ratio = CGFloat(item.image.width) / CGFloat(item.image.height)
            precondition(abs(item.frame.width / item.frame.height - ratio) < 0.02)
        }
        precondition(!model.document.screenshots[0].frame.intersects(model.document.screenshots[1].frame),
                     "Automatic layouts must keep images separate")
    }
    model.resizeCanvas(CGSize(width: 400, height: 400))
    precondition(model.document.screenshots.allSatisfy { model.document.contentRect.contains($0.frame) })
    let selected = model.selectedID
    model.moveSelection(by: -1)
    precondition(model.document.screenshots.first?.id == selected)
    model.undo()
    precondition(model.document.screenshots.last?.id == selected)
    model.removeSelection(); precondition(model.document.screenshots.count == 1)
    model.undo(); precondition(model.document.screenshots.count == 2)
    model.importImages([directory.appendingPathComponent("missing.png")])
    precondition(model.errorMessage != nil && model.document.screenshots.count == 2)

    // Sample overlapping solid images to verify actual painter order, alpha,
    // rounded clipping and the top-left canvas to Core Graphics conversion.
    var document = model.document
    document.size = CGSize(width: 400, height: 400)
    document.background = .none
    document.screenshots[0].frame = CGRect(x: 40, y: 40, width: 200, height: 100)
    document.screenshots[1].frame = CGRect(x: 80, y: 80, width: 100, height: 150)
    for index in document.screenshots.indices { document.screenshots[index].shadow = 0; document.screenshots[index].cornerRadius = 0.2 }
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }
    let image = try ScreenshotCompositionRenderer.render(document, scale: 1)
    precondition(pixel(image, 100, 100).blueComponent > 0.9, "Front screenshot must cover the rear screenshot")
    precondition(pixel(image, 60, 65).redComponent > 0.9, "Canvas must retain top-left coordinates")
    precondition(pixel(image, 40, 40).alphaComponent < 0.1, "Rounded corners must stay transparent")
    precondition(pixel(image, 399, 399).alphaComponent == 0)
    document.screenshots.swapAt(0, 1)
    let reordered = try ScreenshotCompositionRenderer.render(document, scale: 1)
    precondition(pixel(reordered, 100, 100).redComponent > 0.9)
    document.screenshots[0].shadow = 0.5
    let shadowed = try ScreenshotCompositionRenderer.render(document, scale: 1)
    precondition(pixel(shadowed, 185, 160).alphaComponent > 0, "Shadows must survive transparent export")
    precondition(pixel(shadowed, 110, 190).blueComponent > 0.9, "Shadow caster must not blacken image interiors")
    // A Retina capture fitted at half size loses one-pixel text strokes at 1x.
    // Auto must retain the source pixel count and reproduce those strokes exactly,
    // including fractional placement and a non-integer canvas export scale.
    let stripes = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    stripes.setFillColor(NSColor.white.cgColor)
    stripes.fill(CGRect(x: 0, y: 0, width: 400, height: 240))
    stripes.setFillColor(NSColor.black.cgColor)
    for x in stride(from: 0, to: 400, by: 2) { stripes.fill(CGRect(x: x, y: 0, width: 1, height: 240)) }
    let original = stripes.makeImage()!
    var detail = ScreenshotComposition()
    detail.size = CGSize(width: 400, height: 400)
    detail.screenshots = [CompositionScreenshot(id: UUID(), image: original, name: "Retina text strokes",
        frame: CGRect(x: 40.25, y: 40.25, width: 200, height: 120), cornerRadius: 0, shadow: 0)]
    precondition(detail.sourceResolutionScale == 2)
    let reduced = try ScreenshotCompositionRenderer.render(detail, scale: 1)
    let reducedPixels = NSBitmapImageRep(cgImage: reduced)
    let reducedColor = reducedPixels.colorAt(x: 100, y: 100)!.usingColorSpace(.sRGB)!
    precondition(reducedColor.redComponent > 0.1 && reducedColor.redComponent < 0.9,
                 "The fixture must reproduce fine-line contrast loss at 1x")
    for frame in [CGRect(x: 40.25, y: 40.25, width: 200, height: 120),
                  CGRect(x: 40, y: 40, width: 160, height: 96)] {
        detail.screenshots[0].frame = frame
        let scale = detail.sourceResolutionScale
        let detailURL = directory.appendingPathComponent("native-detail.png")
        try ScreenshotCompositionRenderer.export(detail, scale: scale, to: detailURL)
        let exported = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(detailURL as CFURL, nil)!, 0, nil)!
        let pixels = NSBitmapImageRep(cgImage: exported)
        let sourcePixels = NSBitmapImageRep(cgImage: original)
        for y in stride(from: 4, to: 236, by: 7) {
            for x in 4..<396 {
                let actual = pixels.colorAt(x: Int((frame.minX * scale).rounded()) + x,
                                             y: Int((frame.minY * scale).rounded()) + y)!.usingColorSpace(.sRGB)!
                let expected = sourcePixels.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                precondition(abs(actual.redComponent - expected.redComponent) < 1.0 / 255,
                             "Native-resolution export must not soften one-pixel strokes")
            }
        }
    }
    // The smallest placement determines the shared scale for mixed image sizes.
    detail.screenshots.append(CompositionScreenshot(id: UUID(), image: original, name: "Smaller screenshot",
        frame: CGRect(x: 10, y: 10, width: 100, height: 60), cornerRadius: 0, shadow: 0))
    precondition(detail.sourceResolutionScale == 4)
    precondition(ScreenshotComposition().sourceResolutionScale == 1)
    print("PASS 1x fine-line softness reproduced; Auto PNG preserves native detail at 2x and 2.5x with pixel-aligned placement")

    let output = directory.appendingPathComponent("combined.png")
    try ScreenshotCompositionRenderer.export(document, scale: 2, to: output)
    let saved = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil)!
    precondition(saved.width == 800 && saved.height == 800)
    precondition(pixel(saved, 799, 799).alphaComponent == 0)
    do {
        _ = try ScreenshotCompositionRenderer.outputSize(document, scale: 100)
        preconditionFailure("Oversized exports must fail before allocating a bitmap")
    } catch { precondition(error.localizedDescription.contains("64 megapixels")) }
    model.markExported(model.document.revision)
    precondition(!model.hasUnexportedChanges)
    model.updateSelected { $0.shadow = 0.1 }
    precondition(model.hasUnexportedChanges)
    model.undo(); precondition(!model.hasUnexportedChanges)

    // Exercise the worst-density layout at both supported canvas extremes.
    model.importImages(Array(repeating: red, count: 24))
    precondition(model.document.screenshots.count == 24 && model.errorMessage != nil)
    for size in [CGSize(width: 400, height: 400), CGSize(width: 6000, height: 6000)] {
        model.resizeCanvas(size)
        model.change { $0.spacing = 300 }
        for layout in ScreenshotCompositionLayout.allCases {
            model.change { $0.arrange(layout) }
            precondition(model.document.screenshots.allSatisfy {
                $0.frame.width > 0 && $0.frame.height > 0 && model.document.contentRect.contains($0.frame)
            })
        }
    }
    // Compact and normal editor snapshots use disposable images and preferences.
    let preview = ScreenshotCompositionModel(defaultLook: defaults)
    preview.importImages([red, blue]); preview.change { $0.arrange(.row) }
    let originalSize = preview.document.size
    let portraitSizes: [(CanvasAspectRatio, CGSize)] = [
        (.nineSixteen, CGSize(width: 1080, height: 1920)),
        (.fourFive, CGSize(width: 1080, height: 1350)),
        (.threeFour, CGSize(width: 1080, height: 1440))
    ]
    for (aspect, size) in portraitSizes {
        preview.setCanvasAspect(aspect)
        precondition(preview.document.size == size)
        precondition(preview.document.screenshots.allSatisfy { preview.document.contentRect.contains($0.frame) })
        let outputSize = try ScreenshotCompositionRenderer.outputSize(preview.document, scale: 1)
        precondition(outputSize == size)
        preview.undo()
        precondition(preview.document.size == originalSize)
    }
    preview.setCanvasAspect(.fourFive)
    let snapshots = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/editor-snapshots")
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
        for width: CGFloat in [980, 1280] {
            try snapshot(ScreenshotCompositionWindow(model: preview), scheme: scheme, width: width,
                to: snapshots.appendingPathComponent("composition-\(scheme)-\(Int(width)).png"), height: 780)
        }
    }
    print("PASS composition import, source resolution, undo, layouts, bounds, layer order, rounded alpha, shadows, 2x PNG, limits and compact light/dark snapshots")
}

@MainActor
private func checkFeatureAnnouncement(screenshot: URL, replacement: URL, directory: URL) throws {
    let model = ScreenshotCompositionModel(defaultLook: AnnotationBackgroundSettings(), isAnnouncement: true)
    let exports = directory.appendingPathComponent("posts", isDirectory: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
    model.importImages([screenshot])
    precondition(!model.canExportAnnouncement)
    do {
        _ = try ScreenshotCompositionRenderer.exportAnnouncement(model.document, to: exports)
        preconditionFailure("A post needs a headline")
    } catch {
        let remaining = try FileManager.default.contentsOfDirectory(atPath: exports.path)
        precondition(remaining.isEmpty)
    }
    model.change {
        $0.announcement?.headline = "Edit once. Share in two sizes."
        $0.announcement?.caption = "BetterShot now exports both square and portrait posts."
    }
    model.importAnnouncementLogo(replacement)
    precondition(model.canExportAnnouncement && model.hasUnexportedChanges)
    model.importImages([replacement])
    precondition(model.document.screenshots.count == 1 && model.selection?.name == replacement.lastPathComponent)
    precondition(model.document.announcement?.hasHeadline == true && model.document.announcement?.logo != nil)
    model.undo()
    precondition(model.selection?.name == screenshot.lastPathComponent)
    model.redo()
    precondition(model.selection?.name == replacement.lastPathComponent)
    model.importImages([screenshot, replacement])
    precondition(model.document.screenshots.count == 1 && model.errorMessage != nil)
    model.errorMessage = nil

    let first = try ScreenshotCompositionRenderer.exportAnnouncement(model.document, to: exports)
    let second = try ScreenshotCompositionRenderer.exportAnnouncement(model.document, to: exports)
    precondition(first != second, "Repeated exports must keep both folders")
    let names = try FileManager.default.contentsOfDirectory(atPath: first.path)
    precondition(names.count == 2)
    for format in FeatureAnnouncement.Format.allCases {
        let size = format.size
        let url = first.appendingPathComponent(names.first { $0.hasSuffix("\(format.fileSuffix).png") }!)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width == Int(size.width) && image.height == Int(size.height))
        let scaled = try ScreenshotCompositionRenderer.render(model.document, scale: 0.5, format: format)
        precondition(scaled.width * 2 == image.width && scaled.height * 2 == image.height)
        let layout = model.document.announcement!.layout(for: format, screenshot: model.selection?.image)
        precondition(layout.headline != nil && layout.caption != nil && layout.logoRect != nil)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let center = bitmap.colorAt(x: Int(layout.screenshotArea.midX), y: Int(size.height - layout.screenshotArea.midY))!
        precondition(center.usingColorSpace(.sRGB)!.blueComponent > 0.9, "The full replacement screenshot must render")
        let logo = bitmap.colorAt(x: Int(layout.logoRect!.midX),
                                  y: Int(size.height - layout.logoRect!.midY - layout.copyOffset))!
        precondition(logo.usingColorSpace(.sRGB)!.blueComponent > 0.9, "The optional logo must render")
    }

    var longPost = FeatureAnnouncement()
    longPost.headline = String(repeating: "機能発表　", count: 18)
    longPost.caption = String(repeating: "W", count: 160)
    let compact = longPost.layout(for: .square)
    precondition(compact.headline != nil && compact.caption != nil && compact.screenshotArea.height > 400)

    let pattern = CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    pattern.setFillColor(CGColor(red: 0.15, green: 0.25, blue: 0.65, alpha: 1))
    pattern.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
    pattern.setFillColor(CGColor(red: 0.93, green: 0.3, blue: 0.13, alpha: 1))
    pattern.fill(CGRect(x: 0, y: 200, width: 320, height: 200))
    let fixture = directory.appendingPathComponent("detail.png")
    let destination = CGImageDestinationCreateWithURL(fixture as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, pattern.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    model.importImages([fixture])
    let selection = FeatureAnnouncement.detailSelection(from: CGPoint(x: 0.3, y: 0.35), to: CGPoint(x: 0.05, y: 0.05))!
    precondition(abs(selection.minX - 0.05) < 0.000_001 && abs(selection.minY - 0.05) < 0.000_001)
    precondition(FeatureAnnouncement.detailSelection(from: .zero, to: CGPoint(x: 3, y: 3)) == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
    model.change { $0.announcement?.callout = selection }
    model.importImages([replacement])
    precondition(model.document.announcement?.callout == nil, "A replacement must not highlight the old screenshot's detail")
    model.undo()
    precondition(model.document.announcement?.callout == selection)
    let calloutFolder = try ScreenshotCompositionRenderer.exportAnnouncement(model.document, to: exports)
    for format in FeatureAnnouncement.Format.allCases {
        let announcement = model.document.announcement!
        let media = announcement.layout(for: format, screenshot: model.selection?.image).media!
        let detail = media.detail!
        precondition(detail.card.maxY < media.screenshotRect.minY)
        precondition(detail.imageRect.width > selection.width * media.screenshotRect.width)
        let url = calloutFolder.appendingPathComponent("Feature Announcement \(format.fileSuffix).png")
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor {
            bitmap.colorAt(x: Int(x), y: Int(format.size.height - y))!.usingColorSpace(.sRGB)!
        }
        let inset = color(detail.imageRect.midX, detail.imageRect.midY)
        precondition(inset.redComponent > 0.85 && inset.blueComponent < 0.25,
                     "The inset must show the selected top-left pixels")
        let full = color(media.screenshotRect.midX, media.screenshotRect.midY)
        precondition(full.blueComponent > 0.55, "The full screenshot remains visible")
        let shadow = color(detail.card.midX, detail.card.minY - 5)
        let background = color(20, detail.card.minY - 5)
        precondition(shadow.redComponent < background.redComponent - 0.015, "The inset has a visible drop shadow")
        let preview = NSBitmapImageRep(cgImage: try ScreenshotCompositionRenderer.render(model.document, scale: 0.5, format: format))
        let probe = CGPoint(x: detail.card.midX, y: format.size.height - detail.card.minY + 26)
        let exportShadow = bitmap.colorAt(x: Int(probe.x), y: Int(probe.y))!.usingColorSpace(.sRGB)!
        let previewShadow = preview.colorAt(x: Int(probe.x / 2), y: Int(probe.y / 2))!.usingColorSpace(.sRGB)!
        precondition(abs(exportShadow.redComponent - previewShadow.redComponent) < 0.015,
                     "Preview and export must cast the same relative shadow")
    }

    try checkAnnouncementLayouts(model, tallImage: replacement)
    let postURL = directory.appendingPathComponent("Launch.bettershotpost")
    try FeatureAnnouncementProject.write(model.document, to: postURL)
    let defaultPost = try FeatureAnnouncementProject.read(from: postURL)
    precondition(defaultPost.announcement.arrangement == .headlineAbove, "Posts without a layout field use Headline Above")
    model.change { $0.announcement?.arrangement = .screenshotFirst }
    model.calloutDraft = selection.offsetBy(dx: 0.02, dy: 0.01)
    model.applyCalloutDraft()
    let savedRevision = model.document.revision
    let savedCallout = model.document.announcement?.callout
    try FeatureAnnouncementProject.write(model.document, to: postURL)
    model.markPostSaved(to: postURL, revision: savedRevision)
    precondition(!model.hasUnsavedPostChanges)
    let reopened = ScreenshotCompositionModel(defaultLook: AnnotationBackgroundSettings(), isAnnouncement: true)
    reopened.loadPost(try FeatureAnnouncementProject.read(from: postURL).makeDocument(), from: postURL)
    precondition(!reopened.hasUnsavedPostChanges && !reopened.canUndo)
    precondition(reopened.document.announcement?.headline == model.document.announcement?.headline)
    precondition(reopened.document.announcement?.caption == model.document.announcement?.caption)
    precondition(reopened.document.announcement?.callout == savedCallout)
    precondition(reopened.document.announcement?.arrangement == .screenshotFirst)
    precondition(reopened.selection?.name == fixture.lastPathComponent)
    try FileManager.default.removeItem(at: fixture)
    let reopenedImage = try ScreenshotCompositionRenderer.render(reopened.document, scale: 1, format: .portrait)
    let originalImage = try ScreenshotCompositionRenderer.render(model.document, scale: 1, format: .portrait)
    precondition(reopenedImage.dataProvider!.data! as Data == originalImage.dataProvider!.data! as Data,
                 "Reopened posts must render the same pixels with no access to the source file")
    let copy = ScreenshotCompositionModel(defaultLook: AnnotationBackgroundSettings(), isAnnouncement: true)
    copy.loadPost(reopened.document, from: nil)
    precondition(copy.postURL == nil && copy.hasUnsavedPostChanges)
    copy.importImages([replacement])
    precondition(copy.document.announcement?.callout == nil && reopened.document.announcement?.callout == savedCallout)
    copy.change { $0.announcement?.headline = "New announcement" }
    precondition(reopened.document.announcement?.headline != copy.document.announcement?.headline)
    reopened.removeSelection()
    precondition(reopened.hasUnsavedPostChanges, "Removing the saved image must be kept as an edit")
    reopened.undo()
    precondition(!reopened.hasUnsavedPostChanges)
    let previousSave = try Data(contentsOf: postURL)
    do {
        try FeatureAnnouncementProject.write(ScreenshotComposition(), to: postURL)
        preconditionFailure("Freeform compositions cannot be saved over a post")
    } catch {
        let currentSave = try Data(contentsOf: postURL)
        precondition(previousSave == currentSave)
    }
    let corruptURL = directory.appendingPathComponent("Invalid.bettershotpost")
    try Data("not a project".utf8).write(to: corruptURL)
    do {
        _ = try FeatureAnnouncementProject.read(from: corruptURL)
        preconditionFailure("Invalid projects must be rejected")
    } catch FeatureAnnouncementProject.ProjectError.invalid {}
    let snapshots = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/editor-snapshots")
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
        try snapshot(ScreenshotCompositionWindow(model: model), scheme: scheme, width: 980,
                     to: snapshots.appendingPathComponent("announcement-\(scheme)-980.png"), height: 680)
    }
    print("PASS Feature Announcement callouts, paired exports, lossless editable project round trip, and independent copies")
}

@MainActor
private func checkAnnouncementLayouts(_ model: ScreenshotCompositionModel, tallImage: URL) throws {
    func lines(in frame: CTFrame) -> [CTLine] {
        CTFrameGetLines(frame) as! [CTLine]
    }
    var balancing = FeatureAnnouncement(headline: "BetterShot makes sharing simpler")
    let balanced = lines(in: balancing.layout(for: .square).headline!)
    precondition(balanced.count == 2)
    let widths = balanced.map { CTLineGetTypographicBounds($0, nil, nil, nil) }
    precondition(widths.min()! / widths.max()! > 0.60, "A headline should avoid a short last line when it can balance")
    balancing.headline = "Short\nA deliberately longer second line"
    let manual = lines(in: balancing.layout(for: .square).headline!)
    precondition(manual.count == 2 && CTLineGetStringRange(manual[1]).location == 6,
                 "Typed line breaks take precedence over balancing")

    model.importImages([tallImage])
    model.change {
        $0.announcement?.headline = "A clearer way\nto share"
        $0.announcement?.callout = FeatureAnnouncement.defaultCallout
    }
    var snapshots = model.document
    for arrangement in FeatureAnnouncement.Arrangement.allCases {
        snapshots.announcement?.arrangement = arrangement
        for format in FeatureAnnouncement.Format.allCases {
            let layout = snapshots.announcement!.layout(for: format, screenshot: snapshots.screenshots.first!.image)
            let media = layout.media!
            let headline = CTFrameGetPath(layout.headline!).boundingBox.offsetBy(dx: 0, dy: layout.copyOffset)
            let caption = CTFrameGetPath(layout.caption!).boundingBox.offsetBy(dx: 0, dy: layout.copyOffset)
            let logo = layout.logoRect!.offsetBy(dx: 0, dy: layout.copyOffset)
            let copy = headline.union(caption).union(logo)
            let mediaBounds = media.screenshotRect.union(media.detail!.card)
            let canvas = CGRect(origin: .zero, size: format.size)
            precondition(canvas.contains(copy) && canvas.contains(mediaBounds) && !copy.intersects(mediaBounds))
            switch arrangement {
            case .headlineAbove: precondition(copy.minY > mediaBounds.maxY)
            case .screenshotFirst: precondition(mediaBounds.minY > copy.maxY)
            case .sideBySide: precondition(copy.maxX < mediaBounds.minX)
            }
            let phone = try ScreenshotCompositionRenderer.render(snapshots, scale: 390 / format.size.width, format: format)
            precondition(phone.width == 390)
        }
    }
    model.undo()
    model.undo()
}
