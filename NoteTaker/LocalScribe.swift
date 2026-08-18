import Foundation
import Speech

struct ScribeEntry: Identifiable, Codable, Hashable {
    enum Source: String, Codable {
        case microphone = "Mic"
        case systemAudio = "System"
        case chat = "Chat"
        case note = "Note"
    }

    let id: UUID
    let timestamp: Date
    let source: Source
    let text: String

    init(timestamp: Date = Date(), source: Source, text: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.source = source
        self.text = text
    }
}

enum LocalScribeError: LocalizedError {
    case speechPermissionDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "Speech Recognition permission is required to transcribe meetings locally."
        case .recognizerUnavailable:
            return "Apple Speech Recognition is not available for the selected language."
        case .onDeviceRecognitionUnavailable:
            return "On-device speech recognition is not available for this language on this Mac."
        }
    }
}

final class LocalScribe {
    private let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func requestAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else { throw LocalScribeError.speechPermissionDenied }
    }

    func transcribeFile(_ url: URL, source: ScribeEntry.Source, meetingStart: Date) async throws -> [ScribeEntry] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw LocalScribeError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw LocalScribeError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let result = try await recognize(recognizer: recognizer, request: request)
        return result.bestTranscription.segments.compactMap { segment in
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ScribeEntry(
                timestamp: meetingStart.addingTimeInterval(segment.timestamp),
                source: source,
                text: text
            )
        }
    }

    private func recognize(recognizer: SFSpeechRecognizer, request: SFSpeechRecognitionRequest) async throws -> SFSpeechRecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    task?.cancel()
                    continuation.resume(throwing: error)
                    return
                }
                if let result, result.isFinal {
                    task?.cancel()
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func buildReport(
        title: String,
        startedAt: Date,
        endedAt: Date,
        attendees: [String],
        entries: [ScribeEntry]
    ) -> String {
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        let decisionEntries = sorted.filter { containsAny($0.text, needles: ["we decided", "decision", "agreed", "we will", "approved"]) }
        let actionEntries = sorted.filter { containsAny($0.text, needles: ["action item", "follow up", "follow-up", "i'll", "i will", "you will", "can you", "please", "by friday", "by monday", "due "]) }
        let riskEntries = sorted.filter { containsAny($0.text, needles: ["risk", "blocker", "blocked", "concern", "issue", "open question", "unclear", "depends on"]) }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        lines.append("# \(title.isEmpty ? "Meeting" : title)")
        lines.append("")
        lines.append("## Executive takeaway")
        if let firstDecision = decisionEntries.first {
            lines.append(firstDecision.text)
        } else if let firstAction = actionEntries.first {
            lines.append("The meeting produced a concrete follow-up: \(firstAction.text)")
        } else {
            lines.append("The complete meeting scribe is preserved below. No explicit decision or commitment was detected automatically.")
        }

        lines.append("")
        lines.append("## Decisions")
        append(entries: decisionEntries, to: &lines)

        lines.append("")
        lines.append("## Action items")
        append(entries: actionEntries, to: &lines)

        lines.append("")
        lines.append("## Open questions and risks")
        append(entries: riskEntries, to: &lines)

        lines.append("")
        lines.append("## Meeting details")
        lines.append("- Date: \(formatter.string(from: startedAt))")
        lines.append("- End: \(formatter.string(from: endedAt))")
        lines.append("- Attendees: \(attendees.isEmpty ? "Not provided" : attendees.joined(separator: ", "))")

        lines.append("")
        lines.append("## Full scribe")
        for entry in sorted {
            lines.append("- [\(time(entry.timestamp))] **\(entry.source.rawValue):** \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }

    private func append(entries: [ScribeEntry], to lines: inout [String]) {
        if entries.isEmpty {
            lines.append("- None explicitly detected.")
        } else {
            for entry in entries {
                lines.append("- [\(time(entry.timestamp))] \(entry.text)")
            }
        }
    }

    private func containsAny(_ text: String, needles: [String]) -> Bool {
        let lower = text.lowercased()
        return needles.contains { lower.contains($0) }
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
