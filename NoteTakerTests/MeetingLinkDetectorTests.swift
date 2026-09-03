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
            attendeeNames: []
        )
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
