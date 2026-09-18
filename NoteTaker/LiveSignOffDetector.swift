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

final class LiveSignOffDetector: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?
    private let queue = DispatchQueue(label: "com.agilemindset.notetaker.signoff-speech")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRunning = false
    private var recognitionGeneration = 0
    private var onTranscriptUpdate: ((String) -> Void)?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start(onTranscriptUpdate: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self,
                  SFSpeechRecognizer.authorizationStatus() == .authorized,
                  let recognizer = self.recognizer,
                  recognizer.isAvailable,
                  recognizer.supportsOnDeviceRecognition else { return }

            self.onTranscriptUpdate = onTranscriptUpdate
            self.isRunning = true
            self.beginRecognition()
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.request?.appendAudioSampleBuffer(sampleBuffer)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.recognitionGeneration += 1
            self.request?.endAudio()
            self.task?.cancel()
            self.request = nil
            self.task = nil
            self.onTranscriptUpdate = nil
        }
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
            self?.queue.async { [weak self] in
                guard let self,
                      self.isRunning,
                      self.recognitionGeneration == generation else { return }

                if let transcript = result?.bestTranscription.formattedString,
                   let onTranscriptUpdate = self.onTranscriptUpdate {
                    Task { @MainActor in
                        onTranscriptUpdate(transcript)
                    }
                }

                if error != nil || result?.isFinal == true {
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self,
                              self.isRunning,
                              self.recognitionGeneration == generation else { return }
                        self.beginRecognition()
                    }
                }
            }
        }
    }
}
