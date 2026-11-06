# CallCapture

A personal Mac menu-bar app that records both sides of a call and turns it into
a local text transcript, labeled Me and Them.

## What it does

- Works with any call app (FaceTime, Zoom, Teams, Meet) by capturing system
  audio, with no per-app integration.
- Records two separate tracks: the other participants through system audio
  (`them.wav`) and you through the microphone (`me.wav`). Keeping them separate
  gives the Me and Them labels without speaker detection.
- Writes audio to disk as it records, so a crash loses seconds, not the call.
- After you press Stop, transcribes each track locally with Whisper and merges
  them by timestamp into `transcript.md`. No audio leaves the Mac.
- Lives in the menu bar: Start/Stop, a status line with a timer, Open Last
  Transcript and Open Recordings Folder. The icon turns red while recording.

Each call gets its own folder:

```text
~/Documents/CallCaptures/2026-10-28_1400/
  me.wav
  them.wav
  transcript.md
```

## Who it's for

It's a personal tool for keeping notes on my own calls. It isn't signed for
distribution or on the App Store.

**Consent:** the app has no consent feature. Start recording, ask everyone on
the call aloud whether they're OK being recorded, and stop right away if anyone
says no. California and several other states require every party's consent.

## How it's built

- **Swift and SwiftUI**, using `MenuBarExtra` for the menu-bar UI
- **ScreenCaptureKit** for system audio
- **AVAudioEngine** for the microphone, including handling a format change when
  a Bluetooth headset switches mid-call
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** (Core ML) for local
  transcription with a quantized Whisper large-v3 turbo model, downloaded on
  first use

### Built with Claude Code

I wrote the design first: [DESIGN.md](DESIGN.md) covers the goals, scope,
architecture, the transcription options I weighed, permissions, risks and a
milestone plan, and ends with the starter prompt I gave Claude Code. I then
built the app with Claude Code one milestone at a time; every milestone commit
is co-authored with Claude.

## Run it

You need a Mac on macOS 26.6 or later (the project's deployment target) and
Xcode. Apple Silicon is recommended for transcription speed.

1. Open `CallCapture.xcodeproj` in Xcode. Swift Package Manager fetches
   WhisperKit.
2. Under Signing & Capabilities, choose your own team. A free Apple ID is
   enough for personal use. Keep the same signing identity between builds, or
   macOS may ask for permissions again.
3. Build and run. The app appears in the menu bar, not the Dock.
4. The first time you press Start, allow **Screen & System Audio Recording** and
   **Microphone** in System Settings under Privacy & Security.
5. The first transcription downloads the Whisper model (about 626 MB) to
   `~/Library/Application Support/CallCapture/Models`.

Use headphones. With speakers, the mic re-records the other side and the Me
track fills with their audio.

## Status

Milestones 1–4 of the [build plan](DESIGN.md#milestones-and-build-plan) are
done: the menu-bar shell, system audio, the mic track and local transcription.
Still to come: polish (better error messages and a setting to delete audio after
transcription) and a test on a real call.
