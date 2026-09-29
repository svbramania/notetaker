# NoteTaker — Claude Development Handoff

Last updated: September 29, 2026 — Codex release 0.14.0

## Purpose

NoteTaker is a local-first macOS application that records microphone and system audio during meetings, transcribes both tracks with Apple Speech, creates structured meeting notes through OpenAI or Anthropic Claude when the user supplies an API key, and prepares an email draft for recipients selected by the user.

Repository: https://github.com/svbramania/notetaker

Current release: `0.14.0`

Previous verified `main` commit: `0b95254524c01f93bc781a5e8f224e578631565a`; version 0.14.0 is the current local release commit

Pull request for the latest release: https://github.com/svbramania/notetaker/pull/27

The version 0.13.0 macOS GitHub Actions build and test suite passed before that release was squash-merged. Version 0.14.0 must pass the same workflow before merge.

## Product principles

1. Recordings and transcripts remain on the Mac unless the user deliberately sends a transcript to an Artificial Intelligence provider or opens an email draft.
2. Calendar auto-recording is enabled by default, but the user can turn it off.
3. Meetings normally qualify for auto-recording only when the invitation contains a Microsoft Teams, Zoom, or Google Meet link. A separate preference can include invitations without a recognized meeting link.
4. Recording must remain visible to the user and should respect consent requirements.
5. Never collect a user's ChatGPT or Claude password.
6. API keys are optional, may include multiple OpenAI and Claude keys, and must remain in macOS Keychain.
7. A no-key workflow must remain available through the signed-in ChatGPT application or website.
8. The complete transcript is the source of truth. Summaries must not invent facts, owners, deadlines, decisions, or numbers.

## Local storage

Meeting folders are stored at:

```text
~/Library/Application Support/NoteTaker/Meetings
```

Each meeting folder is named from the calendar or manually entered meeting title followed by its date and time. A folder can contain:

- `microphone.m4a`
- `system-audio.m4a`
- `meeting-transcript.md`
- `meeting-notes.md`
- `transcript.json`
- `chatgpt-summary-prompt.md`

The application scans this directory when it opens, lists saved meetings newest-first, and automatically selects the most recent folder. The selector appears immediately before **Transcribe Meeting**. A saved recording can be selected and transcribed again after the application is restarted or force-quit.

## Current workflow

### Calendar and recording

- Reads calendars already synchronized with macOS Calendar through EventKit.
- Supports calendars from multiple Gmail, Microsoft Outlook/Exchange, iCloud, CalDAV, and local accounts.
- Allows users to choose which calendars are monitored.
- Detects Teams, Meet, and Zoom links in calendar invitations.
- Schedules a local “Meeting starts soon—record?” notification.
- Automatically starts at the calendar start time and stops at the calendar end time when auto-record is enabled.
- Auto-record is enabled by default.
- Manual recordings remain independent of calendar stop rules.
- Provides separate calendar-access and **Allow Access to Mic and Speakers** controls.
- Can stop after locally detecting common spoken sign-offs such as “bye,” “goodbye,” or “thanks everyone,” with a short confirmation delay.

### Audio and transcription

- Uses ScreenCaptureKit for microphone and system/output audio.
- Saves microphone and system audio as separate M4A tracks.
- Does not store screen video.
- Audio writing and live sign-off recognition run away from the interface thread.
- New recordings use fragmented media output to improve recovery following an unexpected exit.
- Apple Speech transcription is on-device and processes the two audio tracks sequentially.
- Long recordings are split into 50-second chunks.
- A silent track does not invalidate speech found in the other track.
- Duplicate speech captured on both tracks is substantially deduplicated.
- The interface shows chunk progress and allows cancellation without deleting recordings.
- Failed chunks are retried once.
- Apple Speech and audio-export operations have hard timeouts so a stalled framework call does not leave the interface waiting forever.
- Typed chat and personal notes are combined with spoken entries in timestamp order.

### Artificial Intelligence notes

- The user may configure multiple OpenAI and Claude API keys.
- Each key is stored independently in macOS Keychain.
- The user controls provider/key attempt order.
- An optional preference tries the next provider only when the current provider reports an exhausted quota, credit, usage, or spending limit.
- After successful transcription, configured API-based note generation starts automatically.
- Completed meetings enter a serial background-processing queue, allowing the recorder to start a back-to-back calendar meeting without waiting for transcription or AI generation.
- A Retry/Cancel alert is shown when post-processing fails.
- If no API key is configured, the local transcript is preserved and **Summarize in ChatGPT** prepares the no-key handoff.

