import AVFoundation
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
    case noSpeechDetected
    case recognitionTimedOut
    case audioPreparationTimedOut

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "Speech Recognition permission is required to transcribe meetings locally."
        case .recognizerUnavailable:
            return "Apple Speech Recognition is not available for the selected language."
        case .onDeviceRecognitionUnavailable:
            return "On-device speech recognition is not available for this language on this Mac."
        case .noSpeechDetected:
            return "The recordings were saved, but Apple Speech did not find transcribable speech in either audio track."
        case .recognitionTimedOut:
            return "Apple Speech stopped responding to an audio chunk. The recording was preserved; retry transcription to continue."
        case .audioPreparationTimedOut:
            return "Preparing an audio chunk took too long. The recording was preserved; retry transcription to continue."
        }
    }
}

struct TranscriptionProgress: Equatable {
    let completedChunks: Int
    let totalChunks: Int
    let failedChunks: Int
}

private final class SpeechRecognitionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    init(_ continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) {
        self.continuation = continuation
    }

    func attach(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
            return
        }
        recognitionTask = task
        lock.unlock()
    }

    func startTimeout(after seconds: TimeInterval) {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            self?.finish(.failure(LocalScribeError.recognitionTimedOut))
        }
        lock.lock()
        if completed {
            lock.unlock()
            timeoutTask.cancel()
            return
        }
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func finish(_ result: Result<SFSpeechRecognitionResult, Error>) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        let recognitionTask = self.recognitionTask
        self.recognitionTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        recognitionTask?.cancel()
        continuation.resume(with: result)
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}

private final class SpeechRecognitionOperationHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: SpeechRecognitionOperation?
    private var cancelled = false

    func set(_ operation: SpeechRecognitionOperation) {
        lock.lock()
        if cancelled {
            lock.unlock()
            operation.cancel()
            return
        }
        self.operation = operation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let operation = self.operation
        lock.unlock()
        operation?.cancel()
    }
}

private final class AudioExportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let exporter: AVAssetExportSession
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    init(
        exporter: AVAssetExportSession,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.exporter = exporter
        self.continuation = continuation
    }

    func start(timeout: TimeInterval) {
        exporter.exportAsynchronously { [weak self] in
            guard let self else { return }
            switch self.exporter.status {
            case .completed:
                self.finish(nil)
            case .failed, .cancelled:
                self.finish(
                    self.exporter.error ?? NSError(
                        domain: "NoteTaker",
                        code: 31,
                        userInfo: [NSLocalizedDescriptionKey: "Could not create an audio transcription chunk."]
                    )
                )
            default:
                self.finish(
                    NSError(
                        domain: "NoteTaker",
                        code: 32,
                        userInfo: [NSLocalizedDescriptionKey: "Audio transcription preparation did not finish."]
                    )
                )
            }
        }
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            self?.exporter.cancelExport()
            self?.finish(LocalScribeError.audioPreparationTimedOut)
        }
        lock.lock()
        if completed {
            lock.unlock()
            timeoutTask.cancel()
        } else {
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    func cancel() {
        exporter.cancelExport()
        finish(CancellationError())
    }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

private final class AudioExportOperationHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: AudioExportOperation?
    private var cancelled = false

    func set(_ operation: AudioExportOperation) {
        lock.lock()
        if cancelled {
            lock.unlock()
            operation.cancel()
            return
        }
        self.operation = operation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let operation = self.operation
        lock.unlock()
        operation?.cancel()
    }
}

final class LocalScribe {
    private struct AudioChunk {
        let url: URL
        let offset: TimeInterval
    }

    private struct PreparedAudioChunks {
        let chunks: [AudioChunk]
        let temporaryDirectory: URL?
    }

    private let maximumRecognitionDuration: TimeInterval = 50
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

