import Foundation

struct RecognizedTrack: Codable, Equatable, Sendable {
    let key: String
    let artist: String
    let title: String
    let durationSeconds: Double?
}

struct DetectedPlay: Identifiable, Codable {
    let id: UUID
    var track: RecognizedTrack
    let startedAt: Date
    var listened: TimeInterval
    var qualified = false
    var enqueued: Bool? = nil
}

struct PlayTracker {
    struct Update {
        var confirmed: DetectedPlay?
        var qualified: DetectedPlay?
    }

    private struct Candidate {
        let key: String
        let startedAt: Date
        let endedAt: Date
        let listened: TimeInterval
    }

    private(set) var current: DetectedPlay?
    private var candidate: Candidate?
    private var lastWindowEnd: Date?
    private var misses = 0

    mutating func observe(_ track: RecognizedTrack, startedAt: Date, duration: TimeInterval) -> Update {
        let endedAt = startedAt.addingTimeInterval(duration)
        let unseenStart = max(startedAt, lastWindowEnd ?? startedAt)
        guard endedAt > unseenStart else { return Update() }
        let listened = endedAt.timeIntervalSince(unseenStart)
        lastWindowEnd = endedAt
        misses = 0

        var update = Update()
        if var play = current, play.track.key == track.key {
            candidate = nil
            if track.durationSeconds != nil { play.track = track }
            play.listened += listened
            current = play
        } else if let prior = candidate, prior.key == track.key,
                  abs(unseenStart.timeIntervalSince(prior.endedAt)) <= 0.75 {
            let play = DetectedPlay(id: UUID(), track: track, startedAt: prior.startedAt,
                                    listened: prior.listened + listened)
            candidate = nil
            current = play
            update.confirmed = play
        } else {
            candidate = Candidate(key: track.key, startedAt: unseenStart, endedAt: endedAt, listened: listened)
        }

        if var play = current, !play.qualified, let length = play.track.durationSeconds,
           length.isFinite, length > 30, play.listened >= min(length / 2, 240) {
            play.qualified = true
            current = play
            update.qualified = play
        }
        return update
    }

    mutating func miss() {
        candidate = nil
        misses += 1
        if misses >= 2 { current = nil }
    }

    mutating func skipWindow() {
        candidate = nil
    }
}
