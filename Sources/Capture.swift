import AVFoundation
import Combine
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

struct AudioWindow: Sendable {
    static let sampleRate = 16_000
    static let sampleCount = sampleRate * 12

    let samples: [Int16]
    let startedAt: Date

    var duration: TimeInterval { Double(samples.count) / Double(Self.sampleRate) }
    var endedAt: Date { startedAt.addingTimeInterval(duration) }
}

@MainActor
final class CaptureController: ObservableObject {
    enum State: Equatable {
        case idle
        case picking
        case starting
        case listening
        case stopping
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level = 0.0
    @Published private(set) var windowCount = 0

    var onWindow: ((AudioWindow) -> Void)?
    var onGap: (() -> Void)?

    var isCapturing: Bool { state == .listening }
    var canStart: Bool {
        switch state {
        case .idle, .failed: true
        default: false
        }
    }
    var status: String {
        switch state {
        case .idle: "Ready to listen"
        case .picking: "Choose full-display capture in the system picker"
        case .starting: "Starting audio capture"
        case .listening: "Listening to device audio"
        case .stopping: "Stopping capture"
        case .failed(let message): message
        }
    }

    private var session: UUID?
    private var attempt: UUID?
    private var observer: PickerObserver?
    private var receiver: CaptureAudioReceiver?
    private var stream: SCStream?
    private var operation: Task<Void, Never>?

    func start() {
        guard canStart else { return }
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable, !picker.isActive else {
            state = .failed("The system capture picker is unavailable")
            return
        }

        let session = UUID()
        self.session = session
        windowCount = 0
        level = 0
        state = .picking

        let observer = PickerObserver { [weak self] event in
            DispatchQueue.main.async { self?.handlePicker(event, session: session) }
        }
        self.observer = observer
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(observer)
        picker.isActive = true
        picker.present()
    }

    func stop() {
        guard let session, state != .stopping else { return }
        if state == .picking {
            finish(session, as: .idle)
            return
        }

        state = .stopping
        level = 0
        onGap?()
        if let operation {
            // Let the in-flight start finish before stopping its stream.
            operation.cancel()
            return
        }
        operation = Task { [weak self, stream = self.stream] in
            try? await stream?.stopCapture()
            self?.finish(session, as: .idle)
        }
    }

    private func handlePicker(_ event: PickerEvent, session: UUID) {
        guard self.session == session, state == .picking else { return }
        switch event {
        case .selected(let selection):
            state = .starting
            operation = Task { [weak self] in
                guard let self else { return }
                await startStream(filter: selection.filter, session: session)
            }
        case .cancelled:
            finish(session, as: .idle)
        case .failed(let message):
            finish(session, as: .failed(message))
        }
    }

    private func dismissPicker() {
        guard let observer else { return }
        let picker = SCContentSharingPicker.shared
        picker.remove(observer)
        picker.isActive = false
        self.observer = nil
    }

    private func startStream(filter: SCContentFilter, session: UUID) async {
        var failure = "ScreenCaptureKit could not start audio capture"
        for needsScreenOutput in [false, true] {
            guard !Task.isCancelled else { break }

            let attempt = UUID()
            self.attempt = attempt
            let receiver = CaptureAudioReceiver { [weak self] event in
                DispatchQueue.main.async { self?.handleAudio(event, session: session, attempt: attempt) }
            }
            self.receiver = receiver

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = AudioWindow.sampleRate
            configuration.channelCount = 1
            configuration.width = 320
            configuration.height = 568
            let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
            self.stream = stream

            do {
                try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: receiver.queue)
                if needsScreenOutput {
                    try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
                }
                try await stream.startCapture()
                if Task.isCancelled {
                    try? await stream.stopCapture()
                    break
                }
                dismissPicker()
                operation = nil
                state = .listening
                return
            } catch {
                if Task.isCancelled || (error as? SCStreamError)?.code == .userStopped {
                    finish(session, as: .idle)
                    return
                }
                if let message = captureAuthorizationMessage(error) {
                    finish(session, as: .failed(message))
                    return
                }
                failure = error.localizedDescription
                self.attempt = nil
                self.stream = nil
                self.receiver = nil
            }
        }
        finish(session, as: Task.isCancelled ? .idle : .failed(failure))
    }

    private func handleAudio(_ event: CaptureEvent, session: UUID, attempt: UUID) {
        guard self.session == session, self.attempt == attempt, state == .listening else { return }
        switch event {
        case .level(let level):
            self.level = level
        case .window(let window):
            windowCount += 1
            onWindow?(window)
        case .gap:
            level = 0
            onGap?()
        case .stopped(let message):
            onGap?()
            finish(session, as: message.map(State.failed) ?? .idle)
        }
    }

    private func finish(_ session: UUID, as nextState: State) {
        guard self.session == session else { return }
        dismissPicker()
        self.session = nil
        attempt = nil
        stream = nil
        receiver = nil
        operation = nil
        level = 0
        state = nextState
    }
}

// The picker gives us a new filter. Only the main actor accesses it after this handoff.
private struct PickerSelection: @unchecked Sendable {
    let filter: SCContentFilter
}

private enum PickerEvent: Sendable {
    case selected(PickerSelection)
    case cancelled
    case failed(String)
}

private final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let receive: @Sendable (PickerEvent) -> Void

    init(receive: @escaping @Sendable (PickerEvent) -> Void) {
        self.receive = receive
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        receive(.selected(PickerSelection(filter: filter)))
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        receive(.cancelled)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        receive(.failed(captureAuthorizationMessage(error) ?? error.localizedDescription))
    }
}

