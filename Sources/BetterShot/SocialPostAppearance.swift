import CoreGraphics
import Foundation

nonisolated struct CompositionScreenshotStyle: Codable, Equatable, Sendable {
    var cornerRadius: CGFloat
    var shadow: CGFloat
    var shadowStyle: AnnotationShadowStyle

    var isValid: Bool { (0...0.25).contains(cornerRadius) && (0...1).contains(shadow) }
}

nonisolated struct SocialPostAppearance: Sendable {
    enum Background: Sendable {
        case solid
        case transparent
        case gradient(GradientPreset)
        case image(CGImage)
    }

    static let paddingRange: ClosedRange<CGFloat> = 24...180
    static let spacingRange: ClosedRange<CGFloat> = 0...100
    static let wallpaperMaxEdge = 2160
    var background: Background = .solid
    var padding: CGFloat = 72
    var spacing: CGFloat = 48
    var screenshot: CompositionScreenshotStyle?
    var typography: SocialPostTypography = .default

    var isDefault: Bool {
        if case .solid = background {
            return padding == 72 && spacing == 48 && screenshot == nil && typography == .default
        }
        return false
    }

    func drawBackground(palette: SocialPostPalette, in rect: CGRect, context: CGContext) {
        switch background {
        case .solid:
            context.setFillColor(palette.background.cgColor)
            context.fill(rect)
        case .transparent:
            context.clear(rect)
        case .gradient(let preset):
            preset.draw(in: context, rect: rect)
        case .image(let image):
            AnnotationBackgroundRenderer.drawWallpaper(image, in: rect, context: context)
        }
    }

    func textColours(palette: SocialPostPalette) -> (headline: SocialPostPalette.RGB, caption: SocialPostPalette.RGB,
                                                    backing: SocialPostPalette.RGB?) {
        switch background {
        case .solid:
            return (palette.background.readableForeground, palette.caption, nil)
        case .gradient(let preset):
            let stops = preset.stops.map { SocialPostPalette.RGB(red: $0.red, green: $0.green, blue: $0.blue) }
            // The shared presets add white highlights, so consider white if the
            // preset highlights the background when checking the foreground.
            let backgrounds = stops + ((preset.highlights ?? []).isEmpty ? [] : [.white])
            for foreground in [SocialPostPalette.RGB.black, .white] where
                backgrounds.allSatisfy({ foreground.contrast(against: $0) >= 4.5 }) {
                return (foreground, foreground, nil)
            }
            fallthrough
        case .image, .transparent:
            let neutral = SocialPostPalette.default
            return (neutral.background.readableForeground, neutral.caption, neutral.background)
        }
    }

    struct Stored: Codable {
        enum Background: Codable {
            case solid
            case transparent
            case gradient(GradientPreset)
            case image(Data)
        }

        let background: Background
        let padding: CGFloat
        let spacing: CGFloat
        let screenshot: CompositionScreenshotStyle?
        let typography: SocialPostTypography?

        init(_ appearance: SocialPostAppearance) throws {
            switch appearance.background {
            case .solid: background = .solid
            case .transparent: background = .transparent
            case .gradient(let preset): background = .gradient(preset)
            case .image(let image): background = .image(try FeatureAnnouncementProject.encodePNG(image))
            }
            padding = appearance.padding
            spacing = appearance.spacing
            screenshot = appearance.screenshot
            typography = appearance.typography == .default ? nil : appearance.typography
        }

        func load() throws -> SocialPostAppearance {
            guard SocialPostAppearance.paddingRange.contains(padding),
                  SocialPostAppearance.spacingRange.contains(spacing), screenshot?.isValid != false,
                  typography?.isValid != false
            else { throw FeatureAnnouncementProject.ProjectError.invalid }
            let resolved: SocialPostAppearance.Background
            switch background {
            case .solid: resolved = .solid
            case .transparent: resolved = .transparent
            case .gradient(let preset):
                guard (2...32).contains(preset.stops.count), preset.stops.allSatisfy({
                    SocialPostPalette.RGB(red: $0.red, green: $0.green, blue: $0.blue).isValid
                }), [preset.startPoint.x, preset.startPoint.y, preset.endPoint.x, preset.endPoint.y].allSatisfy({ (0...1).contains($0) }),
                preset.locations.map({ $0.count == preset.stops.count && $0.allSatisfy { (0...1).contains($0) } }) != false,
                preset.highlights?.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y)
                    && (0...1).contains($0.opacity) && (0...2).contains($0.extent) }) != false
                else { throw FeatureAnnouncementProject.ProjectError.invalid }
                resolved = .gradient(preset)
            case .image(let png):
                resolved = .image(try FeatureAnnouncementProject.decodePNG(png,
                    pixelLimit: SocialPostAppearance.wallpaperMaxEdge * SocialPostAppearance.wallpaperMaxEdge))
            }
            return SocialPostAppearance(background: resolved, padding: padding, spacing: spacing,
                                        screenshot: screenshot, typography: typography ?? .default)
        }
    }
}
