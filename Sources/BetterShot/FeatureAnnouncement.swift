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
