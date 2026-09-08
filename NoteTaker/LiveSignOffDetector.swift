import CoreMedia
import Foundation
import Speech

enum SignOffPhraseDetector {
    private static let phrases = [
        "thank you everyone",
        "thanks everyone",
        "bye everyone",
        "goodbye everyone",
        "have a good day",
        "have a great day",
        "talk to you later",
        "speak to you later",
        "see you later",
        "we can end here",
        "lets end here",
        "that wraps up",
        "we are done",
        "goodbye",
        "bye bye",
        "bye"
    ]

    static func matchingPhrase(in transcript: String) -> String? {
        let normalized = transcript
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return phrases.first { phrase in
            normalized == phrase || normalized.hasSuffix(" \(phrase)")
        }
    }
}

@MainActor
final class LiveSignOffDetector {
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRunning = false
    private var recognitionGeneration = 0
    private var onTranscriptUpdate: ((String) -> Void)?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start(onTranscriptUpdate: @escaping (String) -> Void) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return }

        self.onTranscriptUpdate = onTranscriptUpdate
        isRunning = true
        beginRecognition()
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else { return }
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    func stop() {
        isRunning = false
        recognitionGeneration += 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onTranscriptUpdate = nil
    }

    private func beginRecognition() {
        guard isRunning, let recognizer else { return }

        recognitionGeneration += 1
        let generation = recognitionGeneration
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = [
            "bye", "goodbye", "bye everyone", "thanks everyone",
            "thank you everyone", "have a good day", "have a great day",
            "talk to you later", "see you later", "that wraps up"
        ]
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let transcript = result?.bestTranscription.formattedString {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isRunning,
                          self.recognitionGeneration == generation else { return }
                    self.onTranscriptUpdate?(transcript)
                }
            }

            if error != nil || result?.isFinal == true {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isRunning,
                          self.recognitionGeneration == generation else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    guard self.isRunning,
                          self.recognitionGeneration == generation else { return }
                    self.beginRecognition()
                }
            }
        }
    }
}
