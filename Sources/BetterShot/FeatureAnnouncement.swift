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
    var appearance = SocialPostAppearance()
    var framing = Framing()

    struct Framing: Codable, Equatable, Sendable {
        var shared = Frame()
        var square: Frame?
        var portrait: Frame?

        subscript(override format: Format) -> Frame? {
            get { format == .square ? square : portrait }
            set {
                if format == .square { square = newValue } else { portrait = newValue }
            }
        }

        subscript(format: Format) -> Frame {
            get { self[override: format] ?? shared }
            set {
                if self[override: format] == nil { shared = newValue }
                else { self[override: format] = newValue }
            }
        }

        var isValid: Bool {
            shared.isValid && square?.isValid != false && portrait?.isValid != false
        }
    }

    struct Frame: Codable, Equatable, Sendable {
        enum Mode: String, Codable, CaseIterable, Sendable {
            case fit = "Fit"
            case fill = "Fill"
        }

        var mode: Mode = .fit
        var left: CGFloat = 0
        var right: CGFloat = 0
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var zoom: CGFloat = 1
        var horizontal: CGFloat = 0.5
        var vertical: CGFloat = 0.5

        static let maximumTrim: CGFloat = 0.95
        static let zoomRange: ClosedRange<CGFloat> = 1...4
        static let wholeImage = CGRect(x: 0, y: 0, width: 1, height: 1)

        var isValid: Bool {
            [left, right, top, bottom, horizontal, vertical].allSatisfy { (0...1).contains($0) }
                && left + right <= Self.maximumTrim + 0.000_001
                && top + bottom <= Self.maximumTrim + 0.000_001
                && Self.zoomRange.contains(zoom)
        }

        private var crop: CGRect {
            CGRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom)
        }

        func placement(of image: CGImage, in area: CGRect) -> (rect: CGRect, source: CGRect) {
            let crop = self.crop
            let pixels = CGSize(width: crop.width * CGFloat(image.width), height: crop.height * CGFloat(image.height))
            if mode == .fit {
                return (FeatureAnnouncement.fit(pixels, in: area), crop)
            }
            let scale = max(area.width / pixels.width, area.height / pixels.height) * zoom
            let width = min(crop.width, area.width / (scale * CGFloat(image.width)))
            let height = min(crop.height, area.height / (scale * CGFloat(image.height)))
            return (area, CGRect(x: crop.minX + (crop.width - width) * horizontal,
                                 y: crop.minY + (crop.height - height) * vertical, width: width, height: height))
        }

        func panned(by offset: CGSize, within visibleSource: CGRect) -> Frame {
            // The offset is a fraction of the preview viewport. Dragging the image
            // right or down moves the window toward the left or top of the source.
            var frame = self
            let horizontalTravel = crop.width - visibleSource.width
            let verticalTravel = crop.height - visibleSource.height
            if horizontalTravel > 0.000_001 {
                frame.horizontal = min(1, max(0, horizontal - offset.width * visibleSource.width / horizontalTravel))
            }
            if verticalTravel > 0.000_001 {
                frame.vertical = min(1, max(0, vertical - offset.height * visibleSource.height / verticalTravel))
            }
            return frame
        }
    }

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
    private var hasCopy: Bool {
        hasHeadline || !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || logo != nil
    }
    var hasContent: Bool {
        hasCopy || palette != .default || !appearance.isDefault
    }

    struct Layout {
        let size: CGSize
        let screenshotArea: CGRect
        let logoRect: CGRect?
        let headline: CTFrame?
        let caption: CTFrame?
        let media: MediaLayout?
        let copyOffset: CGFloat
        let copyBacking: CGRect?
        let backingColour: CGColor?

        func draw(in context: CGContext, logo: CGImage?) {
            context.saveGState()
            context.translateBy(x: 0, y: copyOffset)
            if let copyBacking, let backingColour {
                context.setFillColor(backingColour)
                context.addPath(CGPath(roundedRect: copyBacking, cornerWidth: 18, cornerHeight: 18, transform: nil))
                context.fillPath()
            }
            if let logo, let logoRect { context.draw(logo, in: logoRect) }
            context.textMatrix = .identity
            if let headline { CTFrameDraw(headline, context) }
            if let caption { CTFrameDraw(caption, context) }
            context.restoreGState()
        }
    }

    struct MediaLayout {
        let screenshotRect: CGRect
        let visibleSource: CGRect
        let insetAboveScreenshot: CGFloat
        let detail: Detail?

        // The source is top-left normalized. The CGContext uses bottom-left coordinates.
        func imageRect(in viewport: CGRect) -> CGRect {
            let width = viewport.width / visibleSource.width
            let height = viewport.height / visibleSource.height
            return CGRect(x: viewport.minX - visibleSource.minX * width,
                          y: viewport.maxY - (1 - visibleSource.minY) * height, width: width, height: height)
        }
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

    private func mediaLayout(for image: CGImage, in area: CGRect, frame: Frame) -> MediaLayout {
        guard let callout, let crop = Self.crop(image, to: callout) else {
            let placement = frame.placement(of: image, in: area)
            return MediaLayout(screenshotRect: placement.rect, visibleSource: placement.source,
                               insetAboveScreenshot: max(0, area.maxY - placement.rect.maxY), detail: nil)
        }

        let gap = appearance.spacing * (2.0 / 3.0)
        let rim: CGFloat = 8
        let detailLimit = CGRect(x: 0, y: 0, width: area.width * 0.75 - rim * 2,
                                 height: area.height * 0.40 - rim * 2)
        let fittedDetail = Self.fit(crop, in: detailLimit)
        let cardHeight = fittedDetail.height + rim * 2
        let screenshotLimit = CGRect(x: 0, y: 0, width: area.width,
                                     height: area.height - cardHeight - gap)
        let placement = frame.placement(of: image, in: screenshotLimit)
        let fittedScreenshot = placement.rect
        let unused = max(0, (area.height - fittedScreenshot.height - gap - cardHeight) / 2)
        let inset = CGRect(x: area.midX - fittedDetail.width / 2, y: area.minY + unused + rim,
                           width: fittedDetail.width, height: fittedDetail.height)
        let card = inset.insetBy(dx: -rim, dy: -rim)
        let screenshot = CGRect(x: area.midX - fittedScreenshot.width / 2, y: card.maxY + gap,
                                width: fittedScreenshot.width, height: fittedScreenshot.height)
        return MediaLayout(screenshotRect: screenshot, visibleSource: placement.source, insetAboveScreenshot: unused,
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
        let margin = appearance.padding
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let columns = arrangement == .sideBySide && hasCopy && screenshot != nil
        let width: CGFloat = columns ? (format == .square ? 390 : 416) : bounds.width
        var top = bounds.maxY
        let logoRect = logo.map {
            Self.fit($0, in: CGRect(x: margin, y: top - 76, width: 260, height: 76), centered: false)
        }
        if let logoRect { top = logoRect.minY - 28 }
        let colours = appearance.textColours(palette: palette)
        let headlineStyle = appearance.typography.headline
        let captionStyle = appearance.typography.caption
        let title = Self.textFrame(headline, size: headlineStyle.maxSize ?? SocialPostTypography.Role.headline.defaultSize(inColumns: columns),
                                   maxHeight: columns ? 300 : 190, style: headlineStyle, balance: true,
                                   x: margin, top: top, width: width, color: (headlineStyle.colour ?? colours.headline).cgColor)
        if let title { top -= title.height + 16 }
        let subtitle = Self.textFrame(caption, size: captionStyle.maxSize ?? SocialPostTypography.Role.caption.defaultSize(inColumns: columns),
                                      maxHeight: columns ? 166 : 110, style: captionStyle, balance: false,
                                      x: margin, top: top, width: width, color: (captionStyle.colour ?? colours.caption).cgColor)
        let copyBottom = if let subtitle { top - subtitle.height }
            else if title != nil { top + 16 }
            else { logoRect?.minY ?? top }
        let copyHeight = bounds.maxY - copyBottom
        let copyBacking = colours.backing != nil && (title != nil || subtitle != nil)
            ? CGRect(x: margin, y: copyBottom, width: width, height: copyHeight).insetBy(dx: -14, dy: -12)
            : nil
        let gap: CGFloat = copyHeight > 0 ? max(appearance.spacing, copyBacking == nil ? 0 : 18) : 0
        let screenshotFirst = arrangement == .screenshotFirst && screenshot != nil
        let screenshotArea: CGRect
        if columns {
            let left = bounds.minX + width + gap
            screenshotArea = CGRect(x: left, y: bounds.minY, width: bounds.maxX - left, height: bounds.height)
        } else {
            screenshotArea = CGRect(x: bounds.minX, y: bounds.minY + (screenshotFirst ? copyHeight + gap : 0),
                                    width: bounds.width, height: bounds.height - copyHeight - gap)
        }
        let media = screenshot.map { mediaLayout(for: $0, in: screenshotArea, frame: framing[format]) }
        let copyOffset: CGFloat
        if columns {
            copyOffset = (copyHeight - bounds.height) / 2
        } else if screenshotFirst, let media {
            copyOffset = bounds.minY + copyHeight + media.insetAboveScreenshot - bounds.maxY
        } else {
            copyOffset = -(media?.insetAboveScreenshot ?? 0)
        }
        return Layout(size: size, screenshotArea: screenshotArea, logoRect: logoRect,
                      headline: title?.frame, caption: subtitle?.frame, media: media, copyOffset: copyOffset,
                      copyBacking: copyBacking, backingColour: colours.backing?.cgColor)
    }

    static func fit(_ image: CGImage, in bounds: CGRect, centered: Bool = true) -> CGRect {
        fit(CGSize(width: image.width, height: image.height), in: bounds, centered: centered)
    }

    private static func fit(_ size: CGSize, in bounds: CGRect, centered: Bool = true) -> CGRect {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: centered ? bounds.midX - width / 2 : bounds.minX,
                      y: centered ? bounds.midY - height / 2 : bounds.maxY - height,
                      width: width, height: height)
    }

    private static func textFrame(
        _ value: String, size: CGFloat, maxHeight: CGFloat, style: SocialPostTypography.TextStyle, balance: Bool,
        x: CGFloat, top: CGFloat, width: CGFloat, color: CGColor
    ) -> (frame: CTFrame, height: CGFloat)? {
        let unwrapped = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !unwrapped.isEmpty else { return nil }
        let text = value.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.joined(separator: "\n")
        let paragraph = style.alignment.paragraph
        var fontSize = size
        while fontSize >= 14 {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): style.font(size: fontSize),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
            if let paragraph { attributes[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = paragraph }
            if style.tracking != 0 {
                attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = style.tracking * fontSize / size
            }
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
                if balance, !text.contains("\n"), CFArrayGetCount(CTFrameGetLines(frame.frame)) == 2,
                   let balanced = balancedHeadline(text, width: width, attributes: attributes),
                   let balancedFrame = fittedFrame(balanced) {
                    return balancedFrame
                }
                return frame
            }
            fontSize -= 2
        }
        // A pasted paragraph can contain more breaks than fit at any readable size.
        if text != unwrapped {
            return textFrame(unwrapped, size: size, maxHeight: maxHeight, style: style, balance: balance,
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
