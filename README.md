# NoteTaker

A local-first macOS meeting recorder that captures your microphone and system audio, transcribes both tracks, and creates concise meeting notes using the Pyramid Principle.

## MVP capabilities

- Records microphone audio locally.
- Records macOS system/output audio locally using ScreenCaptureKit.
- Captures meeting title and known attendees entered by the user.
- Lets you type manual notes during the meeting and gives those notes extra weight.
- Transcribes the local/microphone and remote/system tracks with OpenAI speech-to-text.
- Produces Pyramid-style notes with:
  - executive takeaway first;
  - logically grouped supporting themes;
  - explicit decisions;
  - action items with owner, due date, and status;
  - open questions, blockers, dependencies, and risks;
  - meeting title, date/time, and attendees.
- Saves `notes.md`, `transcript.txt`, `microphone.m4a`, and `system-audio.m4a` under Application Support on your Mac.
- Sends audio to OpenAI only when you choose **Generate Notes**. Raw recordings remain local.

## Requirements

- macOS 14+
- Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An OpenAI API key

## Build

```bash
brew install xcodegen
xcodegen generate
open NoteTaker.xcodeproj
```

In Xcode, select the `NoteTaker` scheme and run the app. The first recording will trigger macOS microphone and Screen Recording permission prompts. If macOS asks you to restart the app after granting Screen Recording access, do so.

## Use

1. Enter the meeting title.
2. Enter attendees if you know them. Leave blank if unavailable.
3. Paste an OpenAI API key. The MVP keeps it only in app memory for the current session.
4. Click **Record Meeting**.
5. Optionally type rough notes while the meeting is running.
6. Click **Stop Meeting**.
7. Click **Generate Notes**.
8. Review the Pyramid-style notes in the app or open the meeting folder.

## Pyramid Principle output

The note generator is instructed to start with the most important conclusion or current state, then support it with distinct themes. Decisions, actions, and unresolved risks are kept separate so follow-through is clear.

The expected structure is:

```text
Executive takeaway
  ├─ Supporting theme 1
  ├─ Supporting theme 2
  └─ Supporting theme 3

Decisions
Action items
Open questions / risks
Meeting metadata
```

## Current MVP limitation

Microphone and system audio are recorded as separate tracks for capture reliability. The summarizer knows which transcript came from the local microphone and which came from system audio, but it should not claim precise cross-track chronology. A later version can add a synchronized mixed track, diarization, calendar metadata, searchable history, and automatic attendee mapping.

## Privacy and consent

Recording laws and company policies vary by jurisdiction and organization. Make sure participants are appropriately informed and that you have permission to record meetings where required.
