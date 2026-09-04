# NoteTaker Scribe

A local-first macOS meeting scribe that captures microphone audio, system/output audio, and typed meeting chat or notes. It transcribes speech on-device with Apple's Speech framework, saves a complete timestamped transcript, and can create structured notes through a user-provided OpenAI or Claude API key.

## MVP capabilities

- Uses ScreenCaptureKit for both microphone and macOS system/output audio capture.
- Keeps microphone and system audio as separate local tracks.
- Registers a screen output but discards video frames; this keeps the ScreenCaptureKit stream healthy without storing screen video.
- Captures meeting title and known attendees entered by the user.
- Lets you paste or type relevant meeting chat and personal notes with timestamps.
- Uses Apple's on-device Speech framework for transcription; no OpenAI API key is required.
- Preserves everything transcribed from the meeting in timestamp order.
- Saves `meeting-transcript.md`, `meeting-notes.md`, `transcript.json`, `chatgpt-summary-prompt.md`, `microphone.m4a`, and `system-audio.m4a` under Application Support on your Mac.
- Provides **Summarize in ChatGPT**, which copies the transcript and a structured summary prompt, then opens the ChatGPT desktop app or ChatGPT on the web.
- Transcribes microphone and system audio sequentially and continues when either track contains speech.
- Groups Apple Speech word segments into readable timestamped utterances using punctuation, natural pauses, and a 35-word limit.
- Keeps **Open Recordings Folder** visible at all times.
- Keeps the signed-in ChatGPT handoff available without an API key.
- Optionally accepts an OpenAI or Claude API key and stores it in macOS Keychain with device-only, unlocked access.
- Generates editable meeting notes with an executive summary, decisions, action items, owners, due dates, discussion points, risks, open questions, and meeting details.
- Extracts attendee email addresses from calendar invitations and manually entered attendee details.
- Provides an **Everyone** recipient checkbox plus an individual checkbox for every attendee email address.
- Creates an addressed email draft containing the reviewed notes through the Mac's configured email application.
- Sends content to ChatGPT only when the user pastes the prepared prompt into ChatGPT and submits it.
- Reads upcoming events from calendars already synchronized with macOS Calendar.
- Discovers calendars across multiple Gmail, Outlook, Exchange, iCloud, CalDAV, and local accounts connected to the Mac.
- Provides **Choose Calendars** controls grouped by account, with Select All, Clear Selection, saved exclusions, and automatic inclusion of newly added calendars.
- Recognizes Microsoft Teams, Google Meet, and Zoom links in event URLs, locations, and notes.
- Schedules a local **Meeting starts soon—record?** notification five minutes before a recognized call.
- Displays the upcoming meeting in NoteTaker and fills its title and attendee names when recording begins.
- Provides a saved **Auto-record calendar meetings** switch that starts recording at a supported calendar event's start time and stops at its end time.
- Enables calendar auto-recording by default for new installs while preserving each existing user's saved switch preference.
- Keeps manual recordings independent, so calendar boundaries never stop a recording that the user started manually.
- Names each recording folder from its meeting title followed by a timestamp, with a safe `Meeting` fallback for blank titles.
- Provides a separate **Allow Access to Mic and Speakers** button with individual readiness indicators for microphone and system audio.
- Splits long recordings into 50-second files for reliable Apple Speech recognition, then rebuilds the complete timeline.
- Removes substantially matching speech captured by both the microphone and system-audio tracks while preserving distinct contributions.

## Requirements

- macOS 15+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- A language/locale for which macOS supports on-device speech recognition

## Build

```bash
brew install xcodegen
xcodegen generate
open NoteTaker.xcodeproj
```

In Xcode, select the `NoteTaker` scheme and run the app. macOS will request Microphone, Screen & System Audio Recording, Speech Recognition, Calendar, and Notification permissions as the related features are enabled.

## Use

1. Add each Gmail and Outlook account to **System Settings → Internet Accounts** and enable Calendar for each account.
2. Choose **Enable Calendar Alerts** to detect upcoming Teams, Meet, and Zoom meetings across those calendars.
3. Allow Calendar and Notification access when macOS asks, then use **Choose Calendars** to review or refine which calendars NoteTaker monitors.
4. Choose **Allow Access to Mic and Speakers**, then approve Microphone and Screen & System Audio Recording access.
5. **Auto-record calendar meetings** is on by default. Keep NoteTaker running; recognized meetings will record from their calendar start time through their end time. Use the switch to turn this automation off whenever preferred.
6. Enter the meeting title and attendees manually, wait for a detected meeting prompt, or use calendar auto-recording.
7. Click **Record Meeting** for a manual recording. From an upcoming-meeting prompt or automatic recording, the title and available attendee names are filled automatically.
8. During the meeting, paste or type relevant chat messages and your own notes. Each entry is timestamped.
9. Click **Stop Meeting** for a manual recording; an automatic recording stops at the calendar event's end time.
10. Click **Build Transcript**.
11. Review the complete local transcript.
12. Use **Summarize in ChatGPT** for the existing no-key handoff, or choose OpenAI/Claude and save an API key in macOS Keychain.
13. Select **Generate Meeting Notes** to create and save an editable `meeting-notes.md` file.
14. Select **Everyone** or individual attendee email checkboxes, then choose **Prepare Email**.
15. Review the addressed draft in the configured Mac email application and send it.

## ChatGPT summary output

The prepared ChatGPT prompt requests this Pyramid-style structure:

```text
Executive summary
Decisions made
Action items (owner and due date)
Key discussion points
Open questions, risks, and dependencies
Attendees and meeting details
```

The full local transcript remains the source of truth. Both the ChatGPT handoff and API-generated workflow instruct the selected model to use only transcript-supported information and mark missing owners and dates as “Not stated.” ChatGPT subscriptions, OpenAI API usage, and Claude API usage have separate billing arrangements.

## Current MVP limitations

- Microphone and system audio are stored in separate files. Both come from the same ScreenCaptureKit stream and are transcribed sequentially in 50-second chunks so a silent or failed chunk does not block the rest of the meeting.
- Apple Speech availability and on-device language support vary by macOS version and locale.
- The app does not automatically read Zoom, Teams, or Google Meet chat yet; chat can be pasted or typed into the app.
- Speaker names are not inferred from voices. Mic is labeled `Mic`, system output is labeled `System`, and typed entries are labeled `Chat` or `Note`.
- The ChatGPT handoff requires the user to paste and send the prepared prompt. The optional OpenAI and Claude integrations send the transcript directly after the user selects **Generate Meeting Notes**.
- **Prepare Email** opens an addressed draft for review and sending through the configured Mac email application.
- Calendar detection uses every selected calendar available through macOS Calendar, including multiple Google and Microsoft accounts.
- Notifications are scheduled for detected meetings in the next 24 hours whenever NoteTaker is running. Scheduled alerts remain available after the app closes.
- Calendar auto-recording works while NoteTaker is running. It does not launch a closed application at an event's start time.

## Privacy and consent

Meeting audio remains local to your Mac. The transcript stays local until you paste and submit the prepared prompt to ChatGPT. Recording laws and company policies vary by jurisdiction and organization, so make sure participants are appropriately informed and that you have permission to record where required.
