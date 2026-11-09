import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ScrobblerView: View {
    @ObservedObject var session: ListeningSession
    @ObservedObject var capture: CaptureController
    @Environment(\.scenePhase) private var scenePhase
    @State private var importingWAV = false
    @State private var showingSettings = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Capture") {
                    Text(capture.status)
                    ProgressView(value: capture.level) { Text("Device audio level") }
                    LabeledContent("Audio windows", value: capture.windowCount.formatted())
                    if let receivedAt = capture.lastAudioAt {
                        LabeledContent("Last audio buffer", value: receivedAt.formatted(date: .omitted, time: .standard))
                    }
                    if let interruption = capture.lastInterruption {
                        Text(interruption).font(.caption).foregroundStyle(.secondary)
                    }

                    if capture.canStart {
                        Button("Start listening", systemImage: "waveform") { session.start() }
                            .disabled(session.testingFile)
                    } else {
                        Button("Stop capture", systemImage: "stop.circle", role: .destructive) { session.stop() }
                    }
                }

                Section("Recognition") {
                    Text(importError ?? session.lookupStatus)
                    if let match = session.lastMatch {
                        trackLabel(match)
                    }
                    Button("Test a WAV file", systemImage: "doc.badge.waveform") {
                        importError = nil
                        importingWAV = true
                    }
                    .disabled(!capture.canStart || session.testingFile)
                }

                if let play = session.current {
                    Section("Confirmed play") {
                        trackLabel(play.track)
                        LabeledContent("Matched audio", value: "\(Int(play.listened))s")
                    }
                }

                Section("Local history") {
                    if session.history.isEmpty {
                        Text("Confirmed plays will appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(session.history) { play in
                        VStack(alignment: .leading, spacing: 4) {
                            trackLabel(play.track)
                            Text(play.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if play.qualified {
                                Text("Qualified for Last.fm").font(.caption).foregroundStyle(.secondary)
                            } else if play.track.durationSeconds == nil {
                                Text("Track length unknown").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scrobbler")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Last.fm settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .sheet(isPresented: $showingSettings) { LastFMSettings(controller: session.lastFM) }
            .fileImporter(isPresented: $importingWAV, allowedContentTypes: [.wav]) { result in
                switch result {
                case .success(let url): Task { await session.testFile(url) }
                case .failure(let error): importError = error.localizedDescription
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                // Let pending stream callbacks run before checking whether capture ended.
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                capture.checkStreamAfterForeground()
                while !Task.isCancelled {
                    await session.retryScrobbles()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                }
            }
        }
    }

    private func trackLabel(_ track: RecognizedTrack) -> some View {
        VStack(alignment: .leading) {
            Text(track.title).font(.headline)
            Text(track.artist).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct LastFMSettings: View {
    @ObservedObject var controller: LastFMController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let name = controller.username {
                        LabeledContent("Signed in as", value: name)
                        Button("Retry pending scrobbles") { perform { await controller.retryPending() } }
                            .disabled(busy)
                        Button("Sign out", role: .destructive) { controller.signOut() }.disabled(busy)
                    } else {
                        TextField("Last.fm API key", text: $controller.apiKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Last.fm shared secret", text: $controller.apiSecret)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Authorize in browser") {
                            perform {
                                if let url = await controller.startAuthorization() { openURL(url) }
                            }
                        }
                        .disabled(busy || controller.apiKey.isEmpty || controller.apiSecret.isEmpty)
                        Button("Finish authorization") { perform { await controller.finishAuthorization() } }
                            .disabled(busy)
                    }
                }
                Section("Status") { Text(controller.status) }
            }
            .navigationTitle("Last.fm")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        busy = true
        Task {
            defer { busy = false }
            await action()
        }
    }
}
