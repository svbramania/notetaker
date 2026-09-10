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

final class SignOffPhraseDetectorTests: XCTestCase {
    func testRecognizesByeAtEndOfSpeech() {
        XCTAssertEqual(
            SignOffPhraseDetector.matchingPhrase(in: "Thanks for the update. Bye!"),
            "bye"
        )
    }

    func testRecognizesCommonMeetingClosingPhrase() {
        XCTAssertEqual(
            SignOffPhraseDetector.matchingPhrase(in: "That covers everything. Thank you, everyone."),
            "thank you everyone"
        )
    }

    func testDoesNotStopWhenGoodbyeIsFollowedByMoreDiscussion() {
        XCTAssertNil(
            SignOffPhraseDetector.matchingPhrase(
                in: "Before we say goodbye, we need to discuss one more topic."
            )
        )
    }

    func testDoesNotTreatBuyAsBye() {
        XCTAssertNil(SignOffPhraseDetector.matchingPhrase(in: "We should buy the annual plan."))
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

final class CalendarMeetingEligibilityTests: XCTestCase {
    func testSupportedMeetingLinkIsIncludedByDefault() {
        XCTAssertTrue(
            CalendarMeetingEligibility.shouldInclude(
                hasSupportedMeetingLink: true,
                includeInvitesWithoutLinks: false,
                hasAttendees: false
            )
        )
    }

    func testInviteWithoutLinkIsExcludedByDefault() {
        XCTAssertFalse(
            CalendarMeetingEligibility.shouldInclude(
                hasSupportedMeetingLink: false,
                includeInvitesWithoutLinks: false,
                hasAttendees: true
            )
        )
    }

    func testInviteWithoutLinkCanBeIncluded() {
        XCTAssertTrue(
            CalendarMeetingEligibility.shouldInclude(
                hasSupportedMeetingLink: false,
                includeInvitesWithoutLinks: true,
                hasAttendees: true
            )
        )
    }

    func testPersonalBlockWithoutAttendeesRemainsExcluded() {
        XCTAssertFalse(
            CalendarMeetingEligibility.shouldInclude(
                hasSupportedMeetingLink: false,
                includeInvitesWithoutLinks: true,
                hasAttendees: false
            )
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
            ##"{"output":[{"content":[{"type":"output_text","text":"# Meeting Notes\nSummary"}]}]}"##.utf8
        )

        XCTAssertEqual(
            try MeetingNotesService.parseOpenAIResponse(data),
            "# Meeting Notes\nSummary"
        )
    }

    func testParsesClaudeResponseText() throws {
        let data = Data(
            ##"{"content":[{"type":"text","text":"# Meeting Notes\nSummary"}]}"##.utf8
        )

        XCTAssertEqual(
            try MeetingNotesService.parseClaudeResponse(data),
            "# Meeting Notes\nSummary"
        )
    }

    func testMeetingNotesPromptIncludesRequiredSections() {
        XCTAssertTrue(MeetingNotesService.instructions.contains("EXECUTIVE SUMMARY"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("DECISIONS MADE"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("ACTION ITEMS"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Owner"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Due Date"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("FINANCIAL TERMS AND AMOUNTS"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("every mention of money"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Pyramid Principle"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Remove any hashtags and fix the formatting"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Do not use Markdown heading symbols"))
    }

    func testCapturesMoneyWithSessionContext() {
        let transcript = "[10:04] System: The total is $1800 for 6 sessions."

        XCTAssertEqual(
            FinancialMentionExtractor.evidenceLines(in: transcript),
            ["[10:04] System: The total is $1800 for 6 sessions."]
        )
    }

    func testCapturesMultipleCurrencyFormats() {
        let transcript = """
        Budget approved: USD 1,800.
        Deposit: 150 dollars.
        Local cost: ₹2500.
        """

        XCTAssertEqual(FinancialMentionExtractor.evidenceLines(in: transcript).count, 3)
    }

    func testCapturesSpokenMoneyAndFinancialTerms() {
        let transcript = """
        The price is eighteen hundred dollars for six sessions.
        A deposit is due next week.
        """

        XCTAssertEqual(FinancialMentionExtractor.evidenceLines(in: transcript).count, 2)
    }

    func testSessionCountAloneIsNotClassifiedAsMoney() {
        XCTAssertTrue(
            FinancialMentionExtractor.evidenceLines(in: "We agreed to 6 sessions.").isEmpty
        )
    }

    func testFinancialEvidenceIsAddedToGeneratedNotes() {
        let notes = """
        # Meeting Notes
        ## Financial Terms and Amounts
        Pricing was discussed.
        ## Key Discussion Points
        Delivery schedule
        """
        let verified = FinancialMentionExtractor.ensuringEvidence(
            in: notes,
            from: "[10:04] System: The total is $1800 for 6 sessions."
        )

        XCTAssertTrue(verified.contains("Transcript evidence: [10:04] System: The total is $1800 for 6 sessions."))
    }

    func testFinancialEvidenceSectionIsAddedWhenProviderOmitsIt() {
        let verified = FinancialMentionExtractor.ensuringEvidence(
            in: "# Meeting Notes\n## Executive Summary\nAgreement reached.",
            from: "The total is $1800 for 6 sessions."
        )

        XCTAssertTrue(verified.contains("FINANCIAL TERMS AND AMOUNTS"))
        XCTAssertTrue(verified.contains("$1800 for 6 sessions"))
    }

    func testNoKeyChatGPTPromptProtectsFinancialEvidence() {
        let prompt = LocalScribe().chatGPTPrompt(
            for: "[10:04] System: The total is $1800 for 6 sessions."
        )

        XCTAssertTrue(prompt.contains("FINANCIAL TERMS AND AMOUNTS"))
        XCTAssertTrue(prompt.contains("$1800 for 6 sessions"))
        XCTAssertTrue(prompt.contains("REQUIRED FINANCIAL EVIDENCE"))
        XCTAssertTrue(prompt.contains("Remove any hashtags and fix the formatting"))
    }

    func testFormatterRemovesMarkdownHeadingHashesAndBoldMarkers() {
        let formatted = MeetingNotesFormatter.finalize(
            "# MEETING NOTES\n## EXECUTIVE SUMMARY\n**Agreement reached.**",
            transcript: "Agreement reached."
        )

        XCTAssertFalse(formatted.contains("#"))
        XCTAssertFalse(formatted.contains("**"))
        XCTAssertTrue(formatted.contains("EXECUTIVE SUMMARY\nAgreement reached."))
    }

    func testFormatterPlacesTranscriptNumbersAtTheBeginning() {
        let formatted = MeetingNotesFormatter.finalize(
            "EXECUTIVE SUMMARY\nAgreement reached.",
            transcript: "[10:04:22] System: The total is $1800 for 6 sessions."
        )

        XCTAssertTrue(
            formatted.hasPrefix(
                "KEY NUMBERS\n• The total is $1800 for 6 sessions."
            )
        )
    }

    func testNumericEvidenceIgnoresTimestampButKeepsContentNumbers() {
        XCTAssertEqual(
            NumericMentionExtractor.evidenceLines(
                in: "- [10:04:22] **System:** The total is $1800 for 6 sessions."
            ),
            ["The total is $1800 for 6 sessions."]
        )
    }

    func testOnlyLastIndividuallySelectedRecipientIsPreselected() {
        let recipients = [
            MeetingEmailRecipient(name: "One", email: "one@example.com"),
            MeetingEmailRecipient(name: "Two", email: "two@example.com")
        ]

        XCTAssertEqual(
            RecipientSelectionPolicy.initialSelection(
                from: recipients,
                lastSelectedEmail: "TWO@example.com"
            ),
            ["two@example.com"]
        )
        XCTAssertTrue(
            RecipientSelectionPolicy.initialSelection(
                from: recipients,
                lastSelectedEmail: ""
            ).isEmpty
        )
    }

    func testMailAndGmailDraftURLsContainMessageDetails() throws {
        let draft = MeetingEmailDraft(
            recipients: ["one@example.com", "two@example.com"],
            subject: "Meeting notes: Pricing",
            body: "KEY NUMBERS\n• $1800 for 6 sessions"
        )
        let mailURL = try XCTUnwrap(
            MeetingEmailDraftURLBuilder.url(for: draft, client: .appleMail)
        )
        let mailComponents = try XCTUnwrap(URLComponents(url: mailURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(mailComponents.scheme, "mailto")
        XCTAssertEqual(mailComponents.path, "one@example.com,two@example.com")
        XCTAssertEqual(
            mailComponents.queryItems?.first(where: { $0.name == "subject" })?.value,
            draft.subject
        )

        let gmailURL = try XCTUnwrap(
            MeetingEmailDraftURLBuilder.url(for: draft, client: .gmail)
        )
        let gmailComponents = try XCTUnwrap(URLComponents(url: gmailURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(gmailComponents.host, "mail.google.com")
        XCTAssertEqual(
            gmailComponents.queryItems?.first(where: { $0.name == "to" })?.value,
            "one@example.com,two@example.com"
        )
        XCTAssertEqual(
            gmailComponents.queryItems?.first(where: { $0.name == "body" })?.value,
            draft.body
        )
    }

    func testRecognizesOpenAICreditLimit() {
        XCTAssertTrue(
            MeetingNotesService.isQuotaOrCreditLimit(
                statusCode: 429,
                errorType: "insufficient_quota",
                errorCode: "credit_balance_exhausted",
                message: "Your credit balance is exhausted.",
                retryAfter: nil,
                provider: .openAI
            )
        )
    }

    func testRecognizesClaudeSpendCapWithoutRetryAfter() {
        XCTAssertTrue(
            MeetingNotesService.isQuotaOrCreditLimit(
                statusCode: 429,
                errorType: "rate_limit_error",
                errorCode: nil,
                message: "Monthly spend cap reached.",
                retryAfter: nil,
                provider: .claude
            )
        )
    }

    func testTemporaryRateLimitDoesNotTriggerProviderFallback() {
        XCTAssertFalse(
            MeetingNotesService.isQuotaOrCreditLimit(
                statusCode: 429,
                errorType: "rate_limit_error",
                errorCode: nil,
                message: "Rate limit reached.",
                retryAfter: "15",
                provider: .claude
            )
        )
    }

    func testFallbackPolicyRequiresOptInQuotaErrorAndNextProvider() {
        let quotaError = MeetingNotesServiceError.quotaExceeded("Limit reached")
        XCTAssertTrue(
            APIFallbackPolicy.shouldTryNext(
                after: quotaError,
                automaticFallbackEnabled: true,
                hasNextProvider: true
            )
        )
        XCTAssertFalse(
            APIFallbackPolicy.shouldTryNext(
                after: quotaError,
                automaticFallbackEnabled: false,
                hasNextProvider: true
            )
        )
        XCTAssertFalse(
            APIFallbackPolicy.shouldTryNext(
                after: MeetingNotesServiceError.provider("Invalid model"),
                automaticFallbackEnabled: true,
                hasNextProvider: true
            )
        )
    }

    func testProviderConfigurationsPreserveUserOrder() throws {
        let first = APIProviderConfiguration(
            provider: .claude,
            label: "Primary",
            model: "claude-sonnet-5"
        )
        let second = APIProviderConfiguration(
            provider: .openAI,
            label: "Backup",
            model: "gpt-6-astra"
        )
        let data = try JSONEncoder().encode([first, second])
        let restored = try JSONDecoder().decode([APIProviderConfiguration].self, from: data)

        XCTAssertEqual(restored, [first, second])
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
