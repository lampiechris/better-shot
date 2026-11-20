import CoreGraphics
import CoreText
import Foundation

nonisolated struct FeatureAnnouncement: Sendable {
    static let title = "Social Post"
    static let headlineLimit = 90
    static let captionLimit = 160
    static let logoMaxEdge = 1024
    static let logoPixelLimit = logoMaxEdge * logoMaxEdge

    enum Arrangement: String, Codable, CaseIterable, Identifiable, Sendable {
        case headlineAbove
        case screenshotFirst
        case sideBySide

        var id: Self { self }

        var title: String {
            switch self {
            case .headlineAbove: "Headline Above"
            case .screenshotFirst: "Screenshot First"
            case .sideBySide: "Side by Side"
            }
        }
    }

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
    var arrangement: Arrangement = .headlineAbove
    var palette: SocialPostPalette = .default

    // Source coordinates are normalized with the origin at the top left.
    static let defaultCallout = CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25)
    static let minimumDetail: CGFloat = 0.02
    static let maximumDetail: CGFloat = 0.5

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
        hasHeadline || !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || logo != nil || palette != .default
    }

    struct Layout {
        let size: CGSize
        let screenshotArea: CGRect
        let logoRect: CGRect?
        let headline: CTFrame?
        let caption: CTFrame?
        let media: MediaLayout?
        let copyOffset: CGFloat

        func draw(in context: CGContext, logo: CGImage?) {
            context.saveGState()
            context.translateBy(x: 0, y: copyOffset)
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
        let accent: SocialPostPalette.RGB

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
            context.setStrokeColor(accent.readableForeground.cgColor)
            context.setLineWidth(8)
            context.strokePath()
            context.addPath(outline)
            context.setStrokeColor(accent.cgColor)
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
            context.setStrokeColor(accent.readableForeground.cgColor)
            context.setLineWidth(4)
            context.strokePath()
            context.addPath(outer)
            context.setStrokeColor(accent.cgColor)
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
                           detail: Detail(source: callout, image: crop, imageRect: inset, card: card, accent: palette.accent))
    }

    private static func crop(_ image: CGImage, to detail: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(x: detail.minX * width, y: detail.minY * height,
                          width: detail.width * width, height: detail.height * height)
        return image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height)))
    }

    func layout(for format: Format, screenshot: CGImage? = nil) -> Layout {
        let size = format.size
        let margin: CGFloat = 72
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let columns = arrangement == .sideBySide && hasContent && screenshot != nil
        let width: CGFloat = columns ? (format == .square ? 390 : 416) : bounds.width
        var top = bounds.maxY
        let logoRect = logo.map {
            Self.fit($0, in: CGRect(x: margin, y: top - 76, width: 260, height: 76), centered: false)
        }
        if let logoRect { top = logoRect.minY - 28 }
        let title = Self.textFrame(headline, size: columns ? 62 : 76, maxHeight: columns ? 300 : 190, bold: true,
                                   x: margin, top: top, width: width, color: palette.background.readableForeground.cgColor)
        if let title { top -= title.height + 16 }
        let subtitle = Self.textFrame(caption, size: columns ? 32 : 37, maxHeight: columns ? 166 : 110, bold: false,
                                      x: margin, top: top, width: width, color: palette.caption.cgColor)
        let copyBottom = if let subtitle { top - subtitle.height }
            else if title != nil { top + 16 }
            else { logoRect?.minY ?? top }
        let copyHeight = bounds.maxY - copyBottom
        let gap: CGFloat = copyHeight > 0 ? 48 : 0
        let screenshotFirst = arrangement == .screenshotFirst && screenshot != nil
        let screenshotArea: CGRect
        if columns {
            let left = bounds.minX + width + gap
            screenshotArea = CGRect(x: left, y: bounds.minY, width: bounds.maxX - left, height: bounds.height)
        } else {
            screenshotArea = CGRect(x: bounds.minX, y: bounds.minY + (screenshotFirst ? copyHeight + gap : 0),
                                    width: bounds.width, height: bounds.height - copyHeight - gap)
        }
        let media = screenshot.map { mediaLayout(for: $0, in: screenshotArea) }
        let copyOffset: CGFloat
        if columns {
            copyOffset = (copyHeight - bounds.height) / 2
        } else if screenshotFirst, let media {
            copyOffset = bounds.minY + copyHeight + media.insetAboveScreenshot - bounds.maxY
        } else {
            copyOffset = -(media?.insetAboveScreenshot ?? 0)
        }
        return Layout(size: size, screenshotArea: screenshotArea, logoRect: logoRect,
                      headline: title?.frame, caption: subtitle?.frame, media: media, copyOffset: copyOffset)
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
        x: CGFloat, top: CGFloat, width: CGFloat, color: CGColor
    ) -> (frame: CTFrame, height: CGFloat)? {
        let unwrapped = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !unwrapped.isEmpty else { return nil }
        let text = bold ? value.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.joined(separator: "\n") : unwrapped
        var fontSize = size
        while fontSize >= 14 {
            let style: CTFontUIFontType = bold ? .emphasizedSystem : .system
            let font = CTFontCreateUIFontForLanguage(style, fontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
            func fittedFrame(_ copy: String) -> (frame: CTFrame, height: CGFloat)? {
                let attributed = NSAttributedString(string: copy, attributes: attributes)
                let typesetter = CTFramesetterCreateWithAttributedString(attributed)
                let range = CFRange(location: 0, length: attributed.length)
                var fit = CFRange()
                let suggested = CTFramesetterSuggestFrameSizeWithConstraints(typesetter, range, nil,
                    CGSize(width: width, height: maxHeight), &fit)
                guard fit.length == range.length else { return nil }
                let height = min(maxHeight, ceil(suggested.height) + 2)
                let rect = CGRect(x: x, y: top - height, width: width, height: height)
                let frame = CTFramesetterCreateFrame(typesetter, range, CGPath(rect: rect, transform: nil), nil)
                return CTFrameGetVisibleStringRange(frame).length == range.length ? (frame, height) : nil
            }
            if let frame = fittedFrame(text) {
                if bold, !text.contains("\n"), CFArrayGetCount(CTFrameGetLines(frame.frame)) == 2,
                   let balanced = balancedHeadline(text, width: width, attributes: attributes),
                   let balancedFrame = fittedFrame(balanced) {
                    return balancedFrame
                }
                return frame
            }
            fontSize -= 2
        }
        // A pasted headline can contain more line breaks than fit at any readable size.
        if text != unwrapped {
            return textFrame(unwrapped, size: size, maxHeight: maxHeight, bold: bold,
                             x: x, top: top, width: width, color: color)
        }
        return nil
    }

    private static func balancedHeadline(_ text: String, width: CGFloat,
                                         attributes: [NSAttributedString.Key: Any]) -> String? {
        let words = text.split(separator: " ")
        guard words.count > 1 else { return nil }
        func lineWidth(_ content: String) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: attributes))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        var best: String?
        var smallestDifference = CGFloat.infinity
        for split in 1..<words.count {
            let first = words[..<split].joined(separator: " ")
            let second = words[split...].joined(separator: " ")
            let firstWidth = lineWidth(first)
            let secondWidth = lineWidth(second)
            let difference = abs(firstWidth - secondWidth)
            if max(firstWidth, secondWidth) <= width, difference < smallestDifference {
                best = first + "\n" + second
                smallestDifference = difference
            }
        }
        return best
    }
}
