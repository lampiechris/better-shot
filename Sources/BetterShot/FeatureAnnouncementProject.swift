import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum FeatureAnnouncementProject {
    static let pathExtension = "bettershotpost"
    static let contentType = UTType(exportedAs: "com.bettershot.post", conformingTo: .data)
    private static let maximumBytes = 576 * 1024 * 1024

    enum ProjectError: LocalizedError {
        case invalid, version, size

        var errorDescription: String? {
            switch self {
            case .invalid: "This file is not a readable BetterShot post."
            case .version: "This post was saved with a newer version of BetterShot."
            case .size: "This post exceeds the project file size limit."
            }
        }
    }

    private struct FileContents: Codable {
        var version = 1
        var headline: String
        var caption: String
        var logoPNG: Data?
        var callout: CGRect?
        var screenshot: Screenshot?
        var arrangement: FeatureAnnouncement.Arrangement?
        var palette: SocialPostPalette?
        var appearance: SocialPostAppearance.Stored?
    }

    private struct Screenshot: Codable {
        var name: String
        var png: Data
        var cornerRadius: CGFloat
        var shadow: CGFloat
        var shadowStyle: String
    }

    struct LoadedPost {
        let announcement: FeatureAnnouncement
        let screenshot: CompositionScreenshot?

        @MainActor func makeDocument() -> ScreenshotComposition {
            var document = ScreenshotComposition()
            document.announcement = announcement
            if let screenshot { document.screenshots = [screenshot] }
            return document
        }
    }

    static func write(_ document: ScreenshotComposition, to url: URL) throws {
        guard let post = document.announcement else { throw ProjectError.invalid }
        let screenshot = try document.screenshots.first.map {
            let style = post.appearance.screenshot ?? $0.style
            return Screenshot(name: $0.name, png: try encodePNG($0.image), cornerRadius: style.cornerRadius,
                              shadow: style.shadow, shadowStyle: style.shadowStyle.rawValue)
        }
        let contents = FileContents(headline: post.headline, caption: post.caption,
            logoPNG: try post.logo.map(encodePNG), callout: post.callout, screenshot: screenshot,
            arrangement: post.arrangement == .headlineAbove ? nil : post.arrangement,
            palette: post.palette == .default ? nil : post.palette,
            appearance: post.appearance.isDefault ? nil : try SocialPostAppearance.Stored(post.appearance))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(contents)
        guard data.count <= maximumBytes else { throw ProjectError.size }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> LoadedPost {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true else { throw ProjectError.invalid }
        guard let size = info.fileSize, size <= maximumBytes else { throw ProjectError.size }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw ProjectError.size }
        let contents: FileContents
        do {
            contents = try PropertyListDecoder().decode(FileContents.self, from: data)
        } catch {
            throw ProjectError.invalid
        }
        guard contents.version == 1 else { throw ProjectError.version }
        guard contents.headline.count <= FeatureAnnouncement.headlineLimit,
              contents.caption.count <= FeatureAnnouncement.captionLimit,
              contents.palette?.isValid != false else { throw ProjectError.invalid }
        let announcement = FeatureAnnouncement(headline: contents.headline, caption: contents.caption,
            logo: try contents.logoPNG.map { try decodePNG($0, pixelLimit: FeatureAnnouncement.logoPixelLimit) },
            callout: contents.callout, arrangement: contents.arrangement ?? .headlineAbove,
            palette: contents.palette ?? .default, appearance: try contents.appearance?.load() ?? SocialPostAppearance())
        if let rect = contents.callout {
            // Tolerate normal floating-point roundoff at the selection edges.
            let epsilon: CGFloat = 0.000_001
            let limits = (FeatureAnnouncement.minimumDetail - epsilon)...(FeatureAnnouncement.maximumDetail + epsilon)
            guard contents.screenshot != nil, limits.contains(rect.size.width), limits.contains(rect.size.height),
                  CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -epsilon, dy: -epsilon).contains(rect)
            else { throw ProjectError.invalid }
        }
        let screenshot = try contents.screenshot.map { screenshot in
            guard (0...0.25).contains(screenshot.cornerRadius), (0...1).contains(screenshot.shadow),
                  let style = AnnotationShadowStyle(rawValue: screenshot.shadowStyle)
            else { throw ProjectError.invalid }
            let image = try decodePNG(screenshot.png, pixelLimit: 64_000_000)
            return CompositionScreenshot(id: UUID(), image: image, name: screenshot.name, frame: .zero,
                                         cornerRadius: screenshot.cornerRadius, shadow: screenshot.shadow, shadowStyle: style)
        }
        return LoadedPost(announcement: announcement, screenshot: screenshot)
    }

    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    static func decodePNG(_ data: Data, pixelLimit: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= Double(pixelLimit),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ProjectError.invalid }
        return image
    }
}
