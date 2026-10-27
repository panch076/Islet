import Foundation

/// Fetches time-synced lyrics from LRCLIB (https://lrclib.net).
actor LyricsService {
    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?

        var hasSynced: Bool { !(syncedLyrics ?? "").isEmpty }
        var hasPlain: Bool { !(plainLyrics ?? "").isEmpty }
    }

    private var cache: [String: LyricsState] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Lyrical/1.0 (macOS lyrics overlay)"]
        config.timeoutIntervalForRequest = 12
        session = URLSession(configuration: config)
    }

    func lyrics(for track: Track) async -> LyricsState {
        let key = "\(track.artist)|\(track.title)".lowercased()
        if let cached = cache[key] { return cached }

        var networkFailed = false
        var records: [Record] = []

        if let duration = track.duration, !track.album.isEmpty {
            let (record, failed) = await get(track: track, duration: duration)
            networkFailed = networkFailed || failed
            if let record { records.append(record) }
        }
        if !records.contains(where: \.hasSynced) {
            let (found, failed) = await search(title: track.title, artist: track.artist)
            networkFailed = networkFailed || failed
            records += found
        }
        if !records.contains(where: \.hasSynced) {
            let title = Self.cleanTitle(track.title)
            let artist = Self.primaryArtist(track.artist)
            if title != track.title || artist != track.artist {
                let (found, _) = await search(title: title, artist: artist)
                records += found
            }
        }

        let result = Self.choose(from: records, duration: track.duration)
        if !(networkFailed && result == .unavailable) { cache[key] = result }
        return result
    }

    // MARK: - Requests

    private func get(track: Track, duration: TimeInterval) async -> (Record?, Bool) {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            .init(name: "track_name", value: track.title),
            .init(name: "artist_name", value: track.artist),
            .init(name: "album_name", value: track.album),
            .init(name: "duration", value: String(Int(duration.rounded()))),
        ]
        do {
            let (data, response) = try await session.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return (nil, false) }
            return (try? JSONDecoder().decode(Record.self, from: data), false)
        } catch {
            return (nil, true)
        }
    }

    private func search(title: String, artist: String) async -> ([Record], Bool) {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: artist),
        ]
        do {
            let (data, response) = try await session.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return ([], false) }
            return ((try? JSONDecoder().decode([Record].self, from: data)) ?? [], false)
        } catch {
            return ([], true)
        }
    }

    // MARK: - Matching

    private static func choose(from records: [Record], duration: TimeInterval?) -> LyricsState {
        func distance(_ r: Record) -> Double {
            guard let duration, let d = r.duration else { return 0 }
            return abs(d - duration)
        }
        let synced = records.filter(\.hasSynced)
            .filter { duration == nil || $0.duration == nil || distance($0) < 15 }
            .sorted { distance($0) < distance($1) }
        if let best = synced.first, let lines = LRCParser.parse(best.syncedLyrics ?? ""), !lines.isEmpty {
            return .synced(lines)
        }
        if records.first?.instrumental == true { return .instrumental }
        if let plain = records.first(where: \.hasPlain)?.plainLyrics {
            return .plain(plain.components(separatedBy: .newlines))
        }
        return .unavailable
    }

    static func cleanTitle(_ title: String) -> String {
        let keywords = "feat|ft\\.|with|remaster|version|edit|mix|live|mono|stereo|deluxe|bonus|explicit|official|video|audio|lyrics|visualizer"
        var result = title.replacingOccurrences(
            of: "\\s*[\\(\\[][^\\)\\]]*(\(keywords))[^\\)\\]]*[\\)\\]]",
            with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(
            of: "\\s+-\\s+.*(\(keywords)).*$",
            with: "", options: [.regularExpression, .caseInsensitive])
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func primaryArtist(_ artist: String) -> String {
        let separators = [", ", " & ", " feat. ", " feat ", " ft. ", " x ", " and "]
        var result = artist
        for separator in separators {
            if let range = result.range(of: separator, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

enum LRCParser {
    private static let tag = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:[.:]\\d+)?)\\]")

    static func parse(_ lrc: String) -> [LyricLine]? {
        var entries: [(TimeInterval, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .replacingOccurrences(of: "<\\d+:\\d+(?:\\.\\d+)?>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                entries.append((minutes * 60 + seconds, text))
            }
        }
        guard !entries.isEmpty else { return nil }
        entries.sort { $0.0 < $1.0 }

        // Collapse consecutive gaps so instrumental breaks render once.
        var lines: [LyricLine] = []
        for (time, text) in entries {
            if text.isEmpty, lines.last?.isGap == true { continue }
            lines.append(LyricLine(id: lines.count, time: time, text: text))
        }
        while lines.last?.isGap == true { lines.removeLast() }
        return lines
    }
}
