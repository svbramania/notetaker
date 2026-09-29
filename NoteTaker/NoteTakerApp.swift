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

private struct MeetingProcessingJob: Identifiable {
    let id = UUID()
    let title: String
    let attendees: [String]
    let recipients: [MeetingEmailRecipient]
    let startedAt: Date
    let endedAt: Date
    let sessionDirectory: URL
    let microphoneURL: URL?
    let systemAudioURL: URL?
    let typedEntries: [ScribeEntry]
}

private struct MeetingProcessingFailure: Identifiable {
    let id = UUID()
    let job: MeetingProcessingJob
    let message: String
}

struct ContentView: View {
    @StateObject private var recorder = MeetingRecorder()
    @StateObject private var calendarMonitor = CalendarMeetingMonitor()
    @StateObject private var recordingPermissions = RecordingPermissionManager()
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
    @State private var autoRecordedMeetingID: String?
    @State private var skippedAutoMeetingIDs: Set<String> = []
    @State private var isSynchronizingAutoRecording = false
    @State private var autoRecordingSyncPending = false
    @State private var showsCalendarSelection = false
    @State private var calendarEmailRecipients: [MeetingEmailRecipient] = []
    @State private var signOffStopTask: Task<Void, Never>?
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var transcriptionTaskID: UUID?
    @State private var processingQueue: [MeetingProcessingJob] = []
    @State private var processingFailure: MeetingProcessingFailure?
    @State private var savedMeetings: [SavedMeetingSession] = []
    @State private var selectedSavedMeetingID = ""
    @State private var availableMeetingEmailClients: [MeetingEmailClient] = []
    @State private var meetingSenderAccount = ""
    @AppStorage("autoRecordCalendarMeetings") private var autoRecordCalendarMeetings = true
    @AppStorage("autoStopOnSpokenSignOff") private var autoStopOnSpokenSignOff = true
    @AppStorage("calendarAlertsEnabled") private var calendarAlertsEnabled = true
    @AppStorage("autoFallbackOnAPIQuotaLimit") private var autoFallbackOnQuotaLimit = false
    @AppStorage("autoOpenEmailDraftAfterNotes") private var autoOpenEmailDraftAfterNotes = true
    @AppStorage("autoEmailEveryone") private var autoEmailEveryone = false
    @AppStorage("lastMeetingNotesRecipientEmail") private var lastRecipientEmail = ""
    @AppStorage("preferredMeetingEmailClient") private var emailClientRawValue = ""

    private let scribe = LocalScribe()

