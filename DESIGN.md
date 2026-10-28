# Meeting Capture & Transcription for Mac: Design Doc

Oct 28, 2026 · @John Souchak

## Overview and goals

A personal Mac menu-bar app that records whatever your Mac is playing, plus your microphone, during a call, then turns it into a text transcript. You open it before the call, ask for consent aloud, press Start, and press Stop when you're done.

**v1 goals**

- Works with any call app (FaceTime, Zoom, Teams, Meet) by capturing system audio, with no per-app integration.
- Captures both sides: the other participants through system audio, you through the mic.
- Transcribes locally by default, so no audio leaves your Mac.
- Saves a plain-text transcript you can open right away.

**Success:** after a 30-minute call you press Stop and, within a few minutes, have a readable transcript labeled Me and Them.

## Scope

v1 is capture plus transcript, started and stopped by hand. Everything else waits.

| In v1 | Deferred |
| --- | --- |
| Menu-bar app with Start and Stop | Auto-start when a call app opens |
| System audio plus mic, saved as two audio files | Live, on-screen transcription |
| Transcript generated after Stop | AI summaries and action items |
| Me / Them labels from the two tracks | Naming individual remote speakers |
| Plain-text transcript file | Search across past calls |
| Spoken consent, done by you | In-app consent reminder |

## User workflow

1. Open the app before the call. It sits in the menu bar.
2. Join your FaceTime, Zoom, Teams, or Meet call as usual.
3. Click Start. The menu-bar icon turns red while recording.
4. Say aloud: "Do you mind if I record this for my notes?" and wait for a clear yes.
5. Click Stop when the call ends, or right away if anyone says no.
6. The app transcribes the recording, then opens the folder with the transcript.

Step 3 comes before step 4 on purpose, so the yes is captured on the recording.

## Architecture

&#91;embedded content: data flow · 2 capture tracks, 1 transcript\]

The Start button calls `startRecording()`, which launches both capture streams. Each writes its own file while the call runs. After Stop, WhisperKit transcribes both files and merges them by timestamp.

## Audio capture

Use ScreenCaptureKit for system audio and capture the mic as a second, separate track.

- **System audio:** an SCStream with audio capture on. It records whatever the Mac plays, whichever call app is running. Requires macOS 13 or later.
- **Mic:** AVAudioEngine's input node works on any supported macOS. On macOS 15 and later, ScreenCaptureKit can capture the mic itself.
- **Two tracks, not a mix.** Saving them separately gives you Me and Them labels for free and lets each be transcribed cleanly.
- **Write to disk as you go.** Stream each track to a file during the call, so a crash loses seconds, not the whole call.
- **Alternative:** Core Audio process taps (macOS 14.2 and later) capture system audio without the Screen Recording permission. Worth trying if that prompt becomes annoying.
- **Fallback:** a virtual driver such as BlackHole, only if the above fails on your macOS version.

Use headphones. With speakers, your mic re-records the other side and the Me track fills with Them audio.

## Transcription

Recommendation: transcribe locally with WhisperKit after you press Stop.

| Option | Pros | Cons |
| --- | --- | --- |
| WhisperKit (Swift, Core ML) | Native Swift package, fast on Apple Silicon, audio stays on the Mac | Model download (hundreds of MB to a few GB) |
| whisper.cpp | Very portable, well documented | C++ bridge adds setup |
| Cloud API (Deepgram, AssemblyAI) | Live streaming, speaker labels, no local model | Audio leaves your Mac, per-minute cost |

- **After Stop, not live.** Batch transcription is simpler and usually more accurate. Live captions can come in v2.
- **Transcribe each track on its own,** then merge the segments by timestamp into one Me/Them transcript.
- **Model size:** start with a small or turbo-class Whisper model and move up only if accuracy disappoints.
- **Cloud later:** if you want live text or named speakers, add a cloud backend behind the same transcriber interface.

## UI and storage

**Menu-bar app**, no dock icon, with one menu:

- Start / Stop toggle
- Status line: Idle, Recording (with a running timer), or Transcribing
- Open last transcript
- Open recordings folder
- Quit

The icon turns red while recording, so you can't forget it's on.

**Files:** each call gets a folder under `~/Documents/CallCaptures/`, named by date and time.

```text
2026-10-28_1400/
  me.wav
  them.wav
  transcript.md
```

Add a setting to delete the audio after transcription if you only want the text.

## macOS permissions and setup

Two permissions, both granted once in System Settings under Privacy & Security.

- **Screen & System Audio Recording:** lets ScreenCaptureKit hear system audio. The prompt appears the first time you press Start.
- **Microphone:** needs an `NSMicrophoneUsageDescription` string in the app's Info.plist.

Two gotchas:

- **Sign the app with a stable identity.** A free Apple ID in Xcode is enough for personal use. If the signature changes on every rebuild, macOS may forget the permissions and ask again.
- **macOS Sequoia re-asks periodically** to confirm Screen Recording access. That's expected, not a bug.

You don't need the App Store or notarization for an app that runs only on your own Mac.

## Consent step

v1 has no consent feature in the software. You ask aloud on every call, and the recording captures the answer.

To add a reminder later without a refactor, route all recording through one function:

```swift
func startRecording() {
    // begin both capture streams
}
```

The Start button calls it directly in v1. Later, a consent gate (a reminder dialog, a "Did you ask?" checkbox, a spoken announcement) sits in front of that one call and nothing else changes.

**Habit to keep:** start recording, ask, and stop immediately if anyone says no. California requires all-party consent for recording calls.

## Risks and open questions

| Risk | Mitigation |
| --- | --- |
| Bluetooth headset switching mid-call changes the audio format | Handle device-change events; test with AirPods |
| Mic picks up speaker audio | Use headphones; consider voice processing later |
| App crash mid-call | Write audio to disk continuously |
| Long calls fill the disk | Show file size; offer the delete-audio setting |
| Mac sleeps during a call | Hold a power assertion while recording |
| Weak accuracy on accents or jargon | Try a larger model; add custom vocabulary later |

**Open questions**

- Which macOS version are you on? It decides mic capture and whether Core Audio taps are an option.
- Intel or Apple Silicon? Local transcription speed depends on it.
- Keep the audio after transcription, or keep only the text?

## Milestones and build plan

1. **Shell:** menu-bar app with Start/Stop, a timer, and the red indicator. No audio yet.
2. **System audio:** ScreenCaptureKit capture to `them.wav`. Test with a YouTube video.
3. **Mic track:** add `me.wav`. Test with a call to yourself on a second device.
4. **Transcription:** WhisperKit after Stop, merged into `transcript.md`.
5. **Polish:** open-folder actions, error messages, the delete-audio setting.
6. **Real call:** run a Zoom call with a willing friend and check the transcript.

Starter prompt for Claude Code:

```text
Build a macOS menu-bar app in Swift. A Start/Stop button controls recording through a single startRecording() function. Capture system audio with ScreenCaptureKit and the mic with AVAudioEngine, saving each to its own WAV file in ~/Documents/CallCaptures/<date-time>/ as it records. On Stop, transcribe both files locally with WhisperKit and merge them by timestamp into transcript.md, labeled Me and Them. Show a red menu-bar icon while recording. Build in small steps and run the app after each one.
```