The Artificial Intelligence prompt must:

- Use only facts supported by the transcript.
- Remove hashtags and fix formatting.
- Put all important numbers, monetary amounts, prices, dates, percentages, quantities, durations, and financial terms at the beginning.
- Preserve the exact context of every monetary amount. For example, `$1800 for 6 sessions` must not be omitted or separated from its meaning.
- Apply the Pyramid Principle: lead with the main conclusion, then supporting facts.
- Include decisions, action items, owners, due dates, status, discussion points, risks, dependencies, open questions, attendees, and meeting details.
- Mark missing owners or dates as `Not stated` rather than guessing.
- Produce clean, editable, email-ready text without Markdown heading clutter or excessive symbols.

Expected output structure:

```text
KEY FINANCIAL AMOUNTS (only when an actual monetary amount was stated)
MEETING NOTES
EXECUTIVE SUMMARY
DECISIONS MADE
ACTION ITEMS
FINANCIAL TERMS AND AMOUNTS
KEY DISCUSSION POINTS
OPEN QUESTIONS, RISKS, AND DEPENDENCIES
ATTENDEES AND MEETING DETAILS
```

### Email workflow

- Extracts candidate recipient addresses from calendar attendees and manually entered attendee details.
- Displays one **Everyone** checkbox plus individual recipient checkboxes.
- Email-client, sender-account, automatic-draft, and recipient-default choices are configured ahead of time in Settings.
- On a new meeting, all recipients start unchecked except the individual address selected most recently.
- Detects supported installed clients: Apple Mail, Microsoft Outlook, and Gmail in a browser.
- Lets the user choose the email client and specify the sender-account email.
- Remembers a separate sender account for each client.
- Opens a reviewable draft; it does not silently send email.

## Important source files

- `NoteTaker/NoteTakerApp.swift` — primary interface and end-to-end recording/transcription orchestration.
- `NoteTaker/MeetingRecorder.swift` — ScreenCaptureKit stream, audio writers, saved-folder discovery, recording lifecycle, and crash-resilient media settings.
- `NoteTaker/LocalScribe.swift` — Apple Speech authorization, chunking, recognition, timeouts, retry, progress, cancellation, utterance grouping, and track deduplication.
- `NoteTaker/LiveSignOffDetector.swift` — local live recognition used for closing-phrase detection.
- `NoteTaker/CalendarMeetingMonitor.swift` — EventKit calendar discovery, meeting eligibility, notifications, and active-event tracking.
- `NoteTaker/CloudMeetingNotesView.swift` — API configuration, provider ordering, automatic note generation, result review, recipients, and email controls.
- `NoteTaker/MeetingNotesService.swift` — provider calls, prompt construction, response handling, monetary safeguards, and fallback classification.
- `NoteTaker/MeetingEmailLauncher.swift` — installed-client discovery and email-draft routing.
- `NoteTaker/RecordingPermissionManager.swift` — microphone and system-audio permission readiness.
- `NoteTakerTests/MeetingLinkDetectorTests.swift` — calendar, folder naming/discovery, notes, recipient, provider, and related unit tests.
- `project.yml` — XcodeGen project configuration, entitlements-related build settings, deployment target, and version.

## Build and test

Requirements:

- macOS 15 or later
- Xcode 16 or later
- XcodeGen

Commands:

```bash
brew install xcodegen
git clone https://github.com/svbramania/notetaker.git
cd notetaker
xcodegen generate
open NoteTaker.xcodeproj
```

In Xcode, select the NoteTaker scheme, choose the developer team under **Signing & Capabilities**, clean the build folder, and run the application.

For every code change:

1. Preserve existing user settings and recordings.
2. Add or update unit tests.
3. Generate the Xcode project from `project.yml`.
4. Run the macOS build and tests.
5. Use a pull request and squash merge only after tests pass.
6. Increment the marketing version for a user-visible release.

## Permissions

The application may request:

- Microphone
- Screen and System Audio Recording
- Speech Recognition
- Calendar
- Notifications

The bundle identifier must remain stable:

```text
com.agilemindset.notetaker
```

