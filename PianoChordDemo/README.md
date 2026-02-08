# PianoChordDemo

A minimal iOS demo for real-time piano chord detection using microphone input.

## What this demo does

- Listens to microphone input in real time.
- Estimates active pitch classes (C, C#, D... B) from FFT/chroma energy.
- Matches them against chord templates.
- Displays:
  - detected chord name (e.g. `C`, `Am7`, `G7`)
  - chord notes (e.g. `C, E, G`)
  - confidence score

## Open and run on iPhone

1. Open `/Users/lizhujun/Documents/GitHub/chords/PianoChordDemo/PianoChordDemo.xcodeproj` in Xcode.
2. Select target `PianoChordDemo`.
3. In `Signing & Capabilities`, choose your Apple Development Team.
4. Connect iPhone and trust the device.
5. Build and run.
6. Tap **Start Listening**.

When prompted, allow microphone access.

## Current detection scope

- Chords: major, minor, diminished, augmented, sus2, sus4, 7, maj7, m7, m7b5, dim7.
- Best range: play triads/seventh chords around middle C with clear attack.

## Notes

- This is a practical MVP detector, not production-grade transcription.
- Acoustic piano environments with heavy noise/reverb can reduce confidence.
- For next iteration, adding MIDI input can greatly improve reliability.
