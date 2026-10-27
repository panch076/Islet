import AppKit

/// Reads now-playing state from music apps and YouTube Music browser tabs over
/// Apple Events. These give exact track metadata and playback position, so they
/// are preferred over audio recognition whenever one of them is playing.
final class MediaAppBridge: @unchecked Sendable {
    struct Snapshot: Sendable {
        let source: PlaybackSource
        let isPlaying: Bool
        let track: Track
        let position: TimeInterval
    }

    struct PollResult: Sendable {
        var snapshots: [Snapshot] = []
        /// Browsers with a YouTube Music tab open that refuse JavaScript from Apple Events.
        var blockedBrowsers: [PlaybackSource] = []
    }

    enum Command {
        case playPause, next, previous
        case seek(TimeInterval)
    }

    static let musicID = "com.apple.Music"
    static let spotifyID = "com.spotify.client"
    static let kasetID = "com.sertacozercan.Kaset"
    static let chromeID = "com.google.Chrome"
    static let safariID = "com.apple.Safari"

    private let queue = DispatchQueue(label: "app.lyrical.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]
    /// Only touched on `queue`.
    private var browserTick = 0
    private var foundBrowserTab = false

    private static let separator = "\u{1F}"
    private static let jsBlocked = "ERR:JS"

    private static let musicScript = """
    tell application id "com.apple.Music"
        try
            set st to player state as text
            if st is "stopped" then return "stopped"
            set t to current track
            set sep to character id 31
            set d to 0
            try
                set d to duration of t
            end try
            return st & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (d as text) & sep & ((player position) as text) & sep & (persistent ID of t)
        on error
            return "stopped"
        end try
    end tell
    """

    private static let spotifyScript = """
    tell application id "com.spotify.client"
        try
            set st to player state as text
            if st is "stopped" then return "stopped"
            set t to current track
            set sep to character id 31
            return st & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (((duration of t) / 1000) as text) & sep & ((player position) as text) & sep & (id of t) & sep & (artwork url of t)
        on error
            return "stopped"
        end try
    end tell
    """

    private static let kasetScript = """
    tell application id "com.sertacozercan.Kaset" to get player info
    """

    private static let musicArtworkScript = """
    tell application id "com.apple.Music"
        try
            return raw data of artwork 1 of current track
        on error
            return missing value
        end try
    end tell
    """

    // MARK: YouTube Music (web)

    /// Reads the page's own media session and <video> element. Single quotes
    /// only, so it can be embedded in an AppleScript string literal.
    private static let youTubeMusicInfoJS = """
    (function(){var v=document.querySelector('video');var m=navigator.mediaSession&&navigator.mediaSession.metadata;\
    if(!v||!m||!m.title)return '';var art=(m.artwork&&m.artwork.length)?m.artwork[m.artwork.length-1].src:'';\
    var id=new URLSearchParams(location.search).get('v')||(m.title+'|'+m.artist);\
    return JSON.stringify({isPlaying:!v.paused,position:v.currentTime,duration:isFinite(v.duration)?v.duration:0,\
    currentTrack:{name:m.title,artist:m.artist||'',album:m.album||'',videoId:id,artworkURL:art}});})()
    """

    private static func youTubeMusicCommandJS(_ command: Command) -> String {
        switch command {
        case .playPause:
            "(function(){var b=document.querySelector('#play-pause-button');if(b){b.click();return 1}var v=document.querySelector('video');if(v){v.paused?v.play():v.pause()}return 1})()"
        case .next:
            "(function(){var b=document.querySelector('ytmusic-player-bar .next-button');if(b)b.click();return 1})()"
        case .previous:
            "(function(){var b=document.querySelector('ytmusic-player-bar .previous-button');if(b)b.click();return 1})()"
        case .seek(let time):
            "(function(){var v=document.querySelector('video');if(v)v.currentTime=\(String(format: "%.3f", max(0, time)));return 1})()"
        }
    }

    /// Finds the first music.youtube.com tab and runs `js` in it.
    static func browserScript(bundleID: String, js: String) -> String {
        let run = bundleID == chromeID ? "execute t javascript \"\(js)\"" : "do JavaScript \"\(js)\" in t"
        return """
        tell application id "\(bundleID)"
            repeat with w in windows
                set t to missing value
                try
                    set t to (first tab of w whose URL starts with "https://music.youtube.com")
                end try
                if t is not missing value then
                    try
                        return \(run)
                    on error
                        return "\(jsBlocked)"
                    end try
                end if
            end repeat
            return ""
        end tell
        """
    }

    // MARK: - Polling

    @MainActor
    func poll() async -> PollResult {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return await withCheckedContinuation { continuation in
            queue.async {
                var result = PollResult()
                if running.contains(Self.musicID), Self.stillRunning(Self.musicID),
                   let text = self.execute(Self.musicScript)?.stringValue,
                   let snap = Self.parseDelimited(text, source: .appleMusic) {
                    result.snapshots.append(snap)
                }
                if running.contains(Self.spotifyID), Self.stillRunning(Self.spotifyID),
                   let text = self.execute(Self.spotifyScript)?.stringValue,
                   let snap = Self.parseDelimited(text, source: .spotify) {
                    result.snapshots.append(snap)
                }
                if running.contains(Self.kasetID), Self.stillRunning(Self.kasetID),
                   let text = self.execute(Self.kasetScript)?.stringValue,
                   let snap = Self.parseJSON(text, source: .kaset) {
                    result.snapshots.append(snap)
                }
                // Scanning every browser tab is the most expensive script. Without an open YouTube Music
                // tab, only look every 4th poll; once one is found, poll it every time.
                self.browserTick += 1
                for (bundleID, source) in [(Self.chromeID, PlaybackSource.youTubeMusicChrome), (Self.safariID, .youTubeMusicSafari)]
                where (self.foundBrowserTab || self.browserTick % 4 == 1)
                    && running.contains(bundleID) && Self.stillRunning(bundleID) {
                    let text = self.execute(Self.browserScript(bundleID: bundleID, js: Self.youTubeMusicInfoJS))?.stringValue ?? ""
                    if text == Self.jsBlocked {
                        result.blockedBrowsers.append(source)
                    } else if let snap = Self.parseJSON(text, source: source) {
                        result.snapshots.append(snap)
                    }
                }
                if self.browserTick % 4 == 1 || self.foundBrowserTab {
                    self.foundBrowserTab = result.snapshots.contains { $0.source == .youTubeMusicChrome || $0.source == .youTubeMusicSafari }
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Re-checked on the script queue right before scripting: if the app quit since the poll started,
    /// `tell application id …` would relaunch it.
    private static func stillRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func musicArtwork() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                let data = self.execute(Self.musicArtworkScript)?.data
                continuation.resume(returning: (data?.count ?? 0) > 64 ? data : nil)
            }
        }
    }

    func send(_ command: Command, to source: PlaybackSource) {
        let script: String
        var cacheable = true
        if case .seek = command { cacheable = false }

        switch source {
        case .appleMusic, .spotify, .kaset:
            let bundleID = source == .appleMusic ? Self.musicID : source == .spotify ? Self.spotifyID : Self.kasetID
            let verb: String
            switch command {
            case .playPause: verb = "playpause"
            case .next: verb = "next track"
            case .previous: verb = "previous track"
            case .seek(let time):
                guard source.canSeek else { return }
                verb = "set player position to \(String(format: "%.3f", max(0, time)))"
            }
            script = "tell application id \"\(bundleID)\" to \(verb)"
        case .youTubeMusicChrome, .youTubeMusicSafari:
            let bundleID = source == .youTubeMusicChrome ? Self.chromeID : Self.safariID
            script = Self.browserScript(bundleID: bundleID, js: Self.youTubeMusicCommandJS(command))
        case .shazam:
            return
        }
        queue.async { _ = self.execute(script, cache: cacheable) }
    }

    // MARK: - Helpers

    /// Runs an arbitrary script on the bridge's queue (shuffle, repeat, playback speed…).
    func run(_ script: String) {
        queue.async { _ = self.execute(script, cache: false) }
    }

    private func execute(_ source: String, cache: Bool = true) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if cache, let existing = compiled[source] {
            script = existing
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            if cache { compiled[source] = fresh }
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    private static func parseDelimited(_ text: String, source: PlaybackSource) -> Snapshot? {
        let fields = text.components(separatedBy: separator)
        guard fields.count >= 7 else { return nil }
        func number(_ s: String) -> Double {
            Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        let duration = number(fields[4])
        let artwork = fields.count > 7 ? URL(string: fields[7]) : nil
        let track = Track(
            id: "\(source.rawValue):\(fields[6])",
            title: fields[1],
            artist: fields[2],
            album: fields[3],
            duration: duration > 0 ? duration : nil,
            artworkURL: artwork
        )
        return Snapshot(source: source, isPlaying: fields[0] == "playing", track: track, position: number(fields[5]))
    }

    /// Shared by Kaset's `get player info` and the YouTube Music page script,
    /// which deliberately emits the same shape.
    private static func parseJSON(_ text: String, source: PlaybackSource) -> Snapshot? {
        guard let data = text.data(using: .utf8),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let current = info["currentTrack"] as? [String: Any],
              let title = current["name"] as? String, !title.isEmpty else { return nil }
        func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
        let duration = max(number(info["duration"]), number(current["duration"]))
        let id = (current["videoId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title
        let artwork = (current["artworkURL"] as? String).flatMap(URL.init(string:))
        let track = Track(
            id: "\(source.rawValue):\(id)",
            title: title,
            artist: current["artist"] as? String ?? "",
            album: current["album"] as? String ?? "",
            duration: duration > 0 ? duration : nil,
            artworkURL: artwork
        )
        return Snapshot(source: source, isPlaying: info["isPlaying"] as? Bool ?? false, track: track, position: number(info["position"]))
    }
}
