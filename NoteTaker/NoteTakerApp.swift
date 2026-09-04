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
    @AppStorage("autoRecordCalendarMeetings") private var autoRecordCalendarMeetings = true

    private let scribe = LocalScribe()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            Text("NoteTaker Scribe")
                .font(.largeTitle.bold())
            Text("Capture everything said, then create meeting notes with ChatGPT handoff, OpenAI, or Claude")
                .foregroundStyle(.secondary)

            GroupBox("Meeting") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Meeting title", text: $title)
                    TextField("Attendees or email addresses (comma-separated, if known)", text: $attendees)
                }
                .textFieldStyle(.roundedBorder)
                .padding(6)
            }

            calendarMeetingSection

            recordingPermissionSection

            HStack(spacing: 12) {
                Button {
                    Task { await toggleRecording(clearCalendarRecipients: true) }
                } label: {
                    Label(recorder.isRecording ? "Stop Meeting" : "Record Meeting", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)

                Button("Build Transcript") {
                    Task { await buildTranscript() }
                }
                .disabled(recorder.isRecording || isProcessing || recorder.sessionDirectory == nil)

                Button("Summarize in ChatGPT") {
                    openInChatGPT()
                }
                .disabled(recorder.isRecording || isProcessing || report.isEmpty)

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

            GroupBox("Meeting transcript") {
                ScrollView {
                    Text(report.isEmpty ? "After the meeting, choose Build Transcript. Spoken audio and typed meeting content will be combined into one local, timestamped transcript." : report)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(minHeight: 300)
            }

            CloudMeetingNotesView(
                transcript: report,
                meetingTitle: title,
                sessionDirectory: recorder.sessionDirectory,
                suggestedRecipients: suggestedEmailRecipients
            )
            .id(recorder.sessionDirectory?.path ?? "meeting-notes-configuration")

            HStack {
                Button("Open Recordings Folder") { openRecordingsFolder() }
                Spacer()
                Text("Audio and transcription remain on this Mac. Recording consent laws still apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
            .padding(20)
        }
        .task {
            calendarMonitor.start()
        }
        .onChange(of: calendarMonitor.activeMeeting, initial: true) { _, _ in
            Task { await synchronizeCalendarRecording() }
        }
        .onChange(of: autoRecordCalendarMeetings) { _, _ in
            Task { await synchronizeCalendarRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recordingPermissions.refresh()
            Task {
                await calendarMonitor.refresh()
                await synchronizeCalendarRecording()
            }
        }
        .sheet(isPresented: $showsCalendarSelection) {
            CalendarSelectionView(calendarMonitor: calendarMonitor)
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
                HStack(alignment: .center, spacing: 12) {
                    Toggle("Auto-record calendar meetings", isOn: $autoRecordCalendarMeetings)
                        .toggleStyle(.switch)
                        .disabled(!calendarMonitor.calendarAccessGranted)

                    Spacer()

                    if autoRecordCalendarMeetings {
                        Label("On", systemImage: "calendar.badge.checkmark")
                            .foregroundStyle(.green)
                    }
                }

                Text(
                    autoRecordCalendarMeetings
                        ? "NoteTaker starts and stops automatically for invitations containing a Teams, Zoom, or Google Meet link. Keep NoteTaker running and confirm participants have consented to recording."
                        : "Turn this on to start and stop recording automatically from Teams, Zoom, and Google Meet calendar times."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle(
                    "Also auto-record meeting invitations without a Teams, Zoom, or Google Meet link",
                    isOn: Binding(
                        get: { calendarMonitor.includeInvitesWithoutLinks },
                        set: { calendarMonitor.setIncludeInvitesWithoutLinks($0) }
                    )
                )
                .disabled(!calendarMonitor.calendarAccessGranted || !autoRecordCalendarMeetings)

                Text("This optional setting applies to timed calendar invitations with attendees; personal calendar blocks remain excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if calendarMonitor.calendarAccessGranted {
                    HStack {
                        Text(
                            "Monitoring \(calendarMonitor.includedCalendarCount) of \(calendarMonitor.availableCalendars.count) calendars across \(calendarMonitor.calendarAccounts.count) accounts"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Spacer()

                        Button("Choose Calendars") {
                            showsCalendarSelection = true
                        }
                    }
                }

                Divider()

                if let meeting = calendarMonitor.meetingToPrompt {
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
                        .disabled(recorder.isRecording || isProcessing)

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
                    HStack {
                        Image(systemName: "calendar.badge.plus")
                            .foregroundStyle(.secondary)
                        Text("Connect macOS Calendar to receive a recording prompt five minutes before supported video meetings.")
                        Spacer()
                        Button("Enable Calendar Alerts") {
                            Task { await calendarMonitor.requestAccess() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
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
                await recorder.stop()
                endedAt = Date()
            } else {
                if clearCalendarRecipients {
                    calendarEmailRecipients = []
                }
                report = ""
                entries = []
                startedAt = Date()
                endedAt = nil
                try await recorder.start(folderTitle: title)
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

        guard autoRecordCalendarMeetings else {
            await stopAutomaticRecording(status: "Calendar auto-record turned off — recording saved locally")
            return
        }

        if let autoRecordedMeetingID, autoRecordedMeetingID != activeMeeting?.id {
            await stopAutomaticRecording(status: "Calendar meeting ended — recording saved locally")
        }

        guard let activeMeeting,
              !skippedAutoMeetingIDs.contains(activeMeeting.id),
              autoRecordedMeetingID == nil,
              !recorder.isRecording,
              !isProcessing else { return }

        title = activeMeeting.title
        attendees = activeMeeting.attendeeNames.joined(separator: ", ")
        calendarEmailRecipients = activeMeeting.emailRecipients
        report = ""
        entries = []
        startedAt = Date()
        endedAt = nil
        errorMessage = nil

        do {
            try await recorder.start(folderTitle: activeMeeting.title)
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
            await recorder.stop()
            endedAt = Date()
            recorder.status = status
        }
        autoRecordedMeetingID = nil
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

    private func buildTranscript() async {
        guard let mic = recorder.microphoneURL,
              let system = recorder.systemAudioURL,
              let start = startedAt else { return }

        errorMessage = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            try await scribe.requestAuthorization()
            var transcriptionErrors: [Error] = []

            recorder.status = "Transcribing microphone audio..."
            let micEntries: [ScribeEntry]
            do {
                micEntries = try await scribe.transcribeFileAllowingSilence(
                    mic,
                    source: .microphone,
                    meetingStart: start
                )
            } catch {
                micEntries = []
                transcriptionErrors.append(error)
            }

            recorder.status = "Transcribing system audio..."
            let systemEntries: [ScribeEntry]
            do {
                systemEntries = try await scribe.transcribeFileAllowingSilence(
                    system,
                    source: .systemAudio,
                    meetingStart: start
                )
            } catch {
                systemEntries = []
                transcriptionErrors.append(error)
            }

            let spoken = scribe.mergeSpokenEntries(
                microphone: micEntries,
                systemAudio: systemEntries
            )
            if spoken.isEmpty && entries.isEmpty {
                throw transcriptionErrors.first ?? LocalScribeError.noSpeechDetected
            }
            let allEntries = (entries + spoken).sorted { $0.timestamp < $1.timestamp }
            entries = allEntries

            let names = attendees.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let built = scribe.buildTranscript(
                title: title,
                startedAt: start,
                endedAt: endedAt ?? Date(),
                attendees: names,
                entries: allEntries
            )
            report = built
            try save(report: built, entries: allEntries)
            recorder.status = transcriptionErrors.isEmpty
                ? "Transcript saved — ready for ChatGPT"
                : "Transcript saved from the available audio track — ready for ChatGPT"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(report: String, entries: [ScribeEntry]) throws {
        guard let folder = recorder.sessionDirectory else { return }
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
