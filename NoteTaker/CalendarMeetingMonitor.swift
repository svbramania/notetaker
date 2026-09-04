import AppKit
import Combine
import EventKit
import Foundation
import UserNotifications

enum MeetingProvider: String, Codable, CaseIterable {
    case microsoftTeams = "Microsoft Teams"
    case googleMeet = "Google Meet"
    case zoom = "Zoom"

    var systemImage: String {
        switch self {
        case .microsoftTeams:
            return "person.2.wave.2"
        case .googleMeet:
            return "video"
        case .zoom:
            return "video.circle"
        }
    }
}

struct UpcomingVideoMeeting: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let provider: MeetingProvider
    let meetingURL: URL?
    let attendeeNames: [String]
}

struct AvailableMeetingCalendar: Identifiable, Equatable {
    let id: String
    let title: String
    let accountIdentifier: String
    let accountName: String
    let providerName: String
}

struct MeetingCalendarAccount: Identifiable, Equatable {
    let id: String
    let name: String
    let providerName: String
    let calendars: [AvailableMeetingCalendar]
}

enum CalendarSelectionPolicy {
    static func includedIdentifiers(
        available: Set<String>,
        excluded: Set<String>
    ) -> Set<String> {
        available.subtracting(excluded)
    }
}

enum CalendarAccountProvider {
    static func name(sourceTitle: String, sourceType: EKSourceType) -> String {
        let normalized = sourceTitle.lowercased()
        if normalized.contains("google") || normalized.contains("gmail") {
            return "Google"
        }
        if normalized.contains("outlook")
            || normalized.contains("office 365")
            || normalized.contains("microsoft") {
            return "Microsoft"
        }

        switch sourceType {
        case .exchange:
            return "Microsoft Exchange"
        case .mobileMe:
            return "iCloud"
        case .calDAV:
            return "CalDAV"
        case .local:
            return "On My Mac"
        case .subscribed:
            return "Subscribed"
        case .birthdays:
            return "Birthdays"
        @unknown default:
            return "Calendar"
        }
    }
}

enum CalendarMeetingTimeline {
    static func activeMeeting(
        in meetings: [UpcomingVideoMeeting],
        at date: Date
    ) -> UpcomingVideoMeeting? {
        meetings
            .filter { $0.startDate <= date && $0.endDate > date }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    static func nextMeeting(
        in meetings: [UpcomingVideoMeeting],
        after date: Date
    ) -> UpcomingVideoMeeting? {
        meetings
            .filter { $0.startDate > date }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    static func nextBoundary(
        in meetings: [UpcomingVideoMeeting],
        after date: Date
    ) -> Date? {
        meetings
            .flatMap { [$0.startDate, $0.endDate] }
            .filter { $0 > date }
            .min()
    }
}

enum MeetingLinkDetector {
    static func detect(in text: String) -> (provider: MeetingProvider, url: URL?)? {
        let candidates = detectedURLs(in: text)

        for candidate in candidates {
            if let provider = provider(for: candidate.absoluteString) {
                return (provider, candidate)
            }
        }

        guard let provider = provider(for: text) else { return nil }
        return (provider, nil)
    }

    static func provider(for text: String) -> MeetingProvider? {
        let normalized = text.lowercased()

        if normalized.contains("teams.microsoft.com")
            || normalized.contains("teams.live.com")
            || normalized.contains("teams.cloud.microsoft")
            || normalized.contains("teams.microsoft.us")
            || normalized.contains("msteams:") {
            return .microsoftTeams
        }

        if normalized.contains("meet.google.com") {
            return .googleMeet
        }

        if normalized.contains("zoommtg:")
            || normalized.range(
                of: #"(?:^|[./])(?:[a-z0-9-]+\.)?zoom\.(?:us|com)(?:[/\s]|$)"#,
                options: .regularExpression
            ) != nil {
            return .zoom
        }

        return nil
    }

    private static func detectedURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }
}

@MainActor
final class CalendarMeetingMonitor: NSObject, ObservableObject {
    @Published private(set) var calendarAccessGranted = false
    @Published private(set) var notificationAccessGranted = false
    @Published private(set) var nextMeeting: UpcomingVideoMeeting?
    @Published private(set) var activeMeeting: UpcomingVideoMeeting?
    @Published private(set) var meetingToPrompt: UpcomingVideoMeeting?
    @Published private(set) var availableCalendars: [AvailableMeetingCalendar] = []
    @Published private(set) var status = "Calendar alerts are not enabled"

