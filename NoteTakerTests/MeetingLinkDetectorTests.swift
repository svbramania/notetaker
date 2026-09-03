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
