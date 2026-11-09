import Foundation

@main
enum PlayTrackerChecks {
    static func main() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let track = RecognizedTrack(key: "a", artist: "Artist", title: "Song", durationSeconds: 60)
        let other = RecognizedTrack(key: "b", artist: "Artist", title: "Next", durationSeconds: nil)
        var tracker = PlayTracker()

        func observe(_ track: RecognizedTrack, at offset: TimeInterval) -> PlayTracker.Update {
            tracker.observe(track, startedAt: epoch.addingTimeInterval(offset), duration: 12)
        }

        precondition(observe(track, at: 0).confirmed == nil)
        precondition(observe(track, at: 0).confirmed == nil, "A repeated window cannot confirm a play")
        let firstPlay = observe(track, at: 12).confirmed
        precondition(firstPlay?.startedAt == epoch && firstPlay?.listened == 24)
        precondition(observe(track, at: 12).qualified == nil, "A repeated window cannot qualify a play")
        let qualified = observe(track, at: 24).qualified
        precondition(qualified?.id == firstPlay?.id && qualified?.listened == 36)
        precondition(observe(track, at: 36).qualified == nil, "A qualifying play should emit once")

        precondition(observe(other, at: 48).confirmed == nil)
        let next = observe(other, at: 60)
        precondition(next.confirmed?.track == other && next.qualified == nil)
        tracker.miss()
        precondition(tracker.current != nil)
        tracker.miss()
        precondition(tracker.current == nil)

        tracker = PlayTracker()
        precondition(observe(track, at: 0).confirmed == nil)
        precondition(observe(track, at: 24).confirmed == nil, "Windows separated by a gap cannot confirm a play")
        precondition(observe(track, at: 36).confirmed?.startedAt == epoch.addingTimeInterval(24))
        print("Play tracker checks passed")
    }
}
