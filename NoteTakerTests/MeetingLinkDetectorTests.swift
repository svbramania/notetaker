import AppKit
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

    func testMeetingReminderAppearsTwoMinutesBeforeStart() {
        XCTAssertEqual(CalendarMeetingMonitor.notificationLeadTime, 2 * 60)
    }

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

    func testCurrentOrNextMeetingSkipsCompletedActiveMeeting() {
        let completed = meeting(id: "completed", startsIn: -60, endsIn: 120)
        let future = meeting(id: "future", startsIn: 60, endsIn: 600)

        XCTAssertEqual(
            CalendarMeetingTimeline.currentOrNextMeeting(
                after: completed.id,
                activeMeeting: completed,
                nextMeeting: future
            ),
            future
        )
    }

    func testCurrentOrNextMeetingUsesNewBackToBackActiveMeeting() {
        let newActive = meeting(id: "new-active", startsIn: 0, endsIn: 300)

        XCTAssertEqual(
            CalendarMeetingTimeline.currentOrNextMeeting(
                after: "completed",
                activeMeeting: newActive,
                nextMeeting: nil
            ),
            newActive
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

final class SavedMeetingSessionTests: XCTestCase {
    func testSavedMeetingsAreSortedNewestFirst() {
        let older = SavedMeetingSession(
            directoryURL: URL(fileURLWithPath: "/tmp/Older - 2026-01-01T10-00-00.000Z"),
            title: "Older",
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            hasMicrophoneAudio: true,
            hasSystemAudio: true
        )
        let newer = SavedMeetingSession(
            directoryURL: URL(fileURLWithPath: "/tmp/Newer - 2026-01-02T10-00-00.000Z"),
            title: "Newer",
            startedAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 400),
            hasMicrophoneAudio: true,
            hasSystemAudio: false
        )

        XCTAssertEqual(
            SavedMeetingSession.sortedNewestFirst([older, newer]).map(\.title),
            ["Newer", "Older"]
        )
    }

    func testDiscoversRecordingFolderAndExtractsCalendarTitle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteTakerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = root.appendingPathComponent(
            "Client Planning - 2026-09-18T10-30-00.000Z",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: meeting.appendingPathComponent("microphone.m4a"))

        let sessions = SavedMeetingSession.discover(in: root)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Client Planning")
        XCTAssertEqual(sessions.first?.hasMicrophoneAudio, true)
        XCTAssertEqual(sessions.first?.hasSystemAudio, false)
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

    func testClaudeAuthenticationIncludesOptionalWorkspaceHeader() {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        MeetingNotesService.applyClaudeAuthentication(
            to: &request,
            apiKey: "test-key",
            workspaceID: "  wrkspc_test  "
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-workspace-id"), "wrkspc_test")
    }

    func testClaudeAuthenticationOmitsBlankWorkspaceHeader() {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        MeetingNotesService.applyClaudeAuthentication(
            to: &request,
            apiKey: "test-key",
            workspaceID: "   "
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-workspace-id"))
    }

    func testMeetingNotesPromptIncludesRequiredSections() {
        XCTAssertTrue(MeetingNotesService.instructions.contains("EXECUTIVE SUMMARY"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("DECISIONS MADE"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("ACTION ITEMS"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Owner"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Due Date"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("FINANCIAL TERMS AND AMOUNTS"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("monetary amount"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Pyramid Principle"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Remove any hashtags and fix the formatting"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Do not use Markdown heading symbols"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Unicode bullet"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("treat the name as the addressee"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("without naming a speaker"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Never mention speaker-attribution uncertainty"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Never comment on the transcript itself"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("omit that section entirely"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Keep this executive summary concise"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("two to four complete sentences"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Do not reduce substantive topics to short, generic, or one-line bullets"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("include a person only when the spoken transcript supports that the person actually spoke"))
        XCTAssertTrue(MeetingNotesService.instructions.contains("Calendar invitees are reference metadata, not proof that they attended or spoke"))
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

        XCTAssertEqual(FinancialMentionExtractor.evidenceLines(in: transcript).count, 1)
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
        XCTAssertTrue(prompt.contains("Unicode bullet"))
        XCTAssertTrue(prompt.contains("treat the name as the addressee"))
        XCTAssertTrue(prompt.contains("keep this section concise"))
        XCTAssertTrue(prompt.contains("two to four complete sentences"))
        XCTAssertTrue(prompt.contains("Do not reduce substantive topics to short, generic, or one-line bullets"))
        XCTAssertTrue(prompt.contains("include a person only when the spoken transcript supports that the person actually spoke"))
        XCTAssertTrue(prompt.contains("omit the attendee list rather than guessing"))
    }

    func testTranscriptMarksCalendarInviteesAsUnverifiedParticipants() {
        let transcript = LocalScribe().buildTranscript(
            title: "Planning",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            attendees: ["Invited Person"],
            entries: [ScribeEntry(source: .microphone, text: "We should proceed.")]
        )

        XCTAssertTrue(transcript.contains("Calendar invitees (not proof of attendance or speech): Invited Person"))
        XCTAssertFalse(transcript.contains("- Attendees: Invited Person"))
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
                "KEY FINANCIAL AMOUNTS\n• The total is $1800 for 6 sessions."
            )
        )
    }

    func testFormatterOmitsTopSectionWhenNoMoneyWasMentioned() {
        let formatted = MeetingNotesFormatter.finalize(
            "MEETING NOTES\nEXECUTIVE SUMMARY\nSix people attended.\n\nFINANCIAL TERMS AND AMOUNTS\nNone stated.\n\nKEY DISCUSSION POINTS\nPlanning.",
            transcript: "Six people attended for 30 minutes."
        )

        XCTAssertFalse(formatted.contains("KEY FINANCIAL AMOUNTS"))
        XCTAssertFalse(formatted.contains("FINANCIAL TERMS AND AMOUNTS"))
        XCTAssertTrue(formatted.hasPrefix("MEETING NOTES"))
    }

    func testFormatterRemovesTranscriptQualityCommentaryAndEmptySection() {
        let formatted = MeetingNotesFormatter.finalize(
            """
            MEETING NOTES
            EXECUTIVE SUMMARY
            • The team agreed to schedule another interview.

            OPEN QUESTIONS, RISKS, AND DEPENDENCIES:
            • The transcript is incomplete and fragmented, leaving the substance of the discussion, any risks, and dependencies unclear.

            ATTENDEES AND MEETING DETAILS
            • Vigyan Agarwal attended.
            """,
            transcript: "The team agreed to schedule another interview with Vigyan Agarwal."
        )

        XCTAssertFalse(formatted.localizedCaseInsensitiveContains("transcript is incomplete"))
        XCTAssertFalse(formatted.contains("OPEN QUESTIONS, RISKS, AND DEPENDENCIES"))
        XCTAssertTrue(formatted.contains("The team agreed to schedule another interview."))
        XCTAssertTrue(formatted.contains("Vigyan Agarwal attended."))
    }

    func testFormatterRemovesSpeakerAttributionLimitationCommentary() {
        let formatted = MeetingNotesFormatter.finalize(
            """
            MEETING NOTES
            EXECUTIVE SUMMARY
            • The team agreed to continue the discovery work.

            ATTENDEES AND MEETING DETAILS
            • Speaker identities could not be confidently attributed from the transcript, as dialogue was labeled only by audio channel (Mic and System) rather than by name.
            """,
            transcript: "We agreed to continue the discovery work."
        )

        XCTAssertTrue(formatted.contains("continue the discovery work"))
        XCTAssertFalse(formatted.localizedCaseInsensitiveContains("speaker identities"))
        XCTAssertFalse(formatted.localizedCaseInsensitiveContains("audio channel"))
        XCTAssertFalse(formatted.contains("ATTENDEES AND MEETING DETAILS"))
    }

    func testFormatterPreservesLegitimateTranscriptDiscussion() {
        let formatted = MeetingNotesFormatter.finalize(
            "KEY DISCUSSION POINTS\n• The team agreed to order the legal transcript tomorrow.",
            transcript: "We will order the legal transcript tomorrow."
        )

        XCTAssertTrue(formatted.contains("legal transcript tomorrow"))
    }

    func testAutomaticTranscriptionRetryPolicyRetriesOnlyBeforeTranscriptIsSaved() {
        XCTAssertTrue(
            TranscriptionRetryPolicy.shouldRetry(attempt: 1, transcriptWasSaved: false)
        )
        XCTAssertFalse(
            TranscriptionRetryPolicy.shouldRetry(attempt: 2, transcriptWasSaved: false)
        )
        XCTAssertFalse(
            TranscriptionRetryPolicy.shouldRetry(attempt: 1, transcriptWasSaved: true)
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
                encodedSelection: "",
                lastSelectedEmail: "TWO@example.com"
            ),
            ["two@example.com"]
        )
        XCTAssertTrue(
            RecipientSelectionPolicy.initialSelection(
                from: recipients,
                encodedSelection: "",
                lastSelectedEmail: ""
            ).isEmpty
        )
    }

    func testMailAndGmailDraftURLsContainMessageDetails() throws {
        let draft = MeetingEmailDraft(
            recipients: ["one@example.com", "two@example.com"],
            subject: "Meeting notes: Pricing",
            body: "KEY NUMBERS\n• $1800 for 6 sessions",
            senderAccount: "sender@example.com"
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
        XCTAssertEqual(
            mailComponents.queryItems?.first(where: { $0.name == "from" })?.value,
            draft.senderAccount
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
        XCTAssertEqual(
            gmailComponents.queryItems?.first(where: { $0.name == "authuser" })?.value,
            draft.senderAccount
        )

        let fallbackURL = try XCTUnwrap(
            MeetingEmailDraftURLBuilder.url(
                for: draft,
                client: .microsoftOutlook,
                includeBody: true
            )
        )
        let fallbackComponents = try XCTUnwrap(
            URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(
            fallbackComponents.queryItems?.first(where: { $0.name == "body" })?.value,
            draft.body
        )
        XCTAssertEqual(
            fallbackComponents.queryItems?.first(where: { $0.name == "subject" })?.value,
            draft.subject
        )
    }

    func testAutomaticEmailRequiresRecordedConversation() {
        XCTAssertTrue(
            AutomaticMeetingEmailPolicy.shouldOpenDraft(
                automaticDraftEnabled: true,
                hasSpokenConversation: true
            )
        )
        XCTAssertFalse(
            AutomaticMeetingEmailPolicy.shouldOpenDraft(
                automaticDraftEnabled: true,
                hasSpokenConversation: false
            )
        )
        XCTAssertFalse(
            AutomaticMeetingEmailPolicy.shouldOpenDraft(
                automaticDraftEnabled: false,
                hasSpokenConversation: true
            )
        )
    }

    func testNativeEmailClientsRequireDefaultStatusForRichText() {
        XCTAssertEqual(
            MeetingEmailCompositionMode.resolve(
                client: .microsoftOutlook,
                isDefaultNativeClient: true
            ),
            .nativeRichText
        )
        XCTAssertEqual(
            MeetingEmailCompositionMode.resolve(
                client: .microsoftOutlook,
                isDefaultNativeClient: false
            ),
            .requiresDefaultNativeClient
        )
        XCTAssertEqual(
            MeetingEmailCompositionMode.resolve(
                client: .appleMail,
                isDefaultNativeClient: false
            ),
            .requiresDefaultNativeClient
        )
    }

    func testGmailUsesPrefilledPlainTextComposition() {
        XCTAssertEqual(
            MeetingEmailCompositionMode.resolve(
                client: .gmail,
                isDefaultNativeClient: false
            ),
            .prefilledPlainText
        )
    }

    func testDismissedMeetingRemainsExcludedFromAutoRecording() {
        let dismissed: Set<String> = ["dismissed-meeting"]

        XCTAssertFalse(
            CalendarAutoRecordingExclusionPolicy.allowsRecording(
                meetingID: "dismissed-meeting",
                excludedIDs: dismissed
            )
        )
        XCTAssertTrue(
            CalendarAutoRecordingExclusionPolicy.allowsRecording(
                meetingID: "different-meeting",
                excludedIDs: dismissed
            )
        )
    }

    func testEmailFormatterUsesRealBulletsAndNestedIndentation() {
        let nonbreakingSpace = "\u{00A0}"
        let formatted = MeetingNotesEmailFormatter.format(
            """
            ## EXECUTIVE SUMMARY
            - Primary conclusion
              - Supporting detail
                * Deeper qualification

            ACTION ITEMS
            - Follow-up with the post-meeting team
            """
        )

        let lines = formatted.components(separatedBy: .newlines)
        XCTAssertEqual(lines[0], "EXECUTIVE SUMMARY")
        XCTAssertEqual(lines[1], "• Primary conclusion")
        XCTAssertEqual(
            lines[2],
            String(repeating: nonbreakingSpace, count: 4) + "◦ Supporting detail"
        )
        XCTAssertEqual(
            lines[3],
            String(repeating: nonbreakingSpace, count: 8) + "◦ Deeper qualification"
        )
        XCTAssertFalse(formatted.contains("\n- "))
        XCTAssertTrue(formatted.contains("post-meeting"))
    }

    func testEmailFormatterDoesNotArtificiallyWrapLongPrimaryBullets() {
        let formatted = MeetingNotesEmailFormatter.format(
            "• This primary bullet contains enough words to wrap onto another line while keeping its continuation aligned with the text after the bullet instead of returning to the left margin of the email."
        )
        let lines = formatted.components(separatedBy: .newlines)

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("• "))
        XCTAssertTrue(lines[0].hasSuffix("email."))
    }

    func testEmailFormatterDoesNotArtificiallyWrapLongNestedBullets() {
        let formatted = MeetingNotesEmailFormatter.format(
            "    ◦ This nested bullet also contains enough words to wrap and must keep both its nesting indentation and its hanging continuation indentation in Outlook and other email clients."
        )
        let lines = formatted.components(separatedBy: .newlines)

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix(String(repeating: "\u{00A0}", count: 4) + "◦ "))
        XCTAssertTrue(lines[0].hasSuffix("clients."))
    }

    func testEmailFormatterDoesNotArtificiallyWrapNumberedItems() {
        let formatted = MeetingNotesEmailFormatter.format(
            "1. Action: Send a detailed note to stakeholders. Owner: Suraj. Due Date: Not stated. Status: In progress."
        )
        let lines = formatted.components(separatedBy: .newlines)

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("1. Action:"))
        XCTAssertTrue(lines[0].hasSuffix("In progress."))
    }

    func testRichTextFormatterUsesHangingIndentsAndNaturalWrapping() throws {
        let formatted = MeetingNotesRichTextFormatter.format(
            """
            DECISIONS MADE
            • A long primary decision that should remain one paragraph and wrap at the email client's available width.
                ◦ A nested supporting point that should remain aligned beneath its own text.
            """
        )
        let primaryRange = try XCTUnwrap(formatted.string.range(of: "•\u{2003}"))
        let primaryIndex = formatted.string.distance(
            from: formatted.string.startIndex,
            to: primaryRange.lowerBound
        )
        let primaryStyle = try XCTUnwrap(
            formatted.attribute(.paragraphStyle, at: primaryIndex, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(primaryStyle.firstLineHeadIndent, 0)
        XCTAssertEqual(primaryStyle.headIndent, 18)

        let nestedRange = try XCTUnwrap(formatted.string.range(of: "◦\u{2003}"))
        let nestedIndex = formatted.string.distance(
            from: formatted.string.startIndex,
            to: nestedRange.lowerBound
        )
        let nestedStyle = try XCTUnwrap(
            formatted.attribute(.paragraphStyle, at: nestedIndex, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(nestedStyle.firstLineHeadIndent, 18)
        XCTAssertEqual(nestedStyle.headIndent, 36)
        XCTAssertFalse(formatted.string.contains("\t"))
        XCTAssertFalse(formatted.string.contains("\n\u{00A0}"))
    }

    func testRichTextFormatterProducesRTFData() throws {
        let formatted = MeetingNotesRichTextFormatter.format(
            "DECISIONS MADE\n• Continue with the candidate."
        )
        let data = try formatted.data(
            from: NSRange(location: 0, length: formatted.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        XCTAssertFalse(data.isEmpty)
    }

    func testRichTextFormatterUsesMeasuredHangingIndentsForNumberedItems() throws {
        let formatted = MeetingNotesRichTextFormatter.format(
            "1. Action: Send a detailed note to stakeholders that is long enough to wrap in the email composer.\n10. Action: Follow up with the client."
        )

        let firstRange = try XCTUnwrap(formatted.string.range(of: "1.\u{2003}"))
        let firstIndex = formatted.string.distance(
            from: formatted.string.startIndex,
            to: firstRange.lowerBound
        )
        let firstStyle = try XCTUnwrap(
            formatted.attribute(.paragraphStyle, at: firstIndex, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(firstStyle.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(firstStyle.headIndent, firstStyle.firstLineHeadIndent)

        let tenthRange = try XCTUnwrap(formatted.string.range(of: "10.\u{2003}"))
        let tenthIndex = formatted.string.distance(
            from: formatted.string.startIndex,
            to: tenthRange.lowerBound
        )
        let tenthStyle = try XCTUnwrap(
            formatted.attribute(.paragraphStyle, at: tenthIndex, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertGreaterThan(tenthStyle.headIndent, firstStyle.headIndent)
        XCTAssertFalse(formatted.string.contains("\t"))
    }

    func testAutomaticEmailDraftPreparationRejectsMissingConfiguration() {
        let recipients = [MeetingEmailRecipient(name: "One", email: "one@example.com")]

        XCTAssertThrowsError(
            try MeetingEmailDraftPreparation.prepare(
                notes: "Notes",
                meetingTitle: "Planning",
                recipients: recipients,
                emailEveryone: true,
                selectedRecipientEmails: [],
                clientRawValue: "",
                senderAccount: "sender@example.com"
            )
        ) { error in
            XCTAssertEqual(error as? MeetingEmailDraftPreparationError, .emailClientNotSelected)
        }

        XCTAssertThrowsError(
            try MeetingEmailDraftPreparation.prepare(
                notes: "Notes",
                meetingTitle: "Planning",
                recipients: recipients,
                emailEveryone: false,
                selectedRecipientEmails: ["missing@example.com"],
                clientRawValue: MeetingEmailClient.microsoftOutlook.rawValue,
                senderAccount: "sender@example.com"
            )
        ) { error in
            XCTAssertEqual(error as? MeetingEmailDraftPreparationError, .recipientsMissing)
        }
    }

    func testAutomaticEmailDraftPreparationUsesRememberedRecipient() throws {
        let prepared = try MeetingEmailDraftPreparation.prepare(
            notes: "Formatted notes",
            meetingTitle: "Planning",
            recipients: [
                MeetingEmailRecipient(name: "One", email: "one@example.com"),
                MeetingEmailRecipient(name: "Two", email: "two@example.com")
            ],
            emailEveryone: false,
            selectedRecipientEmails: ["two@example.com"],
            clientRawValue: MeetingEmailClient.microsoftOutlook.rawValue,
            senderAccount: "sender@example.com"
        )

        XCTAssertEqual(prepared.client, .microsoftOutlook)
        XCTAssertEqual(prepared.draft.recipients, ["two@example.com"])
        XCTAssertEqual(prepared.draft.subject, "Meeting notes: Planning")
        XCTAssertEqual(prepared.draft.body, "Formatted notes")
    }

    func testMultipleRecipientSelectionsPersistAndPrepareTogether() throws {
        let saved = RecipientSelectionPolicy.encodedSelection([
            "one@example.com",
            "two@example.com"
        ])
        let remembered = RecipientSelectionPolicy.rememberedEmails(
            encodedSelection: saved,
            lastSelectedEmail: "ignored@example.com"
        )
        XCTAssertEqual(remembered, ["one@example.com", "two@example.com"])

        let prepared = try MeetingEmailDraftPreparation.prepare(
            notes: "Notes",
            meetingTitle: "Planning",
            recipients: [
                MeetingEmailRecipient(name: "One", email: "one@example.com"),
                MeetingEmailRecipient(name: "Two", email: "two@example.com"),
                MeetingEmailRecipient(name: "Three", email: "three@example.com")
            ],
            emailEveryone: false,
            selectedRecipientEmails: remembered,
            clientRawValue: MeetingEmailClient.appleMail.rawValue,
            senderAccount: "sender@example.com"
        )

        XCTAssertEqual(prepared.draft.recipients, ["one@example.com", "two@example.com"])
    }

    func testAvailableEmailClientsOnlyIncludesInstalledDesktopApps() {
        XCTAssertEqual(
            MeetingEmailClient.available(
                installedBundleIdentifiers: ["com.apple.mail"],
                hasWebBrowser: true
            ),
            [.appleMail, .gmail]
        )
        XCTAssertEqual(
            MeetingEmailClient.available(
                installedBundleIdentifiers: ["com.microsoft.Outlook"],
                hasWebBrowser: false
            ),
            [.microsoftOutlook]
        )
    }

    func testSenderAccountMustBeOneCompleteEmailAddress() {
        XCTAssertTrue(MeetingEmailSenderAccount.isValid(" Sender@Example.com "))
        XCTAssertFalse(MeetingEmailSenderAccount.isValid("sender"))
        XCTAssertFalse(MeetingEmailSenderAccount.isValid("one@example.com two@example.com"))
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
            model: "claude-sonnet-5",
            workspaceID: "wrkspc_primary"
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

    func testProviderConfigurationDecodesLegacyDataWithoutWorkspaceID() throws {
        let data = Data(
            #"[{"id":"00000000-0000-0000-0000-000000000001","provider":"Claude","label":"Legacy","model":"claude-sonnet-5"}]"#.utf8
        )

        let restored = try JSONDecoder().decode([APIProviderConfiguration].self, from: data)

        XCTAssertEqual(restored.first?.label, "Legacy")
        XCTAssertNil(restored.first?.workspaceID)
    }
}

final class MeetingEmailClientPickerTests: XCTestCase {
    func testPickerIncludesSavedSelectionBeforeInstalledClientsLoad() {
        XCTAssertEqual(
            MeetingEmailClient.pickerValues(
                available: [],
                selectedRawValue: MeetingEmailClient.microsoftOutlook.rawValue
            ),
            [MeetingEmailClient.microsoftOutlook.rawValue]
        )
    }

    func testPickerDoesNotDuplicateAvailableSavedSelection() {
        XCTAssertEqual(
            MeetingEmailClient.pickerValues(
                available: [.appleMail, .microsoftOutlook],
                selectedRawValue: MeetingEmailClient.microsoftOutlook.rawValue
            ),
            [MeetingEmailClient.appleMail.rawValue, MeetingEmailClient.microsoftOutlook.rawValue]
        )
    }
}

final class RecordedVoiceDetectorTests: XCTestCase {
    func testRecognizesSpeechClassification() {
        XCTAssertTrue(
            RecordedVoiceDetector.isVoiceClassification(
                identifier: "speech",
                confidence: 0.8
            )
        )
    }

    func testRecognizesHumanVoiceClassification() {
        XCTAssertTrue(
            RecordedVoiceDetector.isVoiceClassification(
                identifier: "human_voice",
                confidence: 0.8
            )
        )
    }

    func testIgnoresNonVoiceSound() {
        XCTAssertFalse(
            RecordedVoiceDetector.isVoiceClassification(
                identifier: "air_conditioner",
                confidence: 0.95
            )
        )
    }

    func testIgnoresLowConfidenceVoiceClassification() {
        XCTAssertFalse(
            RecordedVoiceDetector.isVoiceClassification(
                identifier: "speech",
                confidence: 0.1
            )
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
