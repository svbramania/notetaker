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

In Xcode, select the `NoteTaker` scheme and run the app. macOS will request Microphone, Screen & System Audio Recording, and Speech Recognition permissions.

## Use

1. Enter the meeting title.
2. Enter attendees if you know them. Leave blank if unavailable.
3. Click **Record Meeting**.
4. During the meeting, paste or type relevant chat messages and your own notes. Each entry is timestamped.
5. Click **Stop Meeting**.
6. Click **Build Transcript**.
7. Review the complete local transcript.
8. Click **Summarize in ChatGPT**. The app copies the transcript and summary instructions and opens ChatGPT.
9. Paste into ChatGPT with **Command-V**, then send.

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

- Microphone and system audio are stored in separate files. Both come from the same ScreenCaptureKit stream and are transcribed sequentially so a silent track does not block the other track.
- Apple Speech availability and on-device language support vary by macOS version and locale.
- The app does not automatically read Zoom, Teams, or Google Meet chat yet; chat can be pasted or typed into the app.
- Speaker names are not inferred from voices. Mic is labeled `Mic`, system output is labeled `System`, and typed entries are labeled `Chat` or `Note`.
- ChatGPT summarization requires the user to paste and send the prepared prompt. This keeps the workflow within the user's ChatGPT account without storing account credentials or requiring an API key.

## Privacy and consent

Meeting audio remains local to your Mac. The transcript stays local until you paste and submit the prepared prompt to ChatGPT. Recording laws and company policies vary by jurisdiction and organization, so make sure participants are appropriately informed and that you have permission to record where required.
