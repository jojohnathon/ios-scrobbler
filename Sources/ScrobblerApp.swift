import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct ScrobblerApp: App {
    @StateObject private var session = ListeningSession()

    var body: some Scene {
        WindowGroup { ScrobblerView(session: session, capture: session.capture) }
    }
}

@MainActor
final class ListeningSession: ObservableObject {
    let capture = CaptureController()
    let lastFM = LastFMController()
    @Published private(set) var current: DetectedPlay?
    @Published private(set) var history: [DetectedPlay] = []
    @Published private(set) var lookupStatus = "Waiting for audio"
    @Published private(set) var lastMatch: RecognizedTrack?
    @Published private(set) var testingFile = false

    private let recognizer = ShazamRecognizer()
    private let historyURL: URL
    private var tracker = PlayTracker()
    private var lookup: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0
    private var retryAfter = Date.distantPast

    init() {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("Scrobbler", isDirectory: true)
        historyURL = folder.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: historyURL) {
            history = (try? JSONDecoder().decode([DetectedPlay].self, from: data)) ?? []
        }
        capture.onWindow = { [weak self] window in self?.handle(window) }
        capture.onGap = { [weak self] in self?.resetPlay() }
    }

    func start() {
        resetPlay()
        capture.start()
    }

    func stop() {
        capture.stop()
        resetPlay()
    }

    private func resetPlay() {
        generation += 1
        tracker = PlayTracker()
        current = nil
        lookupStatus = "Waiting for audio"
    }

    private func handle(_ window: AudioWindow) {
        guard lookup == nil, !testingFile, Date() >= retryAfter else {
            tracker.skipWindow()
            return
        }
        let token = generation
        lookupStatus = "Identifying audio…"
        lookup = Task { [weak self] in
            guard let self else { return }
            defer { lookup = nil }
            do {
                let match = try await recognizer.recognize(window.samples)
                guard generation == token else { return }
                consecutiveFailures = 0
                if let match {
                    lastMatch = match
                    lookupStatus = "Match found"
                    let update = tracker.observe(match, startedAt: window.startedAt, duration: window.duration)
                    current = tracker.current
                    if let play = update.confirmed {
                        remember(play)
                        Task { await lastFM.nowPlaying(play.track) }
                    }
                    if let play = update.qualified {
                        remember(play)
                        Task { await enqueue(play) }
                    }
                } else {
                    tracker.miss()
                    current = tracker.current
                    lookupStatus = "No match"
                }
            } catch {
                guard generation == token else { return }
                tracker.skipWindow()
                consecutiveFailures = min(consecutiveFailures + 1, 4)
                let delay = 12 * (1 << (consecutiveFailures - 1))
                retryAfter = Date().addingTimeInterval(Double(delay))
                lookupStatus = "Lookup unavailable. Retrying in \(delay)s."
            }
        }
    }

    func testFile(_ url: URL) async {
        guard !testingFile, capture.canStart, lookup == nil else { return }
        testingFile = true
        lookupStatus = "Reading test WAV…"
        defer { testingFile = false }
        do {
            let samples = try await Task.detached(priority: .userInitiated) { try WAVProbe.read(url) }.value
            lookupStatus = "Identifying test clip…"
            lastMatch = try await recognizer.recognize(samples)
            lookupStatus = lastMatch == nil ? "No match for test clip" : "Test clip matched"
        } catch {
            lookupStatus = error.localizedDescription
        }
    }

    func retryScrobbles() async {
        for play in history.reversed() where play.qualified && play.enqueued != true {
            await enqueue(play)
        }
        await lastFM.retryPending()
    }

    private func enqueue(_ play: DetectedPlay) async {
        if await lastFM.submit(play.track, startedAt: play.startedAt, playID: play.id) {
            var saved = play
            saved.enqueued = true
            remember(saved)
        }
    }

    private func remember(_ play: DetectedPlay) {
        if let index = history.firstIndex(where: { $0.id == play.id }) {
            history[index] = play
        } else {
            history.insert(play, at: 0)
            if history.count > 100,
               let removable = history.lastIndex(where: { !$0.qualified || $0.enqueued == true }) {
                history.remove(at: removable)
            }
        }
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
        } catch {
            lookupStatus = "Could not save local history"
        }
    }
}

private enum WAVProbe {
    static func read(_ url: URL) throws -> [Int16] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let frames: AVAudioFrameCount = 192_000
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw ProbeError.invalidFormat
        }
        try file.read(into: buffer, frameCount: frames)
        guard buffer.frameLength == frames, let samples = buffer.int16ChannelData?[0] else {
            throw ProbeError.tooShort
        }
        return Array(UnsafeBufferPointer(start: samples, count: Int(frames)))
    }

    enum ProbeError: LocalizedError {
        case invalidFormat, tooShort

        var errorDescription: String? {
            switch self {
            case .invalidFormat: "Choose a 16 kHz mono WAV."
            case .tooShort: "Choose a WAV that is at least 12 seconds long."
            }
        }
    }
}
