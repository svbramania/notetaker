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

    func buildTranscript(
        title: String,
        startedAt: Date,
        endedAt: Date,
        attendees: [String],
        entries: [ScribeEntry]
    ) -> String {
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        lines.append("# \(title.isEmpty ? "Meeting transcript" : title)")
        lines.append("")
        lines.append("## Meeting details")
        lines.append("- Date: \(formatter.string(from: startedAt))")
        lines.append("- End: \(formatter.string(from: endedAt))")
        lines.append("- Attendees: \(attendees.isEmpty ? "Not provided" : attendees.joined(separator: ", "))")

        lines.append("")
        lines.append("## Complete transcript")
        if sorted.isEmpty {
            lines.append("No spoken or typed meeting content was transcribed.")
        } else {
            for entry in sorted {
                lines.append("- [\(time(entry.timestamp))] **\(entry.source.rawValue):** \(entry.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func chatGPTPrompt(for transcript: String) -> String {
        """
        Summarize the meeting transcript below. Use only information supported by the transcript.

        Follow this structure and lead with the most important conclusion:
        1. Executive summary
        2. Decisions made
        3. Action items in a table with owner and due date; write "Not stated" when either is absent
        4. Key discussion points
        5. Open questions, risks, and dependencies
        6. Attendees and meeting details

        Keep names, numbers, dates, commitments, and qualifications accurate. Clearly label anything unclear in the transcript. Do not invent missing information.

        --- TRANSCRIPT START ---
        \(transcript)
        --- TRANSCRIPT END ---
        """
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
