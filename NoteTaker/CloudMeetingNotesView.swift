import AppKit
import SwiftUI

struct CloudMeetingNotesView: View {
    let transcript: String
    let meetingTitle: String
    let sessionDirectory: URL?
    let suggestedRecipients: [MeetingEmailRecipient]

    @AppStorage("autoFallbackOnAPIQuotaLimit") private var autoFallbackOnQuotaLimit = false
    @State private var configurations: [APIProviderConfiguration] = []
    @State private var newProvider: MeetingNotesProvider = .openAI
    @State private var newLabel = ""
    @State private var newModel = MeetingNotesProvider.openAI.defaultModel
    @State private var newAPIKey = ""
    @State private var generatedNotes = ""
    @State private var recipients: [MeetingEmailRecipient] = []
    @State private var selectedRecipientIDs: Set<String> = []
    @State private var isGenerating = false
    @State private var status = "Add one or more API providers in the order they should be used."

    private let notesService = MeetingNotesService()

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
                Text("API provider order")
                    .font(.headline)

                HStack(alignment: .bottom, spacing: 8) {
                    Picker("Provider", selection: $newProvider) {
                        ForEach(MeetingNotesProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .frame(width: 165)

                    TextField("Label, such as Work key", text: $newLabel)
                        .textFieldStyle(.roundedBorder)

                    TextField("Model", text: $newModel)
                        .textFieldStyle(.roundedBorder)

                    SecureField(newProvider.keyPlaceholder, text: $newAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Add API Key") { addConfiguration() }
                        .disabled(newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if configurations.isEmpty {
                    Text("No API keys configured. The no-key ChatGPT handoff remains available above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(configurations.enumerated()), id: \.element.id) { index, configuration in
                            providerRow(configuration, at: index)
                        }
                    }
                }

                Toggle(
                    "Automatically try the next API provider when a usage, credit, or spend limit is reached",
                    isOn: $autoFallbackOnQuotaLimit
                )
                .disabled(configurations.count < 2)

                Text("Keys are stored separately in macOS Keychain. The numbered list controls the attempt order. Other errors stop processing so configuration and service issues remain visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: configurations.isEmpty ? "key" : "key.fill")
                        .foregroundStyle(configurations.isEmpty ? Color.secondary : Color.green)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Generate Meeting Notes") {
                        Task { await generateNotes() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || configurations.isEmpty
                            || isGenerating
                    )
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    }
                }

                Text("Generating notes sends the transcript to the provider being attempted. Completed notes are saved locally with the recording.")
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
        .task { loadConfigurationsAndMigrateLegacyKeys() }
        .onChange(of: newProvider) { _, provider in
            newModel = provider.defaultModel
        }
        .onChange(of: suggestedRecipients, initial: true) { _, updatedRecipients in
            recipients = EmailAddressExtractor.merged(updatedRecipients)
            selectedRecipientIDs = Set(recipients.map(\.id))
        }
    }

    @ViewBuilder
    private func providerRow(_ configuration: APIProviderConfiguration, at index: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.headline.monospacedDigit())
                .frame(width: 24)
            Text(configuration.provider.rawValue)
                .frame(width: 75, alignment: .leading)
            TextField("Label", text: configurationBinding(configuration.id, keyPath: \.label))
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: configurationBinding(configuration.id, keyPath: \.model))
                .textFieldStyle(.roundedBorder)
            Button { moveConfiguration(from: index, to: index - 1) } label: {
                Image(systemName: "arrow.up")
            }
            .help("Move earlier")
            .disabled(index == 0)
            Button { moveConfiguration(from: index, to: index + 1) } label: {
                Image(systemName: "arrow.down")
            }
            .help("Move later")
            .disabled(index == configurations.count - 1)
            Button(role: .destructive) { removeConfiguration(configuration) } label: {
                Image(systemName: "trash")
            }
            .help("Remove API key")
        }
    }

    private func configurationBinding(
        _ id: UUID,
        keyPath: WritableKeyPath<APIProviderConfiguration, String>
    ) -> Binding<String> {
        Binding(
            get: { configurations.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { value in
                guard let index = configurations.firstIndex(where: { $0.id == id }) else { return }
                configurations[index][keyPath: keyPath] = value
                persistConfigurations()
            }
        )
    }

    private func addConfiguration() {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = APIProviderConfiguration(
            provider: newProvider,
            label: label.isEmpty ? "\(newProvider.rawValue) key \(configurations.count + 1)" : label,
            model: model.isEmpty ? newProvider.defaultModel : model
        )
        do {
            try APIKeyStore.save(newAPIKey, identifier: configuration.id.uuidString)
            configurations.append(configuration)
            persistConfigurations()
            newAPIKey = ""
            newLabel = ""
            status = "\(configuration.label) added as provider \(configurations.count)."
        } catch {
            status = error.localizedDescription
        }
    }

    private func removeConfiguration(_ configuration: APIProviderConfiguration) {
        do {
            try APIKeyStore.delete(identifier: configuration.id.uuidString)
            configurations.removeAll { $0.id == configuration.id }
            persistConfigurations()
            status = "\(configuration.label) removed from macOS Keychain."
        } catch {
            status = error.localizedDescription
        }
    }

    private func moveConfiguration(from source: Int, to destination: Int) {
        guard configurations.indices.contains(source),
              configurations.indices.contains(destination) else { return }
        let configuration = configurations.remove(at: source)
        configurations.insert(configuration, at: destination)
        persistConfigurations()
        status = "API provider order updated."
    }

    private func persistConfigurations() {
        APIProviderConfigurationStore.save(configurations)
    }

    private func loadConfigurationsAndMigrateLegacyKeys() {
        configurations = APIProviderConfigurationStore.load()
        guard configurations.isEmpty else {
            status = "\(configurations.count) API provider configuration(s) ready."
            return
        }

        var migrated: [APIProviderConfiguration] = []
        for provider in MeetingNotesProvider.allCases {
            let legacyKey: String?
            do {
                legacyKey = try APIKeyStore.load(for: provider)
            } catch {
                continue
            }
            guard let key = legacyKey else { continue }
            let configuration = APIProviderConfiguration(
                provider: provider,
                label: "\(provider.rawValue) key",
                model: provider.defaultModel
            )
            do {
                try APIKeyStore.save(key, identifier: configuration.id.uuidString)
                migrated.append(configuration)
            } catch {
                status = error.localizedDescription
                return
            }
        }

        configurations = migrated
        persistConfigurations()
        status = migrated.isEmpty
            ? "Add one or more API providers in the order they should be used."
            : "Existing API keys migrated into the ordered provider list."
    }

    private func generateNotes() async {
        isGenerating = true
        defer { isGenerating = false }

        for (index, configuration) in configurations.enumerated() {
            do {
                guard let key = try APIKeyStore.load(identifier: configuration.id.uuidString) else {
                    throw MeetingNotesServiceError.missingAPIKey
                }
                status = "Trying \(index + 1) of \(configurations.count): \(configuration.label)..."
                generatedNotes = try await notesService.generate(
                    transcript: transcript,
                    provider: configuration.provider,
                    model: configuration.model,
                    apiKey: key
                )
                try writeGeneratedNotes()
                status = "Meeting notes generated with \(configuration.label) and saved locally."
                return
            } catch {
                let shouldContinue = APIFallbackPolicy.shouldTryNext(
                    after: error,
                    automaticFallbackEnabled: autoFallbackOnQuotaLimit,
                    hasNextProvider: index < configurations.count - 1
                )
                if shouldContinue {
                    status = "\(configuration.label) reached its limit. Trying the next provider..."
                    continue
                }
                status = error.localizedDescription
                return
            }
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
        service.subject = meetingTitle.isEmpty ? "Meeting notes" : "Meeting notes: \(meetingTitle)"
        service.perform(withItems: [generatedNotes])
        status = "Email draft prepared for review and sending."
    }
}
