import SwiftUI

@main
struct NoteTakerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 680)
        }
        .windowStyle(.titleBar)
    }
}

struct ContentView: View {
    @StateObject private var recorder = MeetingRecorder()
    @State private var title = ""
    @State private var attendees = ""
    @State private var manualNotes = ""
    @State private var apiKey = ""
    @State private var generatedNotes = ""
    @State private var startedAt: Date?
    @State private var endedAt: Date?
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NoteTaker")
                .font(.largeTitle.bold())
            Text("Local-first meeting capture → Pyramid-style notes")
                .foregroundStyle(.secondary)

            GroupBox("Meeting") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Meeting title", text: $title)
                    TextField("Attendees (comma-separated, if known)", text: $attendees)
                    SecureField("OpenAI API key (used only for this session)", text: $apiKey)
                }
                .textFieldStyle(.roundedBorder)
                .padding(6)
            }

            GroupBox("Your notes during the meeting") {
                TextEditor(text: $manualNotes)
                    .font(.body)
                    .frame(minHeight: 100)
                    .padding(4)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await toggleRecording() }
                } label: {
                    Label(recorder.isRecording ? "Stop Meeting" : "Record Meeting", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)

                Button("Generate Notes") {
                    Task { await generateNotes() }
                }
                .disabled(recorder.isRecording || isProcessing || recorder.sessionDirectory == nil || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                Text(recorder.status).foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            GroupBox("Generated meeting notes") {
                ScrollView {
                    Text(generatedNotes.isEmpty ? "Your Pyramid-style meeting notes will appear here." : generatedNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(minHeight: 260)
            }

            HStack {
                if let folder = recorder.sessionDirectory {
                    Button("Show Recording Folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                Spacer()
                Text("Audio stays local until you generate notes. Recording consent laws still apply.")
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
                generatedNotes = ""
                startedAt = Date()
                endedAt = nil
                try await recorder.start()
            }
        } catch {
            errorMessage = error.localizedDescription
            await recorder.stop()
        }
    }

    private func generateNotes() async {
        guard let mic = recorder.microphoneURL,
              let system = recorder.systemAudioURL,
              let start = startedAt else { return }

        errorMessage = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            let client = OpenAIClient(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            async let micText = client.transcribe(audioURL: mic, sourceLabel: "LOCAL USER / MICROPHONE")
            async let systemText = client.transcribe(audioURL: system, sourceLabel: "REMOTE PARTICIPANTS / SYSTEM AUDIO")
            let transcript = try await [micText, systemText].joined(separator: "\n\n")
            let names = attendees.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let notes = try await client.generateNotes(
                title: title,
                startedAt: start,
                endedAt: endedAt ?? Date(),
                attendees: names,
                manualNotes: manualNotes,
                transcript: transcript
            )
            generatedNotes = notes
            try save(notes: notes, transcript: transcript)
            recorder.status = "Notes generated and saved"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(notes: String, transcript: String) throws {
        guard let folder = recorder.sessionDirectory else { return }
        try notes.write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try transcript.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    }
}
