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
    @Published private(set) var meetingToPrompt: UpcomingVideoMeeting?
    @Published private(set) var status = "Calendar alerts are not enabled"

    static let notificationLeadTime: TimeInterval = 5 * 60

    private let eventStore = EKEventStore()
    private let notificationCenter = UNUserNotificationCenter.current()
    private var refreshTask: Task<Void, Never>?
    private var dismissedPromptIDs: Set<String> = []

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
                try? await Task.sleep(for: .seconds(60))
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
            meetingToPrompt = nil
            status = "Enable Calendar access to detect video meetings"
            return
        }

        let now = Date()
        let meetings = videoMeetings(from: now, through: now.addingTimeInterval(24 * 60 * 60))
        dismissedPromptIDs.formIntersection(Set(meetings.map(\.id)))
        nextMeeting = meetings.first
        meetingToPrompt = meetings.first { meeting in
            let secondsUntilStart = meeting.startDate.timeIntervalSince(now)
            return !dismissedPromptIDs.contains(meeting.id)
                && secondsUntilStart <= Self.notificationLeadTime
                && secondsUntilStart >= -(15 * 60)
        }

        if notificationAccessGranted {
            await scheduleNotifications(for: meetings, now: now)
            status = meetings.isEmpty
                ? "Watching Calendar for Teams, Zoom, and Google Meet"
                : "Meeting alert scheduled"
        } else {
            status = "Calendar connected — enable notifications for meeting alerts"
        }
    }

    func dismissPrompt() {
        if let meetingToPrompt {
            dismissedPromptIDs.insert(meetingToPrompt.id)
        }
        meetingToPrompt = nil
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
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)

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
