import AppKit
import SwiftUI

/// iTunes Search API, used to fill in duration/album for Shazam matches and
/// to find high-resolution artwork when the player can't provide it.
enum ITunesMetadata {
    struct Item: Decodable {
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackTimeMillis: Double?
        let artworkUrl100: String?
    }

    private struct Response: Decodable { let results: [Item] }

    static func lookup(appleMusicID: String) async -> Item? {
        await fetch("https://itunes.apple.com/lookup?id=\(appleMusicID)&entity=song")
    }

    static func search(title: String, artist: String) async -> Item? {
        let term = "\(artist) \(title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return await fetch("https://itunes.apple.com/search?term=\(term)&entity=song&limit=1")
    }

    private static func fetch(_ string: String) async -> Item? {
        guard let url = URL(string: string),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.results.first { $0.trackName != nil }
    }

    /// Rewrites CDN artwork URLs to a large size: Apple's …/100x100bb.jpg and
    /// Google's (YouTube Music) …=w120-h120-l90-rj.
    static func highResolution(_ url: URL?) -> URL? {
        guard let url, let host = url.host else { return url }
        var string = url.absoluteString
        if host.contains("mzstatic.com") {
            string = string.replacingOccurrences(
                of: "\\d+x\\d+(bb|cc|sr)?", with: "1200x1200bb", options: .regularExpression)
        } else if host.contains("googleusercontent.com") || host.contains("ggpht.com") {
            string = string.replacingOccurrences(
                of: "=w\\d+-h\\d+", with: "=w1200-h1200", options: .regularExpression)
        }
        return URL(string: string) ?? url
    }
}

enum ImageLoader {
    static func load(_ url: URL?) async -> NSImage? {
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}

enum ArtworkPalette {
    static let fallback: [Color] = [
        Color(red: 0.98, green: 0.24, blue: 0.36), Color(red: 0.62, green: 0.16, blue: 0.48), Color(red: 0.29, green: 0.10, blue: 0.42),
        Color(red: 0.84, green: 0.20, blue: 0.40), Color(red: 0.46, green: 0.13, blue: 0.46), Color(red: 0.20, green: 0.10, blue: 0.36),
        Color(red: 0.60, green: 0.14, blue: 0.42), Color(red: 0.30, green: 0.10, blue: 0.40), Color(red: 0.12, green: 0.06, blue: 0.24),
    ]

    /// Downsamples the artwork to a 3×3 grid, giving nine colours that map
    /// directly onto a 3×3 mesh gradient.
    static func colors(from image: NSImage) -> [Color] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        let size = 3
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return fallback }
        return stride(from: 0, to: pixels.count, by: 4).map {
            Color(red: Double(pixels[$0]) / 255, green: Double(pixels[$0 + 1]) / 255, blue: Double(pixels[$0 + 2]) / 255)
        }
    }

    /// A single representative colour, used to tint the floating glass.
    static func accent(from colors: [Color]) -> Color {
        colors.count > 4 ? colors[4] : .pink
    }
}
