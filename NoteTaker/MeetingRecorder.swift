import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecordingFolderNamer {
    static func sanitizedTitle(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
        let separated = title.components(separatedBy: invalidCharacters).joined(separator: "-")
        let compactedWhitespace = separated
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"\s*-+\s*"#,
                with: " - ",
                options: .regularExpression
            )
        let trimmed = compactedWhitespace.trimmingCharacters(
            in: CharacterSet(charactersIn: " .-")
        )
        let shortened = String(trimmed.prefix(80)).trimmingCharacters(
            in: CharacterSet(charactersIn: " .-")
        )
        return shortened.isEmpty ? "Meeting" : shortened
    }

    static func folderName(for title: String?, at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return "\(sanitizedTitle(title ?? "")) - \(timestamp)"
    }
}

struct SavedMeetingSession: Identifiable, Hashable {
    let directoryURL: URL
    let title: String
    let startedAt: Date
    let updatedAt: Date
    let hasMicrophoneAudio: Bool
    let hasSystemAudio: Bool

    var id: String { directoryURL.path }
    var displayName: String { directoryURL.lastPathComponent }

    static func discover(
        in meetingsDirectory: URL,
        fileManager: FileManager = .default
    ) -> [SavedMeetingSession] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        guard let directories = try? fileManager.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let sessions: [SavedMeetingSession] = directories.compactMap { directory -> SavedMeetingSession? in
            guard let values = try? directory.resourceValues(forKeys: resourceKeys),
                  values.isDirectory == true else { return nil }
            let microphoneURL = directory.appendingPathComponent("microphone.m4a")
            let systemURL = directory.appendingPathComponent("system-audio.m4a")
            let transcriptURL = directory.appendingPathComponent("meeting-transcript.md")
            let hasMicrophone = fileManager.fileExists(atPath: microphoneURL.path)
            let hasSystem = fileManager.fileExists(atPath: systemURL.path)
            guard hasMicrophone || hasSystem || fileManager.fileExists(atPath: transcriptURL.path) else {
                return nil
            }

            let date = values.creationDate ?? values.contentModificationDate ?? .distantPast
            let folderName = directory.lastPathComponent
            let title = folderName.replacingOccurrences(
                of: #"\s+-\s+\d{4}-\d{2}-\d{2}T.*$"#,
                with: "",
                options: .regularExpression
            )
            return SavedMeetingSession(
                directoryURL: directory,
                title: title.isEmpty ? "Meeting" : title,
                startedAt: date,
                updatedAt: values.contentModificationDate ?? date,
                hasMicrophoneAudio: hasMicrophone,
                hasSystemAudio: hasSystem
            )
        }
        return sortedNewestFirst(sessions)
    }

    static func sortedNewestFirst(_ sessions: [SavedMeetingSession]) -> [SavedMeetingSession] {
        sessions.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.displayName > $1.displayName
            }
            return $0.startedAt > $1.startedAt
        }
    }
}

private enum RecordingAudioError: LocalizedError {
    case writerFinishTimedOut

    var errorDescription: String? {
        "Audio finalization took too long. The recording files were preserved for retry."
    }
}

private final class RecordingAudioTrackWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var sessionStarted = false
    private var isFinishing = false

    init(url: URL, channels: Int, bitRate: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate
        ])
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(
                domain: "NoteTaker",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Could not configure an audio writer."]
            )
        }
        writer.add(input)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(
                domain: "NoteTaker",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Could not start an audio writer."]
            )
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinishing, writer.status == .writing else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish(timeout: TimeInterval = 15) async throws {
        let shouldFinish = try prepareForFinish()

        guard shouldFinish else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completionLock = NSLock()
            var completed = false
            var timeoutWorkItem: DispatchWorkItem?

            func complete(_ error: Error?) {
                completionLock.lock()
                guard !completed else {
                    completionLock.unlock()
                    return
                }
                completed = true
                completionLock.unlock()
                timeoutWorkItem?.cancel()
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            writer.finishWriting {
                complete(self.writer.status == .failed ? self.writer.error : nil)
            }
            let workItem = DispatchWorkItem {
                self.writer.cancelWriting()
                complete(RecordingAudioError.writerFinishTimedOut)
            }
            timeoutWorkItem = workItem
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: workItem
            )
        }
    }

    private func prepareForFinish() throws -> Bool {
        lock.lock()
        guard !isFinishing else {
            lock.unlock()
            return false
        }
        isFinishing = true
        if writer.status == .writing {
            input.markAsFinished()
        }
        let shouldFinish = writer.status == .writing
        lock.unlock()

        guard shouldFinish else {
            if writer.status == .failed, let error = writer.error { throw error }
            return false
        }
        return true
    }
}

private final class RecordingAudioPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var systemWriter: RecordingAudioTrackWriter?
    private var microphoneWriter: RecordingAudioTrackWriter?

    func configure(systemURL: URL, microphoneURL: URL) throws {
        let system = try RecordingAudioTrackWriter(
            url: systemURL,
            channels: 2,
            bitRate: 128_000
        )
        let microphone = try RecordingAudioTrackWriter(
            url: microphoneURL,
            channels: 1,
            bitRate: 96_000
        )
        lock.lock()
        systemWriter = system
        microphoneWriter = microphone
        lock.unlock()
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let writer = systemWriter
        lock.unlock()
        writer?.append(sampleBuffer)
    }

    func appendMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let writer = microphoneWriter
        lock.unlock()
        writer?.append(sampleBuffer)
    }

    func finish() async throws {
        let (system, microphone) = takeWriters()

        async let systemFinish: Void = finish(system)
        async let microphoneFinish: Void = finish(microphone)
        _ = try await (systemFinish, microphoneFinish)
    }

    private func takeWriters() -> (RecordingAudioTrackWriter?, RecordingAudioTrackWriter?) {
        lock.lock()
        let system = systemWriter
        let microphone = microphoneWriter
        systemWriter = nil
        microphoneWriter = nil
        lock.unlock()
        return (system, microphone)
    }

    private func finish(_ writer: RecordingAudioTrackWriter?) async throws {
        if let writer {
            try await writer.finish()
        }
    }
}