    func transcribeFile(
        _ url: URL,
        source: ScribeEntry.Source,
        meetingStart: Date,
        progress: ((TranscriptionProgress) -> Void)? = nil
    ) async throws -> [ScribeEntry] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw LocalScribeError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw LocalScribeError.onDeviceRecognitionUnavailable
        }

        let prepared = try await prepareAudioChunks(for: url)
        defer {
            if let temporaryDirectory = prepared.temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }

        var entries: [ScribeEntry] = []
        var firstRecognitionError: Error?

        var failedChunks = 0
        for (index, chunk) in prepared.chunks.enumerated() {
            try Task.checkCancellation()
            var finalChunkError: Error?

            for attempt in 1...2 {
                do {
                    let chunkEntries = try await transcribeSingleFile(
                        chunk.url,
                        recognizer: recognizer,
                        source: source,
                        meetingStart: meetingStart.addingTimeInterval(chunk.offset)
                    )
                    entries.append(contentsOf: chunkEntries)
                    finalChunkError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if isNoSpeechError(error) {
                        finalChunkError = nil
                        break
                    }
                    finalChunkError = error
                    if attempt < 2 {
                        continue
                    }
                }
            }

            if let finalChunkError {
                failedChunks += 1
                firstRecognitionError = firstRecognitionError ?? finalChunkError
            }
            progress?(
                TranscriptionProgress(
                    completedChunks: index + 1,
                    totalChunks: prepared.chunks.count,
                    failedChunks: failedChunks
                )
            )
        }

        if entries.isEmpty, let firstRecognitionError {
            throw firstRecognitionError
        }

        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    private func transcribeSingleFile(
        _ url: URL,
        recognizer: SFSpeechRecognizer,
        source: ScribeEntry.Source,
        meetingStart: Date
    ) async throws -> [ScribeEntry] {

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = [
            "dollars", "cents", "euros", "pounds", "rupees",
            "price", "pricing", "cost", "fee", "budget", "rate",
            "payment", "deposit", "invoice", "revenue", "expense",
            "per session", "per hour", "per month", "per year"
        ]

        let result = try await recognize(recognizer: recognizer, request: request)
        return groupIntoUtterances(
            result.bestTranscription.segments,
            source: source,
            meetingStart: meetingStart
        )
    }

    func transcribeFileAllowingSilence(
        _ url: URL,
        source: ScribeEntry.Source,
        meetingStart: Date,
        progress: ((TranscriptionProgress) -> Void)? = nil
    ) async throws -> [ScribeEntry] {
        do {
            return try await transcribeFile(
                url,
                source: source,
                meetingStart: meetingStart,
                progress: progress
            )
        } catch {
            if isNoSpeechError(error) {
                return []
            }
            throw error
        }
    }

    func mergeSpokenEntries(
        microphone: [ScribeEntry],
        systemAudio: [ScribeEntry]
    ) -> [ScribeEntry] {
        var merged = systemAudio

        for microphoneEntry in microphone {
            let isDuplicate = systemAudio.contains { systemEntry in
                abs(systemEntry.timestamp.timeIntervalSince(microphoneEntry.timestamp)) <= 2.5
                    && transcriptSimilarity(systemEntry.text, microphoneEntry.text) >= 0.65
            }

            if !isDuplicate {
                merged.append(microphoneEntry)
            }
        }

        return merged.sorted { $0.timestamp < $1.timestamp }
    }

    private func isNoSpeechError(_ error: Error) -> Bool {
        let recognitionError = error as NSError
        let isAppleNoSpeechError = recognitionError.domain == "kAFAssistantErrorDomain"
            && recognitionError.code == 1110
        let descriptionSaysNoSpeech = recognitionError.localizedDescription
            .localizedCaseInsensitiveContains("no speech")
        return isAppleNoSpeechError || descriptionSaysNoSpeech
    }

    private func prepareAudioChunks(for url: URL) async throws -> PreparedAudioChunks {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        guard duration.isFinite, duration > maximumRecognitionDuration else {
            return PreparedAudioChunks(
                chunks: [AudioChunk(url: url, offset: 0)],
                temporaryDirectory: nil
            )
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteTaker-Speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            var chunks: [AudioChunk] = []
            var offset: TimeInterval = 0
            var index = 0

            while offset < duration {
                try Task.checkCancellation()
                let chunkDuration = min(maximumRecognitionDuration, duration - offset)
                let chunkURL = directory.appendingPathComponent(
                    String(format: "chunk-%04d.m4a", index)
                )
                try await exportAudioChunk(
                    asset: asset,
                    start: offset,
                    duration: chunkDuration,
                    destination: chunkURL
                )
                try Task.checkCancellation()
                chunks.append(AudioChunk(url: chunkURL, offset: offset))
                offset += chunkDuration
                index += 1
            }

            return PreparedAudioChunks(chunks: chunks, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func exportAudioChunk(
        asset: AVURLAsset,
        start: TimeInterval,
        duration: TimeInterval,
        destination: URL
    ) async throws {
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(
                domain: "NoteTaker",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Could not prepare the recording for transcription."]
            )
        }

        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        let holder = AudioExportOperationHolder()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let operation = AudioExportOperation(
                    exporter: exporter,
                    continuation: continuation
                )
                holder.set(operation)
                operation.start(timeout: 60)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private func transcriptSimilarity(_ left: String, _ right: String) -> Double {
        let leftTokens = normalizedTokens(left)
        let rightTokens = normalizedTokens(right)
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }

        let overlap = leftTokens.intersection(rightTokens).count
        return Double(overlap) / Double(min(leftTokens.count, rightTokens.count))
    }

    private func normalizedTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    private func recognize(recognizer: SFSpeechRecognizer, request: SFSpeechRecognitionRequest) async throws -> SFSpeechRecognitionResult {
        let holder = SpeechRecognitionOperationHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let operation = SpeechRecognitionOperation(continuation)
                holder.set(operation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        operation.finish(.failure(error))
                        return
                    }
                    if let result, result.isFinal {
                        operation.finish(.success(result))
                    }
                }
                operation.attach(task)
                operation.startTimeout(after: 90)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private func groupIntoUtterances(
        _ segments: [SFTranscriptionSegment],
        source: ScribeEntry.Source,
        meetingStart: Date
    ) -> [ScribeEntry] {
        let pauseThreshold: TimeInterval = 1.0
        let maximumWordsPerUtterance = 35
        var entries: [ScribeEntry] = []
        var words: [String] = []
        var utteranceStart: TimeInterval = 0
        var previousSegmentEnd: TimeInterval?

        func flushUtterance() {
            guard !words.isEmpty else { return }
            entries.append(
                ScribeEntry(
                    timestamp: meetingStart.addingTimeInterval(utteranceStart),
                    source: source,
                    text: joinTranscriptionTokens(words)
                )
            )
            words.removeAll(keepingCapacity: true)
        }

        for segment in segments {
            let word = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }

            if let previousSegmentEnd,
               segment.timestamp - previousSegmentEnd >= pauseThreshold {
                flushUtterance()
            }

            if words.isEmpty {
                utteranceStart = segment.timestamp
            }

            words.append(word)
            previousSegmentEnd = segment.timestamp + segment.duration

            if endsSentence(word) || words.count >= maximumWordsPerUtterance {
                flushUtterance()
            }
        }

        flushUtterance()
        return entries
    }

    private func joinTranscriptionTokens(_ tokens: [String]) -> String {
        let punctuationWithoutLeadingSpace = CharacterSet(charactersIn: ",.!?;:%)]}")
        var result = ""

        for token in tokens {
            let attachesToPrevious = token.unicodeScalars.first
                .map { punctuationWithoutLeadingSpace.contains($0) } ?? false
            if result.isEmpty || attachesToPrevious {
                result += token
            } else {
                result += " \(token)"
            }
        }
        return result
    }

    private func endsSentence(_ text: String) -> Bool {
        guard let lastCharacter = text.last else { return false }
        return ".!?".contains(lastCharacter)
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
        let financialEvidence = FinancialMentionExtractor.evidenceLines(in: transcript)
        let financialEvidenceText = financialEvidence.isEmpty
            ? "No monetary references were detected automatically; still review the complete transcript for financial information."
            : financialEvidence.map { "- \($0)" }.joined(separator: "\n")
        let numericEvidence = NumericMentionExtractor.evidenceLines(in: transcript)
        let numericEvidenceText = numericEvidence.isEmpty
            ? "No numeric references were detected automatically; still review the complete transcript for material numbers."
            : numericEvidence.map { "- \($0)" }.joined(separator: "\n")

        return """
        Summarize the meeting transcript below. Use only information supported by the transcript.

        Produce clean, email-ready plain text. Remove any hashtags and fix the formatting. Do not use Markdown hash marks or Markdown tables. Start with KEY NUMBERS and include every material number, amount, date, percentage, quantity, and duration. Then use this structure:
        1. EXECUTIVE SUMMARY — apply the Pyramid Principle by leading with the most important conclusion or outcome, followed by the strongest supporting facts
        2. DECISIONS MADE
        3. ACTION ITEMS — format each action as a numbered line with owner, due date, and status; write "Not stated" when an owner or date is absent
        4. FINANCIAL TERMS AND AMOUNTS — capture every mention of money, pricing, fees, budgets, rates, discounts, payments, costs, revenue, and financial commitments, preserving the exact amount, currency, quantity, unit, timing, conditions, and context
        5. KEY DISCUSSION POINTS
        6. OPEN QUESTIONS, RISKS, AND DEPENDENCIES
        7. ATTENDEES AND MEETING DETAILS

        Keep names, numbers, dates, commitments, and qualifications accurate. Clearly label anything unclear in the transcript. Do not invent missing information.

        REQUIRED FINANCIAL EVIDENCE
        Include every applicable line below in the financial section:
        \(financialEvidenceText)

        REQUIRED NUMERIC EVIDENCE
        Place every applicable line below at the start under KEY NUMBERS and use it in the executive summary where material:
        \(numericEvidenceText)

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
