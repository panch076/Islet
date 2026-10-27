import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class NowPlayingModel {
    static let shared = NowPlayingModel()

    private(set) var track: Track?
    private(set) var source: PlaybackSource?
    private(set) var isPlaying = false
    private(set) var clock = PlaybackClock()
    private(set) var artwork: NSImage?
    private(set) var palette: [Color] = ArtworkPalette.fallback
    private(set) var lyrics: LyricsState = .idle
    private(set) var shazamStatus: ShazamStatus = .off
    /// Browsers with a YouTube Music tab that block JavaScript from Apple Events.
    private(set) var blockedBrowsers: [PlaybackSource] = []

    var canControl: Bool { source?.canControl ?? false }
    var canSeek: Bool { source?.canSeek ?? false }
    var accent: Color { ArtworkPalette.accent(from: palette) }

    @ObservationIgnored let bridge = MediaAppBridge()
    @ObservationIgnored private let shazam = ShazamRecognizer()
    @ObservationIgnored private let lyricsService = LyricsService()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var appSnapshots: [MediaAppBridge.Snapshot] = []
    @ObservationIgnored private var shazamMatch: ShazamRecognizer.Match?
    @ObservationIgnored private var commandGrace = Date.distantPast

    func time(at date: Date) -> TimeInterval { clock.position(at: date) }

    // MARK: - Lifecycle

    func start() {
        shazam.onMatch = { [weak self] match in self?.handle(match) }
        shazam.onStatus = { [weak self] status in self?.shazamStatus = status }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                // Poll briskly while music plays; back off when nothing is playing.
                let playing = await MainActor.run { self?.isPlaying ?? false }
                try? await Task.sleep(for: .milliseconds(playing ? 900 : 2000))
            }
        }
        if UserDefaults.standard.bool(forKey: Prefs.shazamEnabled) {
            setShazamEnabled(true)
        }
    }

    func setShazamEnabled(_ enabled: Bool) {
        if enabled {
            Task { await shazam.start() }
        } else {
            shazam.stop()
            shazamMatch = nil
            resolve()
        }
    }

    // MARK: - Source resolution

    private func poll() async {
        let result = await bridge.poll()
        appSnapshots = result.snapshots
        if blockedBrowsers != result.blockedBrowsers { blockedBrowsers = result.blockedBrowsers }
        resolve()
    }

    private func resolve() {
        let now = Date()

        if let playing = appSnapshots.first(where: \.isPlaying) {
            shazam.isSuspended = true
            apply(playing, now: now)
            return
        }
        shazam.isSuspended = false

        if let match = shazamMatch, shazam.isRunning {
            let silence = shazam.secondsSinceAudible
            let elapsed = match.offset + now.timeIntervalSince(match.matchedAt)
            let pastEnd = (match.track.duration).map { elapsed > $0 + 5 } ?? false
            if silence < 45 && !pastEnd {
                applyShazam(match, now: now, audible: silence < 2.5)
                return
            }
            shazamMatch = nil
        }

        if let paused = appSnapshots.first {
            apply(paused, now: now)
            return
        }

        if track != nil {
            track = nil
            source = nil
            isPlaying = false
            artwork = nil
            lyrics = .idle
            palette = ArtworkPalette.fallback
            clock = PlaybackClock()
        }
    }

    private func apply(_ snapshot: MediaAppBridge.Snapshot, now: Date) {
        setTrack(snapshot.track, source: snapshot.source)
        // Right after a transport command the app may still report the old state.
        guard now > commandGrace else { return }
        if isPlaying != snapshot.isPlaying { isPlaying = snapshot.isPlaying }
        syncClock(position: snapshot.position, rate: snapshot.isPlaying ? 1 : 0, now: now, tolerance: 0.35)
    }

    private func applyShazam(_ match: ShazamRecognizer.Match, now: Date, audible: Bool) {
        setTrack(match.track, source: .shazam)
        isPlaying = audible
        let position = match.offset + now.timeIntervalSince(match.matchedAt)
        syncClock(position: position, rate: audible ? 1 : 0, now: now, tolerance: 1.0)
    }

    private func handle(_ match: ShazamRecognizer.Match) {
        var match = match
        // Keep metadata we enriched earlier for the same song.
        if let current = track, current.id == match.track.id {
            match = .init(track: current, offset: match.offset, matchedAt: match.matchedAt)
        }
        let isNewSong = shazamMatch?.track.id != match.track.id
        shazamMatch = match
        if isNewSong, source == .shazam || source == nil {
            // Force a clock reset on a new song rather than waiting for drift tolerance.
            clock = PlaybackClock(position: match.offset, anchor: match.matchedAt, rate: 1)
        }
        resolve()
    }

    private func syncClock(position: TimeInterval, rate: Double, now: Date, tolerance: Double) {
        let predicted = clock.position(at: now)
        if rate != clock.rate || abs(predicted - position) > tolerance {
            clock = PlaybackClock(position: position, anchor: now, rate: rate)
        }
    }

    private func setTrack(_ newTrack: Track, source newSource: PlaybackSource) {
        if source != newSource { source = newSource }
        guard newTrack.id != track?.id else { return }

        track = newTrack
        lyrics = .loading
        clock = PlaybackClock(position: 0, anchor: .now, rate: clock.rate)
        lyricsTask?.cancel()
        artworkTask?.cancel()

        let id = newTrack.id
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            var resolved = newTrack
            if newSource == .shazam, let enriched = await self.enrich(newTrack) {
                resolved = enriched
                guard !Task.isCancelled, self.track?.id == id else { return }
                self.track = enriched
                if let match = self.shazamMatch, match.track.id == id {
                    self.shazamMatch = .init(track: enriched, offset: match.offset, matchedAt: match.matchedAt)
                }
            }
            let state = await self.lyricsService.lyrics(for: resolved)
            guard !Task.isCancelled, self.track?.id == id else { return }
            withAnimation(.smooth) { self.lyrics = state }
        }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let image = await self.loadArtwork(for: newTrack, source: newSource)
            guard !Task.isCancelled, self.track?.id == id else { return }
            withAnimation(.smooth(duration: 0.8)) {
                self.artwork = image
                self.palette = image.map(ArtworkPalette.colors(from:)) ?? ArtworkPalette.fallback
            }
        }
    }

    private func enrich(_ track: Track) async -> Track? {
        let item: ITunesMetadata.Item?
        if let id = track.appleMusicID {
            item = await ITunesMetadata.lookup(appleMusicID: id)
        } else {
            item = await ITunesMetadata.search(title: track.title, artist: track.artist)
        }
        guard let item else { return nil }
        var enriched = track
        enriched.album = item.collectionName ?? track.album
        enriched.duration = item.trackTimeMillis.map { $0 / 1000 }
        if enriched.artworkURL == nil, let art = item.artworkUrl100 { enriched.artworkURL = URL(string: art) }
        return enriched
    }

    private func loadArtwork(for track: Track, source: PlaybackSource) async -> NSImage? {
        if source == .appleMusic, let data = await bridge.musicArtwork(), let image = NSImage(data: data) {
            return image
        }
        if let image = await ImageLoader.load(ITunesMetadata.highResolution(track.artworkURL)) {
            return image
        }
        if let image = await ImageLoader.load(track.artworkURL) {
            return image
        }
        let item = await ITunesMetadata.search(title: track.title, artist: track.artist)
        return await ImageLoader.load(ITunesMetadata.highResolution(item?.artworkUrl100.flatMap(URL.init(string:))))
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let source, canControl else { return }
        bridge.send(.playPause, to: source)
        let now = Date()
        isPlaying.toggle()
        clock = PlaybackClock(position: clock.position(at: now), anchor: now, rate: isPlaying ? 1 : 0)
        commandGrace = now.addingTimeInterval(1.2)
    }

    func next() {
        guard let source, canControl else { return }
        bridge.send(.next, to: source)
    }

    func previous() {
        guard let source, canControl else { return }
        bridge.send(.previous, to: source)
    }

    func seek(to time: TimeInterval) {
        guard let source, canSeek else { return }
        bridge.send(.seek(time), to: source)
        let now = Date()
        clock = PlaybackClock(position: max(0, time), anchor: now, rate: clock.rate)
        commandGrace = now.addingTimeInterval(1.2)
    }
}
