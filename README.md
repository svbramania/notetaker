# NoteTaker Scribe

A local-first macOS meeting scribe that captures microphone audio, system/output audio, and typed meeting chat or notes. It transcribes speech on-device with Apple's Speech framework and saves a timestamped meeting record with conservative Pyramid-style extraction.

## MVP capabilities

- Uses ScreenCaptureKit for both microphone and macOS system/output audio capture.
- Keeps microphone and system audio as separate local tracks.
- Registers a screen output but discards video frames; this keeps the ScreenCaptureKit stream healthy without storing screen video.
- Captures meeting title and known attendees entered by the user.
- Lets you paste or type relevant meeting chat and personal notes with timestamps.
- Uses Apple's on-device Speech framework for transcription; no OpenAI API key is required.
- Preserves the complete scribe and extracts explicit:
  - executive takeaway;
  - decisions;
  - action items;
  - open questions and risks;
  - meeting title, date/time, and attendees.
- Saves `meeting-scribe.md`, `scribe.json`, `microphone.m4a`, and `system-audio.m4a` under Application Support on your Mac.
- Does not send meeting audio or text to OpenAI.

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
6. Click **Build Scribe**.
7. Review the complete local meeting scribe or open the meeting folder.

## Pyramid-style output

The software preserves the full evidence first, then surfaces the most important explicit meeting outcomes in this order:

```text
Executive takeaway
Decisions
Action items
Open questions and risks
Meeting details
Full scribe
```

This version intentionally avoids generative summarization. It only promotes statements that contain explicit decision, commitment, follow-up, blocker, or risk language. The full scribe remains the source of truth.

## Current MVP limitations

- Microphone and system audio are stored in separate files. Both come from the same ScreenCaptureKit stream, which improves timing consistency, but the files are still transcribed independently.
- Apple Speech availability and on-device language support vary by macOS version and locale.
- The app does not automatically read Zoom, Teams, or Google Meet chat yet; chat can be pasted or typed into the app.
- Speaker names are not inferred from voices. Mic is labeled `Mic`, system output is labeled `System`, and typed entries are labeled `Chat` or `Note`.
- Decision/action extraction is rule-based and intentionally conservative rather than AI-generated.

## Privacy and consent

Meeting audio, transcript, typed content, and reports remain local to your Mac in this version. Recording laws and company policies vary by jurisdiction and organization, so make sure participants are appropriately informed and that you have permission to record where required.
