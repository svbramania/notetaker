import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class MeetingRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var status = "Ready"

    private var micRecorder: AVAudioRecorder?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var writerSessionStarted = false
    private let queue = DispatchQueue(label: "com.agilemindset.notetaker.system-audio")

    private(set) var sessionDirectory: URL?
    private(set) var microphoneURL: URL?
    private(set) var systemAudioURL: URL?

    func start() async throws {
        guard !isRecording else { return }
        status = "Requesting permissions..."

        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteTaker/Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sessionDirectory = folder

        try startMicrophone(in: folder)
        do {
            try await startSystemAudio(in: folder)
        } catch {
            micRecorder?.stop()
            micRecorder = nil
            throw error
        }

        isRecording = true
        status = "Recording microphone + system audio"
    }

    func stop() async {
        micRecorder?.stop()
        micRecorder = nil

        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil

        audioInput?.markAsFinished()
        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }
        self.writer = nil
        self.audioInput = nil
        writerSessionStarted = false

        isRecording = false
        status = "Recording saved locally"
    }

    private func startMicrophone(in folder: URL) throws {
        let url = folder.appendingPathComponent("microphone.m4a")
        microphoneURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw NSError(domain: "NoteTaker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not start microphone recording."])
        }
        micRecorder = recorder
    }

    private func startSystemAudio(in folder: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "NoteTaker", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display is available for system-audio capture."])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let url = folder.appendingPathComponent("system-audio.m4a")
        systemAudioURL = url
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "NoteTaker", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not configure system-audio writer."])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "NoteTaker", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not start system-audio writer."])
        }

        self.writer = writer
        self.audioInput = input
        writerSessionStarted = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }
}

extension MeetingRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        Task { @MainActor in
            guard let writer = self.writer, let input = self.audioInput, writer.status == .writing else { return }
            if !self.writerSessionStarted {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                self.writerSessionStarted = true
            }
            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }
}