Unstable development signing can cause macOS Transparency, Consent, and Control permissions to appear denied after rebuilds. Keep automatic signing enabled, select a consistent Apple Development team, and preserve the bundle identifier.

## Known limitations and cautions

- Calendar auto-recording works only while NoteTaker is running; it does not currently launch a closed app at meeting start.
- NoteTaker does not automatically extract native chat from Teams, Meet, or Zoom.
- Speaker names are not inferred from voice identity. Sources are currently Mic, System, Chat, and Note.
- The no-key ChatGPT workflow still requires the user to paste and submit the prepared prompt.
- API-based automation uses separate OpenAI or Claude API billing; a ChatGPT subscription cannot be silently reused as a general third-party API credential.
- Email is opened automatically as a draft when configured; final sending remains under the user's control.
- Do not add mailbox-password SMTP authentication. Safe direct Gmail/Outlook delivery requires provider OAuth and narrowly scoped send permission.
- Apple Speech availability varies by locale, installed recognition assets, macOS version, and hardware.
- An audio container produced by an older app version and interrupted before finalization may be unreadable. Version 0.13.0 improves future recovery but cannot reconstruct missing container metadata from every older file.

## Recommended next work

1. Add a durable transcription job record inside each meeting folder so interrupted chunk work resumes from the last completed chunk rather than restarting the entire meeting.
2. Store partial per-chunk transcripts incrementally and atomically.
3. Add transcript editing, speaker correction, timestamp-linked playback, and autosave.
4. Add an explicit review gate that clearly shows what will leave the Mac before any provider call or email draft.
5. Add configurable audio/transcript retention and automatic deletion.
6. Add recovery behavior for sleep/wake, audio-device changes, Bluetooth disconnects, and ScreenCaptureKit interruptions.
7. Add a permission-repair center for microphone, system audio, speech, calendars, and notifications.
8. Add App Store sandboxing, privacy labels, support/privacy URLs, accessibility review, localization, screenshots, reviewer notes, signing, notarization, and release packaging.
9. Build and execute the physical-device test matrix across Teams, Google Meet, Zoom, Mac speakers, wired headphones, AirPods, Bluetooth microphones, and changing input/output devices.

## Acceptance checks for recovery

Before calling the recovery flow complete, verify all of these on a physical Mac:

1. Record at least two minutes, force-quit NoteTaker, reopen it, and confirm the latest meeting folder is selected.
2. Select **Transcribe Meeting** and confirm readable audio is transcribed or a bounded, actionable error appears.
3. Cancel transcription during a long meeting, restart it, and confirm the audio files remain unchanged.
4. Simulate a stalled or unavailable Speech recognizer and confirm the user regains control after the timeout.
5. Configure a valid provider key, complete transcription, and confirm meeting-note generation begins automatically.
6. Remove all API keys, complete transcription, and confirm the transcript is saved without an attempted cloud request.
7. Verify that generated notes begin with all transcript-supported numbers and retain every monetary amount with its context.
8. Confirm the recipient list starts with only the last individually selected recipient checked.
9. Confirm the chosen email client and sender-account preference are restored correctly.

## Instruction to the next developer

Start from `main`, read this document and the repository README, and inspect the most recent pull requests before changing behavior. Preserve local-first operation, existing meeting folders, Keychain data, user preferences, and the no-key ChatGPT path. Do not weaken permission, consent, privacy, or recipient-review controls while improving automation.



## Version 0.14.0 changes

- Renamed this document to `Claude_Codex_handoff.MD` for shared Claude/Codex continuity.
- Changed the top summary block to `KEY FINANCIAL AMOUNTS`; it appears only when the transcript contains an actual currency amount or spoken currency amount.
- Removed generic dates, counts, percentages, quantities, and durations from the top of notes.
- Removed empty `FINANCIAL TERMS AND AMOUNTS` sections when no money was stated.
- Added a serial post-processing queue so recording of a back-to-back calendar meeting is not blocked by prior transcription or AI work.
- Added Meeting and Settings tabs. Raw transcript display was removed from the main interface.
- Added a default-on `Enable calendar alerts` checkbox in Settings.
- Added masked API-key entry with an explicit reveal/hide control.
- Added ahead-of-time automatic email-draft and recipient-default settings.
- Added Retry and Cancel alerts for post-processing and AI generation failures.

