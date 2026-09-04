import AppKit
import SwiftUI

struct CloudMeetingNotesView: View {
    let transcript: String
    let meetingTitle: String
    let sessionDirectory: URL?
    let suggestedRecipients: [MeetingEmailRecipient]

    @AppStorage("meetingNotesProvider") private var providerRawValue = MeetingNotesProvider.openAI.rawValue
    @AppStorage("openAIMeetingNotesModel") private var openAIModel = MeetingNotesProvider.openAI.defaultModel
    @AppStorage("claudeMeetingNotesModel") private var claudeModel = MeetingNotesProvider.claude.defaultModel
    @State private var apiKeyEntry = ""
    @State private var hasSavedAPIKey = false
    @State private var generatedNotes = ""
    @State private var recipients: [MeetingEmailRecipient] = []
    @State private var selectedRecipientIDs: Set<String> = []
    @State private var isGenerating = false
    @State private var status = "Choose a provider and save its API key in macOS Keychain."

    private let notesService = MeetingNotesService()

    private var provider: MeetingNotesProvider {
        MeetingNotesProvider(rawValue: providerRawValue) ?? .openAI
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { provider == .openAI ? openAIModel : claudeModel },
            set: {
                if provider == .openAI {
                    openAIModel = $0
                } else {
                    claudeModel = $0
                }
            }
        )
    }

    private var everyoneBinding: Binding<Bool> {
        Binding(
            get: {
                !recipients.isEmpty
                    && selectedRecipientIDs == Set(recipients.map(\.id))
            },
            set: { selectEveryone in
                selectedRecipientIDs = selectEveryone ? Set(recipients.map(\.id)) : []
            }
        )
    }

    private var selectedEmails: [String] {
        recipients
            .filter { selectedRecipientIDs.contains($0.id) }
            .map(\.email)
    }

    var body: some View {
        GroupBox("AI meeting notes and email") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 10) {
                    Picker("Provider", selection: $providerRawValue) {
                        ForEach(MeetingNotesProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider.rawValue)
                        }
                    }
                    .frame(width: 180)

                    TextField("Model", text: modelBinding)
                        .textFieldStyle(.roundedBorder)

                    SecureField(provider.keyPlaceholder, text: $apiKeyEntry)
                        .textFieldStyle(.roundedBorder)

                    Button("Save API Key") { saveAPIKey() }
                        .disabled(apiKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if hasSavedAPIKey {
                        Button("Remove Key") { removeAPIKey() }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: hasSavedAPIKey ? "key.fill" : "key")
                        .foregroundStyle(hasSavedAPIKey ? Color.green : Color.secondary)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Generate Meeting Notes") {
                        Task { await generateNotes() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(transcript.isEmpty || !hasSavedAPIKey || isGenerating)
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    }
                }

                Text("Generating notes sends the transcript to the selected provider. The API key stays in macOS Keychain, and the completed notes are saved locally with the recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !generatedNotes.isEmpty {
                    TextEditor(text: $generatedNotes)
                        .font(.body.monospaced())
                        .frame(minHeight: 260)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25))
                        )

                    Divider()

                    Text("Email recipients")
                        .font(.headline)

                    if recipients.isEmpty {
                        Text("Add attendee email addresses to the meeting or calendar invitation to prepare an addressed email.")
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Everyone", isOn: everyoneBinding)
                            .font(.headline)

                        ForEach(recipients) { recipient in
                            Toggle(
                                isOn: Binding(
                                    get: { selectedRecipientIDs.contains(recipient.id) },
                                    set: { selected in
                                        if selected {
                                            selectedRecipientIDs.insert(recipient.id)
                                        } else {
                                            selectedRecipientIDs.remove(recipient.id)
                                        }
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recipient.name)
                                    if recipient.name.localizedCaseInsensitiveCompare(recipient.email) != .orderedSame {
                                        Text(recipient.email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    HStack {
                        Button("Save Edited Notes") { saveGeneratedNotes() }
                        Spacer()
                        Text("\(selectedEmails.count) recipients selected")
                            .foregroundStyle(.secondary)
                        Button("Prepare Email") { prepareEmail() }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedEmails.isEmpty)
                    }
                }
            }
            .padding(6)
        }
        .task { refreshSavedKeyStatus() }
        .onChange(of: providerRawValue) { _, _ in
            apiKeyEntry = ""
            refreshSavedKeyStatus()
        }
        .onChange(of: suggestedRecipients, initial: true) { _, updatedRecipients in
            recipients = EmailAddressExtractor.merged(updatedRecipients)
            selectedRecipientIDs = Set(recipients.map(\.id))
        }
    }

    private func saveAPIKey() {
        do {
            try APIKeyStore.save(apiKeyEntry, for: provider)
            apiKeyEntry = ""
            hasSavedAPIKey = true
            status = "\(provider.rawValue) API key saved securely in macOS Keychain."
        } catch {
            status = error.localizedDescription
        }
    }

    private func removeAPIKey() {
        do {
            try APIKeyStore.delete(for: provider)
            apiKeyEntry = ""
            hasSavedAPIKey = false
            status = "\(provider.rawValue) API key removed from macOS Keychain."
        } catch {
            status = error.localizedDescription
        }
    }

    private func refreshSavedKeyStatus() {
        do {
            hasSavedAPIKey = try APIKeyStore.load(for: provider) != nil
            status = hasSavedAPIKey
                ? "\(provider.rawValue) API key is ready in macOS Keychain."
                : "Enter and save a \(provider.rawValue) API key."
        } catch {
            hasSavedAPIKey = false
            status = error.localizedDescription
        }
    }

    private func generateNotes() async {
        isGenerating = true
        status = "Generating structured notes with \(provider.rawValue)..."
        defer { isGenerating = false }

        do {
            guard let key = try APIKeyStore.load(for: provider) else {
                throw MeetingNotesServiceError.missingAPIKey
            }
            let model = modelBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            generatedNotes = try await notesService.generate(
                transcript: transcript,
                provider: provider,
                model: model.isEmpty ? provider.defaultModel : model,
                apiKey: key
            )
            try writeGeneratedNotes()
            status = "Meeting notes generated and saved locally."
        } catch {
            status = error.localizedDescription
        }
    }

    private func saveGeneratedNotes() {
        do {
            try writeGeneratedNotes()
            status = "Edited meeting notes saved locally."
        } catch {
            status = error.localizedDescription
        }
    }

    private func writeGeneratedNotes() throws {
        guard let sessionDirectory else { return }
        try generatedNotes.write(
            to: sessionDirectory.appendingPathComponent("meeting-notes.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func prepareEmail() {
        guard let service = NSSharingService(named: .composeEmail) else {
            status = "Set up an email application on this Mac to prepare the message."
            return
        }
        service.recipients = selectedEmails
        service.subject = meetingTitle.isEmpty
            ? "Meeting notes"
            : "Meeting notes: \(meetingTitle)"
        service.perform(withItems: [generatedNotes])
        status = "Email draft prepared for review and sending."
    }
}