    static let notificationLeadTime: TimeInterval = 5 * 60

    private let eventStore = EKEventStore()
    private let notificationCenter = UNUserNotificationCenter.current()
    private var refreshTask: Task<Void, Never>?
    private var dismissedPromptIDs: Set<String> = []
    private var nextCalendarBoundary: Date?
    private var excludedCalendarIdentifiers = Set(
        UserDefaults.standard.stringArray(forKey: "excludedMeetingCalendarIdentifiers") ?? []
    )

    var calendarAccounts: [MeetingCalendarAccount] {
        Dictionary(grouping: availableCalendars, by: \.accountIdentifier)
            .map { identifier, calendars in
                MeetingCalendarAccount(
                    id: identifier,
                    name: calendars.first?.accountName ?? "Calendar Account",
                    providerName: calendars.first?.providerName ?? "Calendar",
                    calendars: calendars.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                )
            }
            .sorted {
                let providerComparison = $0.providerName.localizedCaseInsensitiveCompare($1.providerName)
                return providerComparison == .orderedSame
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : providerComparison == .orderedAscending
            }
    }

    var includedCalendarCount: Int {
        includedCalendarIdentifiers.count
    }

    private var includedCalendarIdentifiers: Set<String> {
        CalendarSelectionPolicy.includedIdentifiers(
            available: Set(availableCalendars.map(\.id)),
            excluded: excludedCalendarIdentifiers
        )
    }

    override init() {
        super.init()
        notificationCenter.delegate = self
        registerNotificationActions()
    }

    deinit {
        refreshTask?.cancel()
    }

