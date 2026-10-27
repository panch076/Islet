import AppKit
import SwiftUI

enum PlaybackSource: String, Sendable {
    case appleMusic
    case spotify
    case kaset
    case youTubeMusicChrome
    case youTubeMusicSafari
    case shazam

    var title: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .kaset: "Kaset"
        case .youTubeMusicChrome: "YouTube Music · Chrome"
        case .youTubeMusicSafari: "YouTube Music · Safari"
        case .shazam: "Shazam"
        }
    }

    var symbol: String {
        switch self {
        case .appleMusic: "music.note"
        case .spotify: "dot.radiowaves.left.and.right"
        case .kaset, .youTubeMusicChrome, .youTubeMusicSafari: "play.circle.fill"
        case .shazam: "shazam.logo.fill"
        }
    }

    var canControl: Bool { self != .shazam }

    /// Kaset's scripting dictionary has no seek command.
    var canSeek: Bool { canControl && self != .kaset }
}

struct Track: Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    var artworkURL: URL?
    var appleMusicID: String?
}

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: TimeInterval
    let text: String

    var isGap: Bool { text.isEmpty }
}

enum LyricsState: Equatable, Sendable {
    case idle
    case loading
    case synced([LyricLine])
    case plain([String])
    case instrumental
    case unavailable

    var syncedLines: [LyricLine]? {
        if case .synced(let lines) = self { return lines }
        return nil
    }
}

/// Extrapolates playback position from the last known anchor so views can
/// render smoothly between (relatively coarse) player polls.
struct PlaybackClock: Equatable {
    var position: TimeInterval = 0
    var anchor: Date = .now
    var rate: Double = 0

    func position(at date: Date) -> TimeInterval {
        max(0, position + date.timeIntervalSince(anchor) * rate)
    }
}

enum ShazamStatus: Equatable {
    case off
    case starting
    case listening
    case matched
    case permissionNeeded
    case failed(String)

    var label: String {
        switch self {
        case .off: "Off"
        case .starting: "Starting…"
        case .listening: "Listening to system audio"
        case .matched: "Song identified"
        case .permissionNeeded: "Screen & audio recording permission needed"
        case .failed(let message): message
        }
    }

    var tint: Color {
        switch self {
        case .off: .secondary
        case .starting, .listening: .blue
        case .matched: .green
        case .permissionNeeded, .failed: .orange
        }
    }
}

extension Array where Element == LyricLine {
    /// Index of the last line whose timestamp is at or before `time`.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard let first, time >= first.time else { return nil }
        var low = 0, high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if self[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// How far through singing the line at `index` we are at `time` (0 = not
    /// started, ≥1 = finished). Lines have no per-word timing, so the sweep is
    /// paced by text length, capped by when the next line starts.
    func sweepProgress(at index: Int, time: TimeInterval) -> Double {
        let line = self[index]
        let next = index + 1 < count ? self[index + 1].time : line.time + 5
        let span = Swift.min(next - line.time, Double(line.text.count) * 0.085 + 0.9)
        return span > 0 ? (time - line.time) / span : 1
    }
}

enum Prefs {
    static let fontScale = "fontScale"
    static let syncOffset = "syncOffset"
    static let panelGlass = "panelGlass"
    static let showArtwork = "showArtwork"
    static let showNextLine = "showNextLine"
    static let karaokeSweep = "karaokeSweep"
    static let floatingVisible = "floatingVisible"
    static let panelLocked = "panelLocked"
    static let shazamEnabled = "shazamEnabled"

    static func register() {
        UserDefaults.standard.register(defaults: [
            fontScale: 1.0,
            syncOffset: 0.0,
            panelGlass: PanelGlass.regular.rawValue,
            showArtwork: true,
            showNextLine: true,
            karaokeSweep: true,
            floatingVisible: true,
            panelLocked: false,
            shazamEnabled: false,
        ])
    }
}

enum PanelGlass: String, CaseIterable, Identifiable {
    case regular, clear, tinted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .regular: "Frosted"
        case .clear: "Clear"
        case .tinted: "Album Tint"
        }
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", s / 60, s % 60)
}
