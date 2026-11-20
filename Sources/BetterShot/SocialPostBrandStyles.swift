import CoreGraphics
import Foundation
import Observation

nonisolated struct SocialPostPalette: Codable, Equatable, Sendable {
    struct RGB: Codable, Equatable, Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)

        var isValid: Bool { [red, green, blue].allSatisfy { (0...1).contains($0) } }

        var cgColor: CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }

        private var luminance: CGFloat {
            func linear(_ component: CGFloat) -> CGFloat {
                component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(against other: RGB) -> CGFloat {
            let first = luminance
            let second = other.luminance
            return (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }

        var readableForeground: RGB {
            contrast(against: .black) >= contrast(against: .white) ? .black : .white
        }

        func blended(with foreground: RGB, amount: CGFloat) -> RGB {
            RGB(red: red + (foreground.red - red) * amount,
                green: green + (foreground.green - green) * amount,
                blue: blue + (foreground.blue - blue) * amount)
        }
    }

    var background = RGB(red: 0.17, green: 0.18, blue: 0.21)
    var accent = RGB(red: 0.60, green: 0.82, blue: 1)
    static let `default` = SocialPostPalette()

    var isValid: Bool { background.isValid && accent.isValid }

    var caption: RGB {
        let foreground = background.readableForeground
        // Keep the caption visually quieter where the background allows it.
        // Use an opaque blend so both preview and export get the same contrast.
        for step in 16...20 {
            let candidate = background.blended(with: foreground, amount: CGFloat(step) / 20)
            if candidate.contrast(against: background) >= 4.5 { return candidate }
        }
        return foreground
    }
}

@MainActor @Observable
final class SocialPostBrandStyleStore {
    static let shared = SocialPostBrandStyleStore(url: ScreenshotHistoryStore.applicationSupportDirectory
        .appendingPathComponent("SocialPostBrandStyles.plist"))

    struct Style: Codable, Identifiable {
        let id: UUID
        let name: String
        let palette: SocialPostPalette
        let logoPNG: Data?
        let appearance: SocialPostAppearance.Stored?

        func loadLogo() throws -> CGImage? {
            try logoPNG.map { try FeatureAnnouncementProject.decodePNG($0, pixelLimit: FeatureAnnouncement.logoPixelLimit) }
        }
    }

    private struct Library: Codable {
        var version = 1
        let styles: [Style]
    }

    enum StyleError: LocalizedError {
        case invalidName, duplicateName, unreadable

        var errorDescription: String? {
            switch self {
            case .invalidName: "Enter a name for the brand style."
            case .duplicateName: "A brand style with that name already exists."
            case .unreadable: "The saved brand styles couldn’t be read."
            }
        }
    }

    private let url: URL
    private(set) var styles: [Style] = []
    private var canWrite = true

    init(url: URL) {
        self.url = url
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let library = try PropertyListDecoder().decode(Library.self, from: data)
            guard library.version == 1, library.styles.allSatisfy({ $0.palette.isValid }) else {
                throw StyleError.unreadable
            }
            styles = library.styles
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First use. The folder is created when the user saves a style.
        } catch {
            canWrite = false
        }
    }

    func save(name: String, palette: SocialPostPalette, logo: CGImage?, appearance: SocialPostAppearance? = nil) throws {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        guard !name.isEmpty else { throw StyleError.invalidName }
        guard !styles.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw StyleError.duplicateName
        }
        let style = Style(id: UUID(), name: name, palette: palette,
                          logoPNG: try logo.map(FeatureAnnouncementProject.encodePNG),
                          appearance: try appearance.map(SocialPostAppearance.Stored.init))
        try persist(styles + [style])
    }

    func delete(_ id: Style.ID) throws {
        try persist(styles.filter { $0.id != id })
    }

    private func persist(_ updatedStyles: [Style]) throws {
        guard canWrite else { throw StyleError.unreadable }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Library(styles: updatedStyles))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        styles = updatedStyles
    }
}
