import Foundation
import SoundAnalysis

/// Uses Apple's on-device sound classifier to avoid starting Speech recognition
/// for recordings that contain no human voice.
final class RecordedVoiceDetector {
    private static let minimumVoiceConfidence = 0.25

    func containsVoice(in urls: [URL]) async -> Bool? {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                if try await analyze(url) {
                    return true
                }
            } catch {
                // An unavailable classifier must not cause a real recording to be
                // discarded. Nil tells the caller to fall back to Apple Speech.
                return nil
            }
        }
        return false
    }

    static func isVoiceClassification(identifier: String, confidence: Double) -> Bool {
        guard confidence >= minimumVoiceConfidence else { return false }
        let normalized = identifier.lowercased()
        return normalized.contains("speech")
            || normalized.contains("conversation")
            || normalized.contains("talking")
            || normalized.contains("human_voice")
            || normalized.contains("human voice")
    }

    private func analyze(_ url: URL) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let analysis = try VoiceAnalysis(url: url) { result in
                    continuation.resume(with: result)
                }
                analysis.start()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class VoiceAnalysis: NSObject, SNResultsObserving {
    private let analyzer: SNAudioFileAnalyzer
    private let lock = NSLock()
    private var completion: ((Result<Bool, Error>) -> Void)?
    private var selfRetainer: VoiceAnalysis?

    init(url: URL, completion: @escaping (Result<Bool, Error>) -> Void) throws {
        analyzer = try SNAudioFileAnalyzer(url: url)
        self.completion = completion
        super.init()

        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        try analyzer.add(request, withObserver: self)
    }

    func start() {
        selfRetainer = self
        analyzer.analyze { [weak self] completed in
            guard let self else { return }
            if completed {
                finish(.success(false))
            } else {
                finish(.failure(VoiceAnalysisError.analysisDidNotComplete))
            }
        }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let voiceFound = result.classifications.contains {
            RecordedVoiceDetector.isVoiceClassification(
                identifier: $0.identifier,
                confidence: $0.confidence
            )
        }
        guard voiceFound else { return }

        finish(.success(true))
        analyzer.cancelAnalysis()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        finish(.failure(error))
    }

    func requestDidComplete(_ request: SNRequest) {
        finish(.success(false))
    }

    private func finish(_ result: Result<Bool, Error>) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()

        guard let callback else { return }
        callback(result)
        selfRetainer = nil
    }
}

private enum VoiceAnalysisError: LocalizedError {
    case analysisDidNotComplete

    var errorDescription: String? {
        "The local voice-presence check could not finish."
    }
}
