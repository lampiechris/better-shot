import AppKit
import CoreText

nonisolated struct SocialPostTypography: Codable, Equatable, Sendable {
    enum Role: String, CaseIterable, Identifiable, Sendable {
        case headline = "Headline"
        case caption = "Caption"

        var id: Self { self }
        var sizeRange: ClosedRange<CGFloat> { self == .headline ? 28...140 : 20...76 }
        func defaultSize(inColumns: Bool) -> CGFloat {
            switch self {
            case .headline: inColumns ? 62 : 76
            case .caption: inColumns ? 32 : 37
            }
        }
    }

    enum Typeface: String, CaseIterable, Identifiable, Codable, Sendable {
        case sans = "Sans Serif"
        case serif = "Serif"
        case rounded = "Rounded"
        case monospaced = "Monospaced"

        var id: Self { self }
        var design: NSFontDescriptor.SystemDesign {
            switch self {
            case .sans: .default
            case .serif: .serif
            case .rounded: .rounded
            case .monospaced: .monospaced
            }
        }
    }

    enum Weight: String, CaseIterable, Identifiable, Codable, Sendable {
        case regular = "Regular"
        case semibold = "Semibold"
        case bold = "Bold"

        var id: Self { self }
        var fontWeight: NSFont.Weight {
            switch self {
            case .regular: .regular
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    enum Alignment: String, CaseIterable, Identifiable, Codable, Sendable {
        case automatic = "Automatic"
        case left = "Left"
        case center = "Center"
        case right = "Right"

        var id: Self { self }

        var paragraph: CTParagraphStyle? {
            guard self != .automatic else { return nil }
            let alignment: CTTextAlignment = switch self {
            case .automatic: .natural
            case .left: .left
            case .center: .center
            case .right: .right
            }
            return withUnsafePointer(to: alignment) { pointer in
                let setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                      value: UnsafeRawPointer(pointer))
                return CTParagraphStyleCreate([setting], 1)
            }
        }
    }

    struct TextStyle: Codable, Equatable, Sendable {
        var typeface: Typeface = .sans
        var weight: Weight = .regular
        var alignment: Alignment = .automatic
        var maxSize: CGFloat?
        var tracking: CGFloat = 0
        var colour: SocialPostPalette.RGB?

        func font(size: CGFloat) -> CTFont {
            // Use the original system faces for existing posts. The native
            // design descriptors preserve weights and work with Core Text.
            if typeface == .sans, weight != .semibold,
               let font = CTFontCreateUIFontForLanguage(weight == .bold ? .emphasizedSystem : .system, size, nil) {
                return font
            }
            let base = NSFont.systemFont(ofSize: size, weight: weight.fontWeight)
            let designed = base.fontDescriptor.withDesign(typeface.design).flatMap { NSFont(descriptor: $0, size: size) }
            return (designed ?? base) as CTFont
        }

        func isValid(for role: Role) -> Bool {
            maxSize.map(role.sizeRange.contains) != false && SocialPostTypography.trackingRange.contains(tracking)
                && colour?.isValid != false
        }
    }

    static let trackingRange: ClosedRange<CGFloat> = -2...6
    static let `default` = SocialPostTypography()
    var headline = TextStyle(weight: .bold)
    var caption = TextStyle()

    subscript(_ role: Role) -> TextStyle {
        get { role == .headline ? headline : caption }
        set {
            switch role {
            case .headline: headline = newValue
            case .caption: caption = newValue
            }
        }
    }

    var isValid: Bool { headline.isValid(for: .headline) && caption.isValid(for: .caption) }
}