    func start() {
        guard refreshTask == nil else { return }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let delay = self.refreshDelay(after: Date())
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
            }
        }
    }

    func requestAccess() async {
        status = "Requesting Calendar and notification access..."

        do {
            calendarAccessGranted = try await requestCalendarAccess()
            notificationAccessGranted = try await requestNotificationAccess()
            await refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func requestNotificationPermission() async {
        do {
            notificationAccessGranted = try await requestNotificationAccess()
            status = notificationAccessGranted
                ? "Notifications enabled"
                : "Enable NoteTaker notifications in System Settings"
            await refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func refresh() async {
        updateAuthorizationState()

        guard calendarAccessGranted else {
            nextMeeting = nil
            activeMeeting = nil
            meetingToPrompt = nil
            availableCalendars = []
            nextCalendarBoundary = nil
            status = "Enable Calendar access to detect video meetings"
            return
        }

        refreshAvailableCalendars()
        let now = Date()
        let meetings = videoMeetings(
            from: now.addingTimeInterval(-(24 * 60 * 60)),
            through: now.addingTimeInterval(24 * 60 * 60)
        )
        .filter { $0.endDate > now }
        dismissedPromptIDs.formIntersection(Set(meetings.map(\.id)))
        activeMeeting = CalendarMeetingTimeline.activeMeeting(in: meetings, at: now)
        nextMeeting = CalendarMeetingTimeline.nextMeeting(in: meetings, after: now)
        nextCalendarBoundary = CalendarMeetingTimeline.nextBoundary(in: meetings, after: now)
        meetingToPrompt = meetings.first { meeting in
            let secondsUntilStart = meeting.startDate.timeIntervalSince(now)
            return !dismissedPromptIDs.contains(meeting.id)
                && secondsUntilStart <= Self.notificationLeadTime
                && secondsUntilStart >= -(15 * 60)
        }

        if notificationAccessGranted {
            await scheduleNotifications(for: meetings, now: now)
            status = includedCalendarCount == 0
                ? "Choose one or more calendars to monitor"
                : activeMeeting != nil
                ? "Calendar meeting in progress"
                : meetings.isEmpty
                ? "Watching \(includedCalendarCount) calendars for Teams, Zoom, and Google Meet"
                : "Meeting alert scheduled"
        } else {
            status = includedCalendarCount == 0
                ? "Choose one or more calendars to monitor"
                : "Calendar connected — enable notifications for meeting alerts"
        }
    }

    func dismissPrompt() {
        if let meetingToPrompt {
            dismissedPromptIDs.insert(meetingToPrompt.id)
        }
        meetingToPrompt = nil
    }

    func isCalendarIncluded(_ identifier: String) -> Bool {
        !excludedCalendarIdentifiers.contains(identifier)
    }

    func setCalendarIncluded(_ identifier: String, included: Bool) {
        if included {
            excludedCalendarIdentifiers.remove(identifier)
        } else {
            excludedCalendarIdentifiers.insert(identifier)
        }
        saveCalendarSelection()
        Task { await refresh() }
    }

    func selectAllCalendars() {
        excludedCalendarIdentifiers.subtract(availableCalendars.map(\.id))
        saveCalendarSelection()
        Task { await refresh() }
    }

    func clearCalendarSelection() {
        excludedCalendarIdentifiers.formUnion(availableCalendars.map(\.id))
        saveCalendarSelection()
        Task { await refresh() }
    }

    private func refreshDelay(after date: Date) -> TimeInterval {
        guard let nextCalendarBoundary else { return 60 }
        return min(60, max(0.25, nextCalendarBoundary.timeIntervalSince(date) + 0.1))
    }

    private func refreshAvailableCalendars() {
        availableCalendars = eventStore.calendars(for: .event)
            .map { calendar in
                let source = calendar.source
                return AvailableMeetingCalendar(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    accountIdentifier: source.sourceIdentifier,
                    accountName: source.title,
                    providerName: CalendarAccountProvider.name(
                        sourceTitle: source.title,
                        sourceType: source.sourceType
                    )
                )
            }
    }

    private func saveCalendarSelection() {
        UserDefaults.standard.set(
            Array(excludedCalendarIdentifiers).sorted(),
            forKey: "excludedMeetingCalendarIdentifiers"
        )
    }

    private func requestCalendarAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func requestNotificationAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func updateAuthorizationState() {
        let calendarStatus = EKEventStore.authorizationStatus(for: .event)
        calendarAccessGranted = calendarStatus == .fullAccess || calendarStatus == .authorized

        notificationCenter.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.notificationAccessGranted = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
            }
        }
    }

    private func videoMeetings(from start: Date, through end: Date) -> [UpcomingVideoMeeting] {
        let includedIdentifiers = includedCalendarIdentifiers
        let calendars = eventStore.calendars(for: .event).filter {
            includedIdentifiers.contains($0.calendarIdentifier)
        }
        guard !calendars.isEmpty else { return [] }

        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendars
        )

        return eventStore.events(matching: predicate)
            .compactMap(makeUpcomingMeeting)
            .sorted { $0.startDate < $1.startDate }
    }

    private func makeUpcomingMeeting(from event: EKEvent) -> UpcomingVideoMeeting? {
        guard !event.isAllDay else { return nil }

        let searchableText = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }
            .joined(separator: "\n")

        guard let detection = MeetingLinkDetector.detect(in: searchableText) else { return nil }

        let attendees = (event.attendees ?? []).compactMap { participant in
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        }

        return UpcomingVideoMeeting(
            id: event.eventIdentifier ?? "\(event.startDate.timeIntervalSince1970)-\(event.title ?? "Meeting")",
            title: event.title?.isEmpty == false ? event.title : "Video meeting",
            startDate: event.startDate,
            endDate: event.endDate,
            provider: detection.provider,
            meetingURL: detection.url ?? event.url,
            attendeeNames: attendees
        )
    }

    private func registerNotificationActions() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_NOTETAKER",
            title: "Open NoteTaker",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "UPCOMING_VIDEO_MEETING",
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        notificationCenter.setNotificationCategories([category])
    }

    private func scheduleNotifications(for meetings: [UpcomingVideoMeeting], now: Date) async {
        let notificationPrefix = "video-meeting-"
        let validIdentifiers = Set(meetings.map { notificationPrefix + $0.id })
        let pending = await pendingNotificationRequests()
        let obsolete = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(notificationPrefix) && !validIdentifiers.contains($0) }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: obsolete)

        for meeting in meetings {
            let notificationDate = meeting.startDate.addingTimeInterval(-Self.notificationLeadTime)
            guard notificationDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Meeting starts soon—record?"
            content.body = "\(meeting.title) starts in 5 minutes on \(meeting.provider.rawValue)."
            content.sound = .default
            content.categoryIdentifier = "UPCOMING_VIDEO_MEETING"
            content.userInfo = ["eventIdentifier": meeting.id]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: notificationDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: notificationPrefix + meeting.id,
                content: content,
                trigger: trigger
            )
            await addNotificationRequest(request)
        }
    }

    private func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            notificationCenter.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private func addNotificationRequest(_ request: UNNotificationRequest) async {
        await withCheckedContinuation { continuation in
            notificationCenter.add(request) { _ in
                continuation.resume()
            }
        }
    }
}

extension CalendarMeetingMonitor: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        Task { @MainActor [weak self] in
            await self?.refresh()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