    var body: some View {
        TabView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("NoteTaker Scribe").font(.largeTitle.bold())
                    meetingSection
                    calendarMeetingSection
                }
                .padding(20)
            }
            .tabItem { Label("Meeting", systemImage: "waveform") }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings").font(.largeTitle.bold())
                    calendarSettingsSection
                    recordingPermissionSection
                    CloudMeetingNotesView(
                        transcript: report,
                        meetingTitle: title,
                        sessionDirectory: recorder.sessionDirectory,
                        suggestedRecipients: suggestedEmailRecipients,
                        autoGenerateRequestID: nil
                    )
                    .id(recorder.sessionDirectory?.path ?? "meeting-notes-configuration")
                    HStack {
                        Button("Summarize in ChatGPT") { openInChatGPT() }
                            .disabled(report.isEmpty)
                        Button("Open Recordings Folder") { openRecordingsFolder() }
                    }
                }
                .padding(20)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            if calendarAlertsEnabled { calendarMonitor.start() }
            refreshSavedMeetings(selectMostRecent: true)
            refreshMeetingEmailClients()
        }
        .onChange(of: calendarMonitor.activeMeeting, initial: true) { _, _ in
            Task { await synchronizeCalendarRecording() }
        }
        .onChange(of: autoRecordCalendarMeetings) { _, _ in
            Task { await synchronizeCalendarRecording() }
        }
        .onChange(of: emailClientRawValue) { _, _ in
            loadMeetingSenderAccount()
        }
        .onChange(of: meetingSenderAccount) { _, account in
            saveMeetingSenderAccount(account)
        }
        .onChange(of: calendarAlertsEnabled) { _, enabled in
            if enabled {
                calendarMonitor.start()
                Task {
                    if !calendarMonitor.calendarAccessGranted { await calendarMonitor.requestAccess() }
                    await synchronizeCalendarRecording()
                }
            } else {
                calendarMonitor.stop()
                Task { await synchronizeCalendarRecording() }
            }
        }
        .onChange(of: recorder.detectedSignOffText) { _, phrase in
            scheduleSpokenSignOffStop(for: phrase)
        }
        .onChange(of: autoStopOnSpokenSignOff) { _, enabled in
            signOffStopTask?.cancel()
            signOffStopTask = nil
            recorder.setSignOffDetectionEnabled(enabled)
        }
        .onChange(of: selectedSavedMeetingID) { _, meetingID in
            loadSavedMeeting(withID: meetingID)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recordingPermissions.refresh()
            refreshSavedMeetings(selectMostRecent: selectedSavedMeetingID.isEmpty)
            if calendarAlertsEnabled {
                Task {
                    await calendarMonitor.refresh()
                    await synchronizeCalendarRecording()
                }
            }
        }
        .sheet(isPresented: $showsCalendarSelection) {
            CalendarSelectionView(calendarMonitor: calendarMonitor)
        }
        .alert(item: $processingFailure) { failure in
            Alert(
                title: Text("Meeting Notes Generation Failed"),
                message: Text(failure.message),
                primaryButton: .default(Text("Retry")) {
                    enqueueProcessing(failure.job, atFront: true)
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
    }

    @ViewBuilder
    private var meetingSection: some View {
        GroupBox("Meeting") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Meeting title", text: $title)
                TextField("Attendees or email addresses (comma-separated, if known)", text: $attendees)

                HStack(spacing: 12) {
                    Button {
                        Task { await toggleRecording(clearCalendarRecipients: true) }
                    } label: {
                        Label(recorder.isRecording ? "Stop Meeting" : "Record Meeting", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    if isProcessing { ProgressView().controlSize(.small) }
                    Text(recorder.status).foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Picker("Saved meeting", selection: $selectedSavedMeetingID) {
                        if savedMeetings.isEmpty { Text("No saved meetings").tag("") }
                        ForEach(savedMeetings) { meeting in Text(meeting.displayName).tag(meeting.id) }
                    }
                    .frame(maxWidth: 430)
                    .disabled(recorder.isRecording || isProcessing || savedMeetings.isEmpty)
                    Button("Refresh") { refreshSavedMeetings(selectMostRecent: selectedSavedMeetingID.isEmpty) }
                    Button("Transcribe Meeting") { Task { await startTranscriptBuild() } }
                        .disabled(recorder.isRecording || isProcessing || recorder.sessionDirectory == nil)
                    if isProcessing {
                        Button("Cancel") { transcriptionTask?.cancel() }
                    }
                }

                HStack {
                    Picker("Source", selection: $typedSource) {
                        Text("Chat").tag(ScribeEntry.Source.chat)
                        Text("My note").tag(ScribeEntry.Source.note)
                    }
                    .frame(width: 150)
                    TextField("Optional meeting chat or note", text: $typedEntry)
                        .onSubmit(addTypedEntry)
                    Button("Add") { addTypedEntry() }
                }

                Divider()
                Text("Email automation").font(.headline)
                Toggle("Automatically prepare an email draft after notes are generated", isOn: $autoOpenEmailDraftAfterNotes)
                Toggle("Send to everyone on the calendar invitation", isOn: $autoEmailEveryone)
                    .disabled(!autoOpenEmailDraftAfterNotes || suggestedEmailRecipients.isEmpty)

                if !suggestedEmailRecipients.isEmpty {
                    Text("Recipients").font(.subheadline.bold())
                    ForEach(suggestedEmailRecipients) { recipient in
                        Toggle(
                            isOn: Binding(
                                get: {
                                    autoEmailEveryone
                                        || recipient.email.localizedCaseInsensitiveCompare(lastRecipientEmail) == .orderedSame
                                },
                                set: { selected in
                                    autoEmailEveryone = false
                                    lastRecipientEmail = selected ? recipient.email : ""
                                }
                            )
                        ) {
                            Text("\(recipient.name) — \(recipient.email)")
                        }
                        .disabled(autoEmailEveryone)
                    }
                } else {
                    Text("Recipient choices will appear when the calendar invitation or attendee field contains email addresses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Picker("Email client", selection: $emailClientRawValue) {
                        Text("Choose an installed email client").tag("")
                        ForEach(availableMeetingEmailClients) { client in
                            Text(client.rawValue).tag(client.rawValue)
                        }
                    }
                    TextField("Sender account email", text: $meetingSenderAccount)
                        .disabled(emailClientRawValue.isEmpty)
                    Button("Refresh") { refreshMeetingEmailClients() }
                }
                Text("After notes are generated, NoteTaker opens the configured client with the selected recipients and notes filled in for review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(6)
        }
    }

    @ViewBuilder
    private var calendarSettingsSection: some View {
        GroupBox("Calendar automation") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable calendar alerts", isOn: $calendarAlertsEnabled)
                Toggle("Auto-record calendar meetings", isOn: $autoRecordCalendarMeetings)
                    .disabled(!calendarAlertsEnabled || !calendarMonitor.calendarAccessGranted)
                Toggle(
                    "Also auto-record invitations without a Teams, Zoom, or Google Meet link",
                    isOn: Binding(
                        get: { calendarMonitor.includeInvitesWithoutLinks },
                        set: { calendarMonitor.setIncludeInvitesWithoutLinks($0) }
                    )
                )
                .disabled(!calendarAlertsEnabled || !calendarMonitor.calendarAccessGranted || !autoRecordCalendarMeetings)
                HStack {
                    Text(calendarMonitor.status).foregroundStyle(.secondary)
                    Spacer()
                    if !calendarMonitor.calendarAccessGranted {
                        Button("Allow Calendar Access") { Task { await calendarMonitor.requestAccess() } }
                    } else {
                        Button("Choose Calendars") { showsCalendarSelection = true }
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var recordingPermissionSection: some View {
        GroupBox("Recording access") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    permissionStatus(
                        title: "Microphone",
                        granted: recordingPermissions.microphoneGranted
                    )
                    permissionStatus(
                        title: "Speakers / System Audio",
                        granted: recordingPermissions.systemAudioGranted
                    )

                    Spacer()

                    Button("Allow Access to Mic and Speakers") {
                        Task { await recordingPermissions.requestAccess() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recordingPermissions.allAccessGranted || recordingPermissions.isRequesting)

                    if !recordingPermissions.allAccessGranted {
                        Button("Open Privacy Settings") {
                            recordingPermissions.openPrivacySettings()
                        }
                    }
                }

                HStack(spacing: 8) {
                    if recordingPermissions.isRequesting {
                        ProgressView().controlSize(.small)
                    }
                    Text(recordingPermissions.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Stop after a spoken sign-off and build the transcript automatically",
                    isOn: $autoStopOnSpokenSignOff
                )
                .toggleStyle(.switch)

                Text("When a closing phrase such as “bye,” “goodbye,” or “thanks everyone” remains the final speech for four seconds, NoteTaker stops recording and transcribes both audio tracks. Calendar end time remains the fallback for calendar recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private func permissionStatus(title: String, granted: Bool) -> some View {
        Label(
            "\(title): \(granted ? "Ready" : "Permission required")",
            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .foregroundStyle(granted ? Color.green : Color.gray)
    }

    @ViewBuilder
    private var calendarMeetingSection: some View {
        GroupBox("Upcoming video meetings") {
            VStack(alignment: .leading, spacing: 10) {
                if !calendarAlertsEnabled {
                    Label("Calendar alerts are turned off in Settings", systemImage: "calendar.badge.minus")
                        .foregroundStyle(.secondary)
                } else if let meeting = calendarMonitor.meetingToPrompt {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: meeting.provider.systemImage)
                            .font(.title2)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Meeting starts soon—record?")
                                .font(.headline)
                            Text("\(meeting.title) • \(meeting.provider.rawValue) • \(meetingTime(meeting.startDate))")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Record Meeting") {
                            prepareAndRecord(meeting)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.isRecording)

                        Button("Dismiss") {
                            calendarMonitor.dismissPrompt()
                        }
                    }
                } else if calendarMonitor.calendarAccessGranted {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.secondary)
                        if let meeting = calendarMonitor.nextMeeting {
                            Text("Next: \(meeting.title) at \(meetingTime(meeting.startDate)) on \(meeting.provider.rawValue)")
                        } else {
                            Text(
                                calendarMonitor.includeInvitesWithoutLinks
                                    ? "Watching for video links and attendee-based meeting invitations"
                                    : "Watching Calendar for Teams, Zoom, and Google Meet links"
                            )
                        }
                        Spacer()
                        if calendarMonitor.notificationAccessGranted {
                            Button("Refresh") {
                                Task { await calendarMonitor.refresh() }
                            }
                        } else {
                            Button("Enable Notifications") {
                                Task { await calendarMonitor.requestNotificationPermission() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Text("Allow Calendar access from Settings to detect upcoming video meetings.")
                        .foregroundStyle(.secondary)
                }

                Text(calendarMonitor.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var suggestedEmailRecipients: [MeetingEmailRecipient] {
        EmailAddressExtractor.merged(
            calendarEmailRecipients + EmailAddressExtractor.recipients(in: attendees)
        )
    }

    private func toggleRecording(clearCalendarRecipients: Bool = false) async {
        errorMessage = nil
        do {
            if recorder.isRecording {
                if let autoRecordedMeetingID {
                    skippedAutoMeetingIDs.insert(autoRecordedMeetingID)
                    self.autoRecordedMeetingID = nil
                }
                await finishRecordingAndTranscribe(status: "Recording stopped — building transcript")
            } else {
                if clearCalendarRecipients {
                    calendarEmailRecipients = []
                }
                report = ""
                entries = []
                startedAt = Date()
                endedAt = nil
                if autoStopOnSpokenSignOff {
                    try? await scribe.requestAuthorization()
                }
                try await recorder.start(
                    folderTitle: title,
                    detectSignOffPhrases: autoStopOnSpokenSignOff
                )
                refreshSavedMeetings(preferredDirectory: recorder.sessionDirectory)
            }
        } catch {
            errorMessage = error.localizedDescription
            await recorder.stop()
        }
    }

    private func synchronizeCalendarRecording() async {
        if isSynchronizingAutoRecording {
            autoRecordingSyncPending = true
            return
        }

        isSynchronizingAutoRecording = true
        repeat {
            autoRecordingSyncPending = false
            await applyCalendarRecordingState()
        } while autoRecordingSyncPending
        isSynchronizingAutoRecording = false
    }

    private func applyCalendarRecordingState() async {
        let activeMeeting = calendarMonitor.activeMeeting

        if let activeMeeting {
            skippedAutoMeetingIDs.formIntersection([activeMeeting.id])
        } else {
            skippedAutoMeetingIDs.removeAll()
        }

        guard calendarAlertsEnabled, autoRecordCalendarMeetings else {
            await stopAutomaticRecording(status: "Calendar auto-record turned off — recording saved locally")
            return
        }

        if let autoRecordedMeetingID, autoRecordedMeetingID != activeMeeting?.id {
            await stopAutomaticRecording(status: "Calendar meeting ended — recording saved locally")
        }

        guard let activeMeeting,
              !skippedAutoMeetingIDs.contains(activeMeeting.id),
              autoRecordedMeetingID == nil,
              !recorder.isRecording else { return }

        title = activeMeeting.title
        attendees = activeMeeting.attendeeNames.joined(separator: ", ")
        calendarEmailRecipients = activeMeeting.emailRecipients
        report = ""
        entries = []
        startedAt = Date()
        endedAt = nil
        errorMessage = nil

        do {
            if autoStopOnSpokenSignOff {
                try? await scribe.requestAuthorization()
            }
            try await recorder.start(
                folderTitle: activeMeeting.title,
                detectSignOffPhrases: autoStopOnSpokenSignOff
            )
            refreshSavedMeetings(preferredDirectory: recorder.sessionDirectory)
            autoRecordedMeetingID = activeMeeting.id
            recorder.status = "Auto-recording until \(meetingTime(activeMeeting.endDate))"
        } catch {
            errorMessage = "Could not auto-record \(activeMeeting.title): \(error.localizedDescription)"
            skippedAutoMeetingIDs.insert(activeMeeting.id)
            await recorder.stop()
        }
    }

    private func stopAutomaticRecording(status: String) async {
        guard autoRecordedMeetingID != nil else { return }

        if recorder.isRecording {
            await finishRecordingAndTranscribe(status: status)
        }
        autoRecordedMeetingID = nil
    }

    private func scheduleSpokenSignOffStop(for phrase: String?) {
        signOffStopTask?.cancel()
        signOffStopTask = nil

        guard autoStopOnSpokenSignOff,
              let phrase,
              recorder.isRecording,
              !isProcessing else { return }

        signOffStopTask = Task {
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  recorder.isRecording,
                  recorder.detectedSignOffText == phrase else { return }

            if let autoRecordedMeetingID {
                skippedAutoMeetingIDs.insert(autoRecordedMeetingID)
                self.autoRecordedMeetingID = nil
            }
            signOffStopTask = nil
            await finishRecordingAndTranscribe(
                status: "Heard “\(phrase)” — recording stopped and transcript is being built"
            )
        }
    }

    private func finishRecordingAndTranscribe(status: String) async {
        guard recorder.isRecording else { return }
        signOffStopTask?.cancel()
        signOffStopTask = nil
        await recorder.stop()
        let finishedAt = Date()
        endedAt = finishedAt
        recorder.status = status
        refreshSavedMeetings(preferredDirectory: recorder.sessionDirectory)
        if let job = makeProcessingJob(endedAt: finishedAt) {
            enqueueProcessing(job)
        }
    }

    private func prepareAndRecord(_ meeting: UpcomingVideoMeeting) {
        title = meeting.title
        attendees = meeting.attendeeNames.joined(separator: ", ")
        calendarEmailRecipients = meeting.emailRecipients
        calendarMonitor.dismissPrompt()
        Task { await toggleRecording() }
    }

    private func addTypedEntry() {
        let text = typedEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entries.append(ScribeEntry(source: typedSource, text: text))
        typedEntry = ""
    }

    private func startTranscriptBuild() async {
        guard let job = makeProcessingJob(endedAt: endedAt ?? Date()) else { return }
        enqueueProcessing(job)
    }

    private func makeProcessingJob(endedAt: Date) -> MeetingProcessingJob? {
        guard let start = startedAt,
              let folder = recorder.sessionDirectory,
              recorder.microphoneURL != nil || recorder.systemAudioURL != nil else {
            errorMessage = "The selected meeting does not contain a microphone or system-audio recording."
            return nil
        }
        return MeetingProcessingJob(
            title: title,
            attendees: attendees.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            recipients: suggestedEmailRecipients,
            startedAt: start,
            endedAt: endedAt,
            sessionDirectory: folder,
            microphoneURL: recorder.microphoneURL,
            systemAudioURL: recorder.systemAudioURL,
            typedEntries: entries.filter { $0.source == .chat || $0.source == .note }
        )
    }

    private func enqueueProcessing(_ job: MeetingProcessingJob, atFront: Bool = false) {
        if atFront { processingQueue.insert(job, at: 0) } else { processingQueue.append(job) }
        startProcessingQueueIfNeeded()
    }

    private func startProcessingQueueIfNeeded() {
        guard transcriptionTask == nil else { return }
        let taskID = UUID()
        transcriptionTaskID = taskID
        transcriptionTask = Task {
            while !processingQueue.isEmpty, !Task.isCancelled {
                let job = processingQueue.removeFirst()
                await buildTranscript(for: job)
            }
            if transcriptionTaskID == taskID {
                transcriptionTask = nil
                transcriptionTaskID = nil
            }
        }
    }

    private func buildTranscript(for job: MeetingProcessingJob) async {

        errorMessage = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            try await scribe.requestAuthorization()
            var transcriptionErrors: [Error] = []

            let micEntries: [ScribeEntry]
            if let mic = job.microphoneURL {
                recorder.status = "Preparing microphone transcription..."
                do {
                    micEntries = try await scribe.transcribeFileAllowingSilence(
                        mic,
                        source: .microphone,
                        meetingStart: job.startedAt
                    ) { progress in
                        recorder.status = transcriptionStatus(
                            track: "microphone",
                            progress: progress
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    micEntries = []
                    transcriptionErrors.append(error)
                }
            } else {
                micEntries = []
            }

            let systemEntries: [ScribeEntry]
            if let system = job.systemAudioURL {
                recorder.status = "Preparing system-audio transcription..."
                do {
                    systemEntries = try await scribe.transcribeFileAllowingSilence(
                        system,
                        source: .systemAudio,
                        meetingStart: job.startedAt
                    ) { progress in
                        recorder.status = transcriptionStatus(
                            track: "system audio",
                            progress: progress
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    systemEntries = []
                    transcriptionErrors.append(error)
                }
            } else {
                systemEntries = []
            }

            let spoken = scribe.mergeSpokenEntries(
                microphone: micEntries,
                systemAudio: systemEntries
            )
            if spoken.isEmpty && job.typedEntries.isEmpty {
                throw transcriptionErrors.first ?? LocalScribeError.noSpeechDetected
            }
            let allEntries = (job.typedEntries + spoken).sorted { $0.timestamp < $1.timestamp }

            let built = scribe.buildTranscript(
                title: job.title,
                startedAt: job.startedAt,
                endedAt: job.endedAt,
                attendees: job.attendees,
                entries: allEntries
            )
            try save(report: built, entries: allEntries, in: job.sessionDirectory)
            if recorder.sessionDirectory == job.sessionDirectory {
                report = built
                entries = allEntries
            }
            recorder.status = transcriptionErrors.isEmpty
                ? "Transcript saved — generating formatted meeting notes"
                : "Partial transcript saved — generating formatted meeting notes"
            try await generateAndSaveNotes(for: job, transcript: built)
            refreshSavedMeetings(preferredDirectory: recorder.sessionDirectory)
        } catch is CancellationError {
            recorder.status = "Transcription cancelled — recordings preserved for retry"
        } catch {
            errorMessage = error.localizedDescription
            processingFailure = MeetingProcessingFailure(job: job, message: error.localizedDescription)
        }
    }

    private func generateAndSaveNotes(for job: MeetingProcessingJob, transcript: String) async throws {
        let configurations = APIProviderConfigurationStore.load()
        guard !configurations.isEmpty else {
            recorder.status = "Transcript saved — no API provider configured"
            return
        }

        var lastError: Error?
        for (index, configuration) in configurations.enumerated() {
            do {
                guard let key = try APIKeyStore.load(identifier: configuration.id.uuidString) else {
                    throw MeetingNotesServiceError.missingAPIKey
                }
                let notes = try await MeetingNotesService().generate(
                    transcript: transcript,
                    provider: configuration.provider,
                    model: configuration.model,
                    apiKey: key
                )
                try notes.write(
                    to: job.sessionDirectory.appendingPathComponent("meeting-notes.md"),
                    atomically: true,
                    encoding: .utf8
                )
                recorder.status = "Meeting notes generated and saved"
                if autoOpenEmailDraftAfterNotes {
                    prepareAutomaticEmail(notes: notes, job: job)
                }
                return
            } catch {
                lastError = error
                if APIFallbackPolicy.shouldTryNext(
                    after: error,
                    automaticFallbackEnabled: autoFallbackOnQuotaLimit,
                    hasNextProvider: index < configurations.count - 1
                ) { continue }
                throw error
            }
        }
        throw lastError ?? MeetingNotesServiceError.invalidResponse
    }

    private func prepareAutomaticEmail(notes: String, job: MeetingProcessingJob) {
        guard let client = MeetingEmailClient(rawValue: emailClientRawValue) else { return }
        let sender = UserDefaults.standard.string(forKey: client.senderAccountDefaultsKey) ?? ""
        guard MeetingEmailSenderAccount.isValid(sender) else { return }
        let selected = autoEmailEveryone
            ? job.recipients.map(\.email)
            : job.recipients.filter { $0.email.localizedCaseInsensitiveCompare(lastRecipientEmail) == .orderedSame }.map(\.email)
        guard !selected.isEmpty else { return }
        try? MeetingEmailLauncher.launch(
            MeetingEmailDraft(
                recipients: selected,
                subject: job.title.isEmpty ? "Meeting notes" : "Meeting notes: \(job.title)",
                body: notes,
                senderAccount: sender
            ),
            with: client
        )
    }

    private func refreshMeetingEmailClients() {
        availableMeetingEmailClients = MeetingEmailClient.installed()
        guard let selected = MeetingEmailClient(rawValue: emailClientRawValue),
              availableMeetingEmailClients.contains(selected) else {
            emailClientRawValue = ""
            meetingSenderAccount = ""
            return
        }
        loadMeetingSenderAccount()
    }

    private func loadMeetingSenderAccount() {
        guard let client = MeetingEmailClient(rawValue: emailClientRawValue) else {
            meetingSenderAccount = ""
            return
        }
        meetingSenderAccount = UserDefaults.standard.string(forKey: client.senderAccountDefaultsKey) ?? ""
    }

    private func saveMeetingSenderAccount(_ account: String) {
        guard let client = MeetingEmailClient(rawValue: emailClientRawValue) else { return }
        UserDefaults.standard.set(account, forKey: client.senderAccountDefaultsKey)
    }

    private func transcriptionStatus(
        track: String,
        progress: TranscriptionProgress
    ) -> String {
        let failures = progress.failedChunks == 0
            ? ""
            : " • \(progress.failedChunks) retried/failed"
        return "Transcribing \(track): chunk \(progress.completedChunks) of \(progress.totalChunks)\(failures)"
    }

    private func refreshSavedMeetings(
        selectMostRecent: Bool = false,
        preferredDirectory: URL? = nil
    ) {
        savedMeetings = MeetingRecorder.savedSessions()
        let preferredID = preferredDirectory?.path
        let retainedID = savedMeetings.contains { $0.id == selectedSavedMeetingID }
            ? selectedSavedMeetingID
            : nil
        let selection = preferredID.flatMap { id in
            savedMeetings.first(where: { $0.id == id })?.id
        } ?? (selectMostRecent ? savedMeetings.first?.id : retainedID ?? savedMeetings.first?.id)

        selectedSavedMeetingID = selection ?? ""
        if !recorder.isRecording,
           recorder.sessionDirectory?.path != selectedSavedMeetingID {
            loadSavedMeeting(withID: selectedSavedMeetingID)
        }
    }

    private func loadSavedMeeting(withID meetingID: String) {
        guard !meetingID.isEmpty,
              !recorder.isRecording,
              !isProcessing,
              let meeting = savedMeetings.first(where: { $0.id == meetingID }) else { return }

        recorder.selectSavedSession(meeting)
        title = meeting.title
        startedAt = meeting.startedAt
        endedAt = meeting.updatedAt
        calendarEmailRecipients = []
        errorMessage = nil

        let transcriptURL = meeting.directoryURL.appendingPathComponent("meeting-transcript.md")
        report = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""

        let entriesURL = meeting.directoryURL.appendingPathComponent("transcript.json")
        if let data = try? Data(contentsOf: entriesURL),
           let restoredEntries = try? JSONDecoder().decode([ScribeEntry].self, from: data) {
            entries = restoredEntries
        } else {
            entries = []
        }
    }

    private func save(report: String, entries: [ScribeEntry], in folder: URL) throws {
        try report.write(to: folder.appendingPathComponent("meeting-transcript.md"), atomically: true, encoding: .utf8)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        let prompt = scribe.chatGPTPrompt(for: report)
        try prompt.write(to: folder.appendingPathComponent("chatgpt-summary-prompt.md"), atomically: true, encoding: .utf8)
    }

    private func openInChatGPT() {
        let prompt = scribe.chatGPTPrompt(for: report)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)

        recorder.status = "Prompt copied — paste it into ChatGPT and send"

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init(), completionHandler: nil)
        } else if let webURL = URL(string: "https://chatgpt.com/") {
            NSWorkspace.shared.open(webURL)
        }
    }

    private func openRecordingsFolder() {
        let folder = MeetingRecorder.meetingsDirectory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func meetingTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct CalendarSelectionView: View {
    @ObservedObject var calendarMonitor: CalendarMeetingMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose Calendars")
                        .font(.title2.bold())
                    Text("Select calendars from every Gmail, Outlook, Exchange, and iCloud account connected to this Mac.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack {
                Button("Select All") {
                    calendarMonitor.selectAllCalendars()
                }
                Button("Clear Selection") {
                    calendarMonitor.clearCalendarSelection()
                }
                Spacer()
                Text("\(calendarMonitor.includedCalendarCount) selected")
                    .foregroundStyle(.secondary)
            }

            if calendarMonitor.calendarAccounts.isEmpty {
                ContentUnavailableView(
                    "No Calendars Found",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Add Gmail or Outlook accounts in macOS System Settings under Internet Accounts, then return to NoteTaker.")
                )
            } else {
                List {
                    ForEach(calendarMonitor.calendarAccounts) { account in
                        Section {
                            ForEach(account.calendars) { calendar in
                                Toggle(
                                    isOn: Binding(
                                        get: { calendarMonitor.isCalendarIncluded(calendar.id) },
                                        set: { calendarMonitor.setCalendarIncluded(calendar.id, included: $0) }
                                    )
                                ) {
                                    Text(calendar.title)
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                Text(account.providerName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Text("New calendars and newly connected accounts are included automatically. Calendar choices are saved on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
    }
}
