import AppKit
import SwiftUI

@main
struct NoteTakerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 820, minHeight: 720)
        }
        .windowStyle(.titleBar)
    }
}

struct ContentView: View {
    @StateObject private var recorder = MeetingRecorder()
    @State private var title = ""
    @State private var attendees = ""
    @State private var typedEntry = ""
    @State private var typedSource: ScribeEntry.Source = .chat
    @State private var entries: [ScribeEntry] = []
    @State private var report = ""
    @State private var startedAt: Date?
    @State private var endedAt: Date?
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private let scribe = LocalScribe()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NoteTaker Scribe")
                .font(.largeTitle.bold())
            Text("Local meeting capture, typed chat, and Pyramid-style meeting record — no API key required")
                .foregroundStyle(.secondary)

            GroupBox("Meeting") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Meeting title", text: $title)
                    TextField("Attendees (comma-separated, if known)", text: $attendees)
                }
                .textFieldStyle(.roundedBorder)
                .padding(6)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await toggleRecording() }
                } label: {
                    Label(recorder.isRecording ? "Stop Meeting" : "Record Meeting", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)

                Button("Build Scribe") {
                    Task { await buildScribe() }
                }
                .disabled(recorder.isRecording || isProcessing || recorder.sessionDirectory == nil)

                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                Text(recorder.status).foregroundStyle(.secondary)
            }

            GroupBox("Meeting chat / typed notes") {
                VStack(spacing: 8) {
                    HStack {
                        Picker("Source", selection: $typedSource) {
                            Text("Chat").tag(ScribeEntry.Source.chat)
                            Text("My note").tag(ScribeEntry.Source.note)
                        }
                        .frame(width: 180)

                        TextField("Paste or type something relevant to the meeting", text: $typedEntry)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addTypedEntry)

                        Button("Add") { addTypedEntry() }
                            .disabled(typedEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if !entries.filter({ $0.source == .chat || $0.source == .note }).isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(entries.filter { $0.source == .chat || $0.source == .note }) { entry in
                                    Text("[\(time(entry.timestamp))] \(entry.source.rawValue): \(entry.text)")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                .padding(6)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            GroupBox("Meeting scribe") {
                ScrollView {
                    Text(report.isEmpty ? "After the meeting, choose Build Scribe. Spoken audio and typed meeting content will be combined into a local, timestamped meeting record." : report)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(minHeight: 300)
            }

            HStack {
                if let folder = recorder.sessionDirectory {
                    Button("Show Meeting Folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                Spacer()
                Text("Audio and transcription remain on this Mac. Recording consent laws still apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func toggleRecording() async {
        errorMessage = nil
        do {
            if recorder.isRecording {
                await recorder.stop()
                endedAt = Date()
            } else {
                report = ""
                entries = []
                startedAt = Date()
                endedAt = nil
                try await recorder.start()
            }
        } catch {
            errorMessage = error.localizedDescription
            await recorder.stop()
        }
    }

    private func addTypedEntry() {
        let text = typedEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entries.append(ScribeEntry(source: typedSource, text: text))
        typedEntry = ""
    }

    private func buildScribe() async {
        guard let mic = recorder.microphoneURL,
              let system = recorder.systemAudioURL,
              let start = startedAt else { return }

        errorMessage = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            try await scribe.requestAuthorization()
            async let micEntries = scribe.transcribeFile(mic, source: .microphone, meetingStart: start)
            async let systemEntries = scribe.transcribeFile(system, source: .systemAudio, meetingStart: start)
            let spoken = try await micEntries + systemEntries
            let allEntries = (entries + spoken).sorted { $0.timestamp < $1.timestamp }
            entries = allEntries

            let names = attendees.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let built = scribe.buildReport(
                title: title,
                startedAt: start,
                endedAt: endedAt ?? Date(),
                attendees: names,
                entries: allEntries
            )
            report = built
            try save(report: built, entries: allEntries)
            recorder.status = "Local scribe saved"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(report: String, entries: [ScribeEntry]) throws {
        guard let folder = recorder.sessionDirectory else { return }
        try report.write(to: folder.appendingPathComponent("meeting-scribe.md"), atomically: true, encoding: .utf8)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: folder.appendingPathComponent("scribe.json"), options: .atomic)
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