private func captureAuthorizationMessage(_ error: any Error) -> String? {
    switch (error as? SCStreamError)?.code {
    case .missingEntitlements:
        "This build is missing the Screen Recording entitlement. Install a build signed with a provisioning profile that allows it."
    case .userDeclined:
        "Screen Recording permission was declined. Start again and approve the system capture request."
    default:
        nil
    }
}

private enum CaptureEvent: Sendable {
    case level(Double)
    case gap
    case window(AudioWindow)
    case stopped(String?)
}

private final class CaptureAudioReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "scrobbler.capture.audio", qos: .userInitiated)
    private let receive: @Sendable (CaptureEvent) -> Void
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioWindow.sampleRate),
        channels: 1,
        interleaved: false
    )!

    // All mutable receiver state is confined to queue.
    private var converter: AVAudioConverter?
    private var watchdog: DispatchSourceTimer?
    private var previousEnd: TimeInterval?
    private var nextOutputDate: Date?
    private var lastBufferUptime: TimeInterval?
    private var lastMeterUptime = 0.0
    private var silentDuration = 0.0
    private var hasSignal = false
    private var windowStart: Date?
    private var pending: [Int16] = []

    init(receive: @escaping @Sendable (CaptureEvent) -> Void) {
        self.receive = receive
        super.init()
        pending.reserveCapacity(AudioWindow.sampleCount)
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + .seconds(1), repeating: .milliseconds(500), leeway: .milliseconds(100))
        watchdog.setEventHandler { [weak self] in
            guard let self, let lastBufferUptime,
                  ProcessInfo.processInfo.systemUptime - lastBufferUptime > 1.25 else { return }
            resetAfterGap()
        }
        self.watchdog = watchdog
        watchdog.resume()
    }

    deinit { watchdog?.cancel() }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let didUserStop = (error as? SCStreamError)?.code == .userStopped
        receive(.stopped(didUserStop ? nil : captureAuthorizationMessage(error) ?? error.localizedDescription))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // A screen subscription is only a compatibility fallback. No frames are processed.
        guard type == .audio else { return }
        guard sampleBuffer.isValid, let description = sampleBuffer.formatDescription,
              let count = AVAudioFrameCount(exactly: sampleBuffer.numSamples), count > 0,
              count <= AVAudioFrameCount(Int32.max) else { return }

        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let duration = Double(count) / format.sampleRate
        guard duration.isFinite, duration > 0, duration < 2,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        input.frameLength = count
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList
        ) == noErr else {
            resetAfterGap()
            return
        }

        let presentation = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        if let previousEnd, presentation.isFinite, abs(presentation - previousEnd) > 0.03 {
            resetAfterGap()
        }
        if let converter, !converter.inputFormat.isEqual(format) {
            resetAfterGap()
            self.converter = nil
        }
        previousEnd = presentation.isFinite ? presentation + duration : nil
        lastBufferUptime = ProcessInfo.processInfo.systemUptime
        if converter == nil {
            converter = AVAudioConverter(from: format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter,
              let output = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(duration * outputFormat.sampleRate)) + 128
              ) else {
            resetAfterGap()
            return
        }

        let supply = ConverterInput(input)
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            supply.take(status)
        }
        guard result != .error, conversionError == nil else {
            resetAfterGap()
            return
        }
        guard output.frameLength > 0, let pcm = output.int16ChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: pcm, count: Int(output.frameLength))
        let start = nextOutputDate ?? Date().addingTimeInterval(-duration)
        nextOutputDate = start.addingTimeInterval(Double(samples.count) / outputFormat.sampleRate)
        append(samples, startingAt: start)
    }

    private func append(_ samples: UnsafeBufferPointer<Int16>, startingAt start: Date) {
        let sumOfSquares = samples.reduce(0.0) { sum, sample in
            let value = Double(sample) / 32_768
            return sum + value * value
        }
        let rms = sqrt(sumOfSquares / Double(samples.count))
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMeterUptime >= 0.1 {
            receive(.level(rms))
            lastMeterUptime = now
        }
        if rms < 0.0018 {
            silentDuration += Double(samples.count) / outputFormat.sampleRate
            if silentDuration >= 1.25, hasSignal {
                resetAfterGap()
            }
            if pending.isEmpty { return }
        } else {
            hasSignal = true
            silentDuration = 0
        }

        var offset = 0
        while offset < samples.count {
            if pending.isEmpty {
                windowStart = start.addingTimeInterval(Double(offset) / outputFormat.sampleRate)
            }
            let end = min(samples.count, offset + AudioWindow.sampleCount - pending.count)
            pending.append(contentsOf: samples[offset ..< end])
            offset = end
            if pending.count == AudioWindow.sampleCount, let windowStart {
                receive(.window(AudioWindow(samples: pending, startedAt: windowStart)))
                pending.removeAll(keepingCapacity: true)
                self.windowStart = nil
            }
        }
    }

    private func resetAfterGap() {
        // Signal a discontinuity even when it falls exactly on a completed window boundary.
        let wasReceiving = hasSignal
        hasSignal = false
        pending.removeAll(keepingCapacity: true)
        windowStart = nil
        previousEnd = nil
        nextOutputDate = nil
        lastBufferUptime = nil
        silentDuration = 0
        converter?.reset()
        if wasReceiving { receive(.gap) }
    }
}

// AVAudioConverter requests more input synchronously within one conversion.
private final class ConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
