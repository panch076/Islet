import AVFoundation
import ScreenCaptureKit
import ShazamKit

/// Captures system audio with ScreenCaptureKit and streams it into a
/// ShazamKit session, so songs playing in any app (browsers, video players…)
/// can be identified along with their current playback offset.
final class ShazamRecognizer: NSObject, @unchecked Sendable {
    struct Match: Sendable {
        let track: Track
        let offset: TimeInterval
        let matchedAt: Date
    }

    enum RecognizerError: Error {
        case permissionDenied
        case noDisplay
    }

    var onMatch: (@MainActor (Match) -> Void)?
    var onStatus: (@MainActor (ShazamStatus) -> Void)?

    private let session = SHSession()
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "app.lyrical.audio", qos: .userInitiated)
    private let screenQueue = DispatchQueue(label: "app.lyrical.screen", qos: .background)
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var converter: AVAudioConverter?

    private let lock = NSLock()
    private var _suspended = false
    private var _lastAudible = Date.distantPast

    /// When an app source (Music/Spotify) is playing we stop feeding Shazam.
    var isSuspended: Bool {
        get { lock.withLock { _suspended } }
        set { lock.withLock { _suspended = newValue } }
    }

    var secondsSinceAudible: TimeInterval {
        lock.withLock { Date().timeIntervalSince(_lastAudible) }
    }

    var isRunning: Bool { stream != nil }
    @MainActor private var starting = false
    @MainActor private var generation = 0

    override init() {
        super.init()
        session.delegate = self
    }

    @MainActor
    func start() async {
        guard stream == nil, !starting else { return }
        starting = true
        defer { starting = false }
        let gen = generation
        onStatus?(.starting)
        do {
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw RecognizerError.permissionDenied
            }
            guard let display = content.displays.first else { throw RecognizerError.noDisplay }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // We only want audio; keep the mandatory video stream as cheap as possible.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
            try await stream.startCapture()
            // stop() ran while we were starting: shut this stream down instead of keeping it.
            guard gen == generation else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            onStatus?(.listening)
        } catch RecognizerError.permissionDenied {
            onStatus?(.permissionNeeded)
        } catch {
            onStatus?(.failed("Couldn't capture audio: \(error.localizedDescription)"))
        }
    }

    @MainActor
    func stop() {
        generation += 1
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        onStatus?(.off)
    }

    // MARK: - Audio processing

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }

        if Self.peak(of: buffer) > 0.003 {
            lock.withLock { _lastAudible = Date() }
        }
        guard !isSuspended else { return }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return }
        session.matchStreamingBuffer(output, at: nil)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 1 }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            let data = channels[c]
            for i in stride(from: 0, to: frames, by: 8) { peak = max(peak, abs(data[i])) }
        }
        return peak
    }
}

extension ShazamRecognizer: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        process(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            self.onStatus?(.failed("Audio capture stopped: \(error.localizedDescription)"))
        }
    }
}

extension ShazamRecognizer: SHSessionDelegate {
    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first, let title = item.title else { return }
        let artist = item.artist ?? ""
        let track = Track(
            id: "shazam:" + (item.shazamID ?? "\(title)|\(artist)"),
            title: title,
            artist: artist,
            album: "",
            duration: nil,
            artworkURL: item.artworkURL,
            appleMusicID: item.appleMusicID
        )
        let result = Match(track: track, offset: item.predictedCurrentMatchOffset, matchedAt: Date())
        Task { @MainActor in
            self.onMatch?(result)
            self.onStatus?(.matched)
        }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        // "No match" is routine while listening; anything else is worth surfacing.
        if nsError.domain == SHErrorDomain, nsError.code == SHError.matchAttemptFailed.rawValue { return }
        Task { @MainActor in
            self.onStatus?(.failed("Shazam: \(nsError.localizedDescription)"))
        }
    }
}
