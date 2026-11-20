import CoreGraphics
import CoreText
import Foundation

nonisolated struct FeatureAnnouncement: Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case square = "1:1"
        case portrait = "4:5"

        var id: Self { self }
        var size: CGSize {
            CGSize(width: 1080, height: self == .square ? 1080 : 1350)
        }
        var fileSuffix: String { self == .square ? "1x1" : "4x5" }
    }

    var headline = ""
    var caption = ""
    var logo: CGImage?
    var callout: CGRect?

    // Source coordinates are normalized with the origin at the top left.
    static let defaultCallout = CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25)
    static let minimumDetail: CGFloat = 0.02
    static let maximumDetail: CGFloat = 0.5
    private static let calloutColor = CGColor(red: 0.60, green: 0.82, blue: 1, alpha: 1)

    static func detailSelection(from start: CGPoint, to end: CGPoint) -> CGRect? {
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard bounds.contains(start) else { return nil }
        let dx = min(max(end.x - start.x, -maximumDetail), maximumDetail)
        let dy = min(max(end.y - start.y, -maximumDetail), maximumDetail)
        let rect = CGRect(x: start.x, y: start.y, width: dx, height: dy).standardized.intersection(bounds)
        guard rect.width >= minimumDetail, rect.height >= minimumDetail else { return nil }
        return rect
    }

    var hasHeadline: Bool { !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasContent: Bool {
        hasHeadline || !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || logo != nil
    }

    struct Layout {
        let size: CGSize
        let screenshotArea: CGRect
        let logoRect: CGRect?
        let headline: CTFrame?
        let caption: CTFrame?

        func draw(in context: CGContext, logo: CGImage?, insetAboveScreenshot: CGFloat) {
            context.saveGState()
            // The screenshot is centered in its area. Move the copy down by
            // the unused space above it to keep the group together and centered.
            context.translateBy(x: 0, y: -insetAboveScreenshot)
            if let logo, let logoRect { context.draw(logo, in: logoRect) }
            context.textMatrix = .identity
            if let headline { CTFrameDraw(headline, context) }
            if let caption { CTFrameDraw(caption, context) }
            context.restoreGState()
        }
    }

    struct MediaLayout {
        let screenshotRect: CGRect
        let insetAboveScreenshot: CGFloat
        let detail: Detail?
    }

    struct Detail {
        let source: CGRect
        let image: CGImage
        let imageRect: CGRect
        let card: CGRect

        func drawOutline(in context: CGContext, screenshot: CGRect, clip: CGPath) {
            let selected = CGRect(
                x: screenshot.minX + source.minX * screenshot.width,
                y: screenshot.maxY - source.maxY * screenshot.height,
                width: source.width * screenshot.width, height: source.height * screenshot.height
            )
            let outline = CGPath(roundedRect: selected, cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.saveGState()
            context.addPath(clip)
            context.clip()
            context.addPath(outline)
            context.setStrokeColor(CGColor(gray: 0.08, alpha: 0.78))
            context.setLineWidth(8)
            context.strokePath()
            context.addPath(outline)
            context.setStrokeColor(FeatureAnnouncement.calloutColor)
            context.setLineWidth(4)
            context.strokePath()
            context.restoreGState()
        }

        func drawCard(in context: CGContext, outputScale: CGFloat) {
            let outer = CGPath(roundedRect: card, cornerWidth: 22, cornerHeight: 22, transform: nil)
            let inner = CGPath(roundedRect: imageRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
            AnnotationBackgroundRenderer.drawShadow(path: outer, knockoutPath: outer, strength: 0.86,
                                                    style: .soft, context: context, outputScale: outputScale)
            context.saveGState()
            context.addPath(outer)
            context.setFillColor(CGColor(red: 0.10, green: 0.14, blue: 0.19, alpha: 1))
            context.fillPath()
            context.addPath(outer)
            context.setStrokeColor(FeatureAnnouncement.calloutColor)
            context.setLineWidth(2)
            context.strokePath()
            context.addPath(inner)
            context.clip()
            context.interpolationQuality = .high
            context.draw(image, in: imageRect)
            context.restoreGState()
        }
    }

    func mediaLayout(for image: CGImage, in area: CGRect) -> MediaLayout {
        let full = Self.fit(image, in: area)
        guard let callout, let crop = Self.crop(image, to: callout) else {
            return MediaLayout(screenshotRect: full, insetAboveScreenshot: max(0, area.maxY - full.maxY), detail: nil)
        }

        let gap: CGFloat = 32
        let rim: CGFloat = 8
        let detailLimit = CGRect(x: 0, y: 0, width: area.width * 0.75 - rim * 2,
                                 height: area.height * 0.40 - rim * 2)
        let fittedDetail = Self.fit(crop, in: detailLimit)
        let cardHeight = fittedDetail.height + rim * 2
        let screenshotLimit = CGRect(x: 0, y: 0, width: area.width,
                                     height: area.height - cardHeight - gap)
        let fittedScreenshot = Self.fit(image, in: screenshotLimit)
        let unused = max(0, (area.height - fittedScreenshot.height - gap - cardHeight) / 2)
        let inset = CGRect(x: area.midX - fittedDetail.width / 2, y: area.minY + unused + rim,
                           width: fittedDetail.width, height: fittedDetail.height)
        let card = inset.insetBy(dx: -rim, dy: -rim)
        let screenshot = CGRect(x: area.midX - fittedScreenshot.width / 2, y: card.maxY + gap,
                                width: fittedScreenshot.width, height: fittedScreenshot.height)
        return MediaLayout(screenshotRect: screenshot, insetAboveScreenshot: unused,
                           detail: Detail(source: callout, image: crop, imageRect: inset, card: card))
    }

    private static func crop(_ image: CGImage, to detail: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(x: detail.minX * width, y: detail.minY * height,
                          width: detail.width * width, height: detail.height * height)
        return image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height)))
    }

    func layout(for format: Format) -> Layout {
        let size = format.size
        let margin: CGFloat = 72
        let width = size.width - margin * 2
        var top = size.height - margin
        let logoRect = logo.map {
            Self.fit($0, in: CGRect(x: margin, y: top - 76, width: 260, height: 76), centered: false)
        }
        if logoRect != nil { top -= 104 }
        let title = Self.textFrame(headline, size: 76, maxHeight: 190, bold: true,
                                   x: margin, top: top, width: width, opacity: 1)
        if let title { top -= title.height + 16 }
        let subtitle = Self.textFrame(caption, size: 37, maxHeight: 110, bold: false,
                                      x: margin, top: top, width: width, opacity: 0.8)
        if let subtitle { top -= subtitle.height + 16 }
        let gap: CGFloat = title == nil && subtitle == nil ? 0 : 32
        let screenshotArea = CGRect(x: margin, y: margin, width: width, height: top - gap - margin)
        return Layout(size: size, screenshotArea: screenshotArea, logoRect: logoRect,
                      headline: title?.frame, caption: subtitle?.frame)
    }

    static func fit(_ image: CGImage, in bounds: CGRect, centered: Bool = true) -> CGRect {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        return CGRect(x: centered ? bounds.midX - width / 2 : bounds.minX,
                      y: centered ? bounds.midY - height / 2 : bounds.maxY - height,
                      width: width, height: height)
    }

    private static func textFrame(
        _ value: String, size: CGFloat, maxHeight: CGFloat, bold: Bool,
        x: CGFloat, top: CGFloat, width: CGFloat, opacity: CGFloat
    ) -> (frame: CTFrame, height: CGFloat)? {
        let text = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        var fontSize = size
        while fontSize >= 14 {
            let style: CTFontUIFontType = bold ? .emphasizedSystem : .system
            let font = CTFontCreateUIFontForLanguage(style, fontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            var fit = CFRange()
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: opacity)
            ])
            let typesetter = CTFramesetterCreateWithAttributedString(attributed)
            let range = CFRange(location: 0, length: attributed.length)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(typesetter, range, nil,
                CGSize(width: width, height: maxHeight), &fit)
            if fit.length == range.length {
                let height = min(maxHeight, ceil(suggested.height) + 2)
                let rect = CGRect(x: x, y: top - height, width: width, height: height)
                let frame = CTFramesetterCreateFrame(typesetter, range, CGPath(rect: rect, transform: nil), nil)
                if CTFrameGetVisibleStringRange(frame).length == range.length { return (frame, height) }
            }
            fontSize -= 2
        }
        return nil
    }
}
