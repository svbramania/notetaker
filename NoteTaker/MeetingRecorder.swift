import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class MeetingRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var status = "Ready"

    private var stream: SCStream?

    private var systemWriter: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var systemSessionStarted = false

    private var microphoneWriter: AVAssetWriter?
    private var microphoneInput: AVAssetWriterInput?
    private var microphoneSessionStarted = false

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

    func start() async throws {
        guard !isRecording else { return }
        status = "Requesting permissions..."

        let root = Self.meetingsDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let folder = root.appendingPathComponent(
            ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sessionDirectory = folder

        try configureWriters(in: folder)

        do {
            try await startCapture()
        } catch {
            await stopWriters()
            throw error
        }

        isRecording = true
        status = "Recording microphone + system audio"
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil

        await stopWriters()

        isRecording = false
        status = "Recording saved locally"
    }

    private func configureWriters(in folder: URL) throws {
        let systemURL = folder.appendingPathComponent("system-audio.m4a")
        let microphoneURL = folder.appendingPathComponent("microphone.m4a")
        self.systemAudioURL = systemURL
        self.microphoneURL = microphoneURL

        let system = try makeWriter(url: systemURL, channels: 2, bitRate: 128_000)
        systemWriter = system.writer
        systemInput = system.input
        systemSessionStarted = false

        let microphone = try makeWriter(url: microphoneURL, channels: 1, bitRate: 96_000)
        microphoneWriter = microphone.writer
        microphoneInput = microphone.input
        microphoneSessionStarted = false
    }

    private func makeWriter(url: URL, channels: Int, bitRate: Int) throws -> (writer: AVAssetWriter, input: AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
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
        guard writer.startWriting() else {
            throw writer.error ?? NSError(
                domain: "NoteTaker",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Could not start an audio writer."]
            )
        }

        return (writer, input)
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

    private func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = systemWriter,
              let input = systemInput,
              writer.status == .writing else { return }

        if !systemSessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            systemSessionStarted = true
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    private func appendMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = microphoneWriter,
              let input = microphoneInput,
              writer.status == .writing else { return }

        if !microphoneSessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            microphoneSessionStarted = true
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    private func stopWriters() async {
        systemInput?.markAsFinished()
        microphoneInput?.markAsFinished()

        if let systemWriter, systemWriter.status == .writing {
            await systemWriter.finishWriting()
        }
        if let microphoneWriter, microphoneWriter.status == .writing {
            await microphoneWriter.finishWriting()
        }

        systemWriter = nil
        systemInput = nil
        systemSessionStarted = false

        microphoneWriter = nil
        microphoneInput = nil
        microphoneSessionStarted = false
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
            Task { @MainActor in
                self.appendSystemAudio(sampleBuffer)
            }
        case .microphone:
            Task { @MainActor in
                self.appendMicrophoneAudio(sampleBuffer)
            }
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
