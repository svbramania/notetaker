# NoteTaker Scribe

A local-first macOS meeting scribe that captures microphone audio, system/output audio, and typed meeting chat or notes. It transcribes speech on-device with Apple's Speech framework, saves a complete timestamped transcript, and hands the transcript to the user's existing ChatGPT account for summarization.

## MVP capabilities

- Uses ScreenCaptureKit for both microphone and macOS system/output audio capture.
- Keeps microphone and system audio as separate local tracks.
- Registers a screen output but discards video frames; this keeps the ScreenCaptureKit stream healthy without storing screen video.
- Captures meeting title and known attendees entered by the user.
- Lets you paste or type relevant meeting chat and personal notes with timestamps.
- Uses Apple's on-device Speech framework for transcription; no OpenAI API key is required.
- Preserves everything transcribed from the meeting in timestamp order.
- Saves `meeting-transcript.md`, `transcript.json`, `chatgpt-summary-prompt.md`, `microphone.m4a`, and `system-audio.m4a` under Application Support on your Mac.
- Provides **Summarize in ChatGPT**, which copies the transcript and a structured summary prompt, then opens the ChatGPT desktop app or ChatGPT on the web.
- Transcribes microphone and system audio sequentially and continues when either track contains speech.
- Groups Apple Speech word segments into readable timestamped utterances using punctuation, natural pauses, and a 35-word limit.
- Keeps **Open Recordings Folder** visible at all times.
- Uses the user's signed-in ChatGPT account and never asks for an OpenAI API key.
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
12. Click **Summarize in ChatGPT**. The app copies the transcript and summary instructions and opens ChatGPT.
13. Paste into ChatGPT with **Command-V**, then send.

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

The full local transcript remains the source of truth. ChatGPT is asked to use only transcript-supported information and to mark missing owners and dates as “Not stated.” ChatGPT subscriptions and OpenAI API billing are separate, so this app uses a user-controlled ChatGPT handoff rather than making API calls in the background.

## Current MVP limitations

- Microphone and system audio are stored in separate files. Both come from the same ScreenCaptureKit stream and are transcribed sequentially in 50-second chunks so a silent or failed chunk does not block the rest of the meeting.
- Apple Speech availability and on-device language support vary by macOS version and locale.
- The app does not automatically read Zoom, Teams, or Google Meet chat yet; chat can be pasted or typed into the app.
- Speaker names are not inferred from voices. Mic is labeled `Mic`, system output is labeled `System`, and typed entries are labeled `Chat` or `Note`.
- ChatGPT summarization requires the user to paste and send the prepared prompt. This keeps the workflow within the user's ChatGPT account without storing account credentials or requiring an API key.
- Calendar detection uses every selected calendar available through macOS Calendar, including multiple Google and Microsoft accounts.
- Notifications are scheduled for detected meetings in the next 24 hours whenever NoteTaker is running. Scheduled alerts remain available after the app closes.
- Calendar auto-recording works while NoteTaker is running. It does not launch a closed application at an event's start time.

## Privacy and consent

Meeting audio remains local to your Mac. The transcript stays local until you paste and submit the prepared prompt to ChatGPT. Recording laws and company policies vary by jurisdiction and organization, so make sure participants are appropriately informed and that you have permission to record where required.