@MainActor
final class MeetingRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var status = "Ready"
    @Published private(set) var detectedSignOffText: String?
    @Published private(set) var finalizationError: Error?

    private var stream: SCStream?
    private nonisolated let audioPipeline = RecordingAudioPipeline()
    private nonisolated let systemSignOffDetector = LiveSignOffDetector()
    private nonisolated let microphoneSignOffDetector = LiveSignOffDetector()
    private var systemSignOffPhrase: String?
    private var microphoneSignOffPhrase: String?

    private let screenQueue = DispatchQueue(label: "com.agilemindset.notetaker.screen")
    private let systemAudioQueue = DispatchQueue(label: "com.agilemindset.notetaker.system-audio")
    private let microphoneQueue = DispatchQueue(label: "com.agilemindset.notetaker.microphone")

    private(set) var sessionDirectory: URL?
    private(set) var microphoneURL: URL?
    private(set) var systemAudioURL: URL?

    static var meetingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteTaker/Meetings", isDirectory: true)
    }

    static func savedSessions() -> [SavedMeetingSession] {
        SavedMeetingSession.discover(in: meetingsDirectory)
    }

    func selectSavedSession(_ session: SavedMeetingSession) {
        guard !isRecording else { return }
        sessionDirectory = session.directoryURL
        let microphone = session.directoryURL.appendingPathComponent("microphone.m4a")
        let system = session.directoryURL.appendingPathComponent("system-audio.m4a")
        microphoneURL = session.hasMicrophoneAudio ? microphone : nil
        systemAudioURL = session.hasSystemAudio ? system : nil
        finalizationError = nil
        status = "Selected saved meeting: \(session.title)"
    }

    func start(folderTitle: String? = nil, detectSignOffPhrases: Bool = true) async throws {
        guard !isRecording else { return }
        status = "Requesting permissions..."
        finalizationError = nil

        let root = Self.meetingsDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let folderName = RecordingFolderNamer.folderName(for: folderTitle, at: Date())
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sessionDirectory = folder

        try configureWriters(in: folder)

        do {
        try await startCapture()
        if detectSignOffPhrases {
            startSignOffDetection()
        }
        } catch {
            try? await audioPipeline.finish()
            throw error
        }

        isRecording = true
        status = "Recording microphone + system audio"
    }

    func stop() async {
        stopSignOffDetection()
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil

        do {
            try await audioPipeline.finish()
        } catch {
            finalizationError = error
            status = error.localizedDescription
        }

        isRecording = false
        if finalizationError == nil {
            status = "Recording saved locally"
        }
    }

    func setSignOffDetectionEnabled(_ enabled: Bool) {
        guard isRecording else { return }
        if enabled {
            startSignOffDetection()
        } else {
            stopSignOffDetection()
        }
    }

    private func configureWriters(in folder: URL) throws {
        let systemURL = folder.appendingPathComponent("system-audio.m4a")
        let microphoneURL = folder.appendingPathComponent("microphone.m4a")
        self.systemAudioURL = systemURL
        self.microphoneURL = microphoneURL

        try audioPipeline.configure(
            systemURL: systemURL,
            microphoneURL: microphoneURL
        )
    }

    private func startCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(
                domain: "NoteTaker",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "No display is available for ScreenCaptureKit capture."]
            )
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 2

        // NoteTaker does not use video, but ScreenCaptureKit still produces screen frames.
        // Registering a tiny screen output prevents repeated "stream output NOT found" errors.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)

        try await stream.startCapture()
        self.stream = stream
    }

    private func startSignOffDetection() {
        detectedSignOffText = nil
        systemSignOffPhrase = nil
        microphoneSignOffPhrase = nil

        systemSignOffDetector.start { [weak self] transcript in
            self?.updateSignOffPhrase(transcript, fromSystemAudio: true)
        }
        microphoneSignOffDetector.start { [weak self] transcript in
            self?.updateSignOffPhrase(transcript, fromSystemAudio: false)
        }
    }

    private func updateSignOffPhrase(_ transcript: String, fromSystemAudio: Bool) {
        let phrase = SignOffPhraseDetector.matchingPhrase(in: transcript)
        if fromSystemAudio {
            systemSignOffPhrase = phrase
        } else {
            microphoneSignOffPhrase = phrase
        }
        detectedSignOffText = systemSignOffPhrase ?? microphoneSignOffPhrase
    }

    private func stopSignOffDetection() {
        systemSignOffDetector.stop()
        microphoneSignOffDetector.stop()
        systemSignOffPhrase = nil
        microphoneSignOffPhrase = nil
        detectedSignOffText = nil
    }
}

extension MeetingRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .audio:
            audioPipeline.appendSystemAudio(sampleBuffer)
            systemSignOffDetector.append(sampleBuffer)
        case .microphone:
            audioPipeline.appendMicrophoneAudio(sampleBuffer)
            microphoneSignOffDetector.append(sampleBuffer)
        case .screen:
            break
        @unknown default:
            break
        }
    }
}

extension MeetingRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.status = "Capture stopped: \(error.localizedDescription)"
            self.isRecording = false
        }
    }
}
