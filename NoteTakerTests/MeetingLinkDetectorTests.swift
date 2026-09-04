import EventKit
import XCTest
@testable import NoteTaker

final class MeetingLinkDetectorTests: XCTestCase {
    func testDetectsMicrosoftTeamsMeeting() {
        let result = MeetingLinkDetector.detect(
            in: "Join https://teams.microsoft.com/l/meetup-join/19%3ameeting_example"
        )
        XCTAssertEqual(result?.provider, .microsoftTeams)
    }

    func testDetectsNewMicrosoftTeamsMeetingHost() {
        let result = MeetingLinkDetector.detect(
            in: "Join https://teams.cloud.microsoft/meet/123456789"
        )
        XCTAssertEqual(result?.provider, .microsoftTeams)
    }

    func testDetectsGoogleMeetMeeting() {
        let result = MeetingLinkDetector.detect(in: "Video call: https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(result?.provider, .googleMeet)
    }

    func testDetectsBrandedZoomMeeting() {
        let result = MeetingLinkDetector.detect(in: "https://company.zoom.us/j/123456789")
        XCTAssertEqual(result?.provider, .zoom)
    }

    func testIgnoresUnrelatedCalendarEvent() {
        XCTAssertNil(MeetingLinkDetector.detect(in: "Lunch at the office"))
    }
}

final class CalendarMeetingTimelineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testFindsMeetingInProgress() {
        let active = meeting(id: "active", startsIn: -60, endsIn: 120)
        let future = meeting(id: "future", startsIn: 300, endsIn: 600)

        XCTAssertEqual(
            CalendarMeetingTimeline.activeMeeting(in: [future, active], at: now),
            active
        )
    }

    func testMeetingIsNotActiveAtItsEndTime() {
        let ended = meeting(id: "ended", startsIn: -60, endsIn: 0)

        XCTAssertNil(CalendarMeetingTimeline.activeMeeting(in: [ended], at: now))
    }

    func testFindsNextStartOrEndBoundary() {
        let active = meeting(id: "active", startsIn: -60, endsIn: 120)
        let future = meeting(id: "future", startsIn: 60, endsIn: 600)

        XCTAssertEqual(
            CalendarMeetingTimeline.nextBoundary(in: [active, future], after: now),
            future.startDate
        )
    }

    func testFindsNextFutureMeeting() {
        let active = meeting(id: "active", startsIn: -60, endsIn: 120)
        let future = meeting(id: "future", startsIn: 60, endsIn: 600)

        XCTAssertEqual(
            CalendarMeetingTimeline.nextMeeting(in: [future, active], after: now),
            future
        )
    }

    private func meeting(
        id: String,
        startsIn startOffset: TimeInterval,
        endsIn endOffset: TimeInterval
    ) -> UpcomingVideoMeeting {
        UpcomingVideoMeeting(
            id: id,
            title: id,
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(endOffset),
            provider: .zoom,
            meetingURL: nil,
            attendeeNames: [],
            emailRecipients: []
        )
    }
}

final class CalendarSelectionPolicyTests: XCTestCase {
    func testIncludesEveryCalendarByDefault() {
        let available: Set<String> = ["gmail-personal", "gmail-work", "outlook-client"]

        XCTAssertEqual(
            CalendarSelectionPolicy.includedIdentifiers(available: available, excluded: []),
            available
        )
    }

    func testExcludesOnlyCalendarsTheUserTurnsOff() {
        XCTAssertEqual(
            CalendarSelectionPolicy.includedIdentifiers(
                available: ["gmail-personal", "gmail-work", "outlook-client"],
                excluded: ["gmail-personal"]
            ),
            ["gmail-work", "outlook-client"]
        )
    }

    func testNewCalendarsAreAutomaticallyIncluded() {
        let included = CalendarSelectionPolicy.includedIdentifiers(
            available: ["existing", "new-calendar"],
            excluded: ["existing"]
        )

        XCTAssertEqual(included, ["new-calendar"])
    }

    func testRecognizesGoogleAndMicrosoftAccountLabels() {
        XCTAssertEqual(
            CalendarAccountProvider.name(sourceTitle: "suraj@gmail.com", sourceType: .calDAV),
            "Google"
        )
        XCTAssertEqual(
            CalendarAccountProvider.name(sourceTitle: "Work", sourceType: .exchange),
            "Microsoft Exchange"
        )
    }
}

final class RecordingFolderNamerTests: XCTestCase {
    func testUsesCalendarTitleAndTimestamp() {
        let date = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(
            RecordingFolderNamer.folderName(for: "Quarterly Planning", at: date),
            "Quarterly Planning - 1970-01-01T00-00-00.000Z"
        )
    }

    func testRemovesUnsafeFolderCharacters() {
        XCTAssertEqual(
            RecordingFolderNamer.sanitizedTitle("  Product / Design: Review\n"),
            "Product - Design - Review"
        )
    }

    func testUsesMeetingForBlankTitle() {
        XCTAssertEqual(RecordingFolderNamer.sanitizedTitle("  / :  "), "Meeting")
    }
}

final class MeetingNotesServiceTests: XCTestCase {
    func testExtractsAndDeduplicatesEmailAddresses() {
        XCTAssertEqual(
            EmailAddressExtractor.addresses(
                in: "mailto:Person%40Example.com, person@example.com, second@example.org"
            ),
            ["person@example.com", "second@example.org"]
        )
    }

    func testParsesOpenAIResponseText() throws {
        let data = Data(
            #"{"output":[{"content":[{"type":"output_text","text":"# Meeting Notes\nSummary"}]}]}"#.utf8
        )

        XCTAssertEqual(
            try MeetingNotesService.parseOpenAIResponse(data),
            "# Meeting Notes\nSummary"
        )
    }

    func testParsesClaudeResponseText() throws {
        let data = Data(
            #"{"content":[{"type":"text","text":"# Meeting Notes\nSummary"}]}"#.utf8
        )

        XCTAssertEqual(
            try MeetingNotesService.parseClaudeResponse(data),
            "# Meeting Notes\nSummary"
        )
    }

    func testMeetingNotesPromptIncludesRequiredSections() {
        XCTAssertTrue(MeetingNotesService.instructions.contains("Executive Summary"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Decisions Made"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Action Items"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Owner"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Due Date"))
    }
}

final class LocalScribeMergeTests: XCTestCase {
    func testRemovesSameSpeechCapturedByBothTracks() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let microphone = ScribeEntry(
            timestamp: timestamp,
            source: .microphone,
            text: "The system is data ready but it is not AI ready"
        )
        let system = ScribeEntry(
            timestamp: timestamp.addingTimeInterval(0.2),
            source: .systemAudio,
            text: "The system is data ready, but it is not AI ready."
        )

        let merged = LocalScribe().mergeSpokenEntries(
            microphone: [microphone],
            systemAudio: [system]
        )

        XCTAssertEqual(merged, [system])
    }

    func testKeepsDistinctSpeechFromMicrophoneAndSystemAudio() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let microphone = ScribeEntry(
            timestamp: timestamp,
            source: .microphone,
            text: "I will prepare the market analysis"
        )
        let system = ScribeEntry(
            timestamp: timestamp.addingTimeInterval(0.2),
            source: .systemAudio,
            text: "The device sends data through HL7"
        )

        let merged = LocalScribe().mergeSpokenEntries(
            microphone: [microphone],
            systemAudio: [system]
        )

        XCTAssertEqual(merged.count, 2)
    }
}
