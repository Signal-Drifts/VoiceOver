# VoiceOver

Record your voice. Shape it locally.

Current release: **v0.1.0**

VoiceOver is a native macOS recorder that converts a recording toward one of eight bundled reference voices, changes its speed without changing pitch, and optionally reduces quiet background noise. The original recording never leaves the Mac.

## Why this exists

Most voice-changing services require an upload, an account, or a subscription. A private recording should not need to leave the computer just to preview another voice style.

VoiceOver records, converts, previews, and exports on the Mac. Voice conversion uses a bundled local Seed-VC model; speed and noise processing use AVFoundation.

## What it does

- Records up to 5 minutes from the selected macOS microphone
- Pauses, resumes, stops, previews, resets, and restarts a recording
- Provides Female and Male versions of Western, Documentary, Calm, and Hollywood voice styles
- Plays a bundled voice sample when a style is selected
- Converts the recording toward the selected reference voice with Seed-VC
- Caches the normal-speed conversion so later speed changes do not rerun the voice model
- Adjusts speed from 0.25× through 2× while preserving pitch
- Optionally reduces low rumble and quiet background noise
- Saves the untouched original as M4A and the modified recording as WAV
- Keeps the active recording available after either save action

## What it avoids

| Hosted voice tools | VoiceOver |
|---|---|
| Upload the recording to a server | Processes the recording locally |
| Require an account | Requires no account |
| Charge by generated minute | Has no per-minute fee |
| Replace the source after export | Keeps the original recording available |
| Reconvert the voice for every speed | Reuses the cached voice conversion |

## How to use

Download the signed, notarized Apple Silicon installer from the latest GitHub release.

1. Open VoiceOver and allow microphone access.
2. Press Start, record up to 5 minutes, then press Stop.
3. Optionally pick one voice style, adjust speed, and enable Reduce Noise.
4. Press Preview. The first voice conversion can take longer than the recording because it runs locally.
5. Press Save Original for an M4A copy or Save Modified for a WAV copy.
6. Press Reset when you want to delete the current working recording and begin again.

## Tech stack

**Application**

- SwiftUI — native macOS interface and state management
- AVFoundation — microphone capture, playback, waveform analysis, noise processing, pitch-preserving speed, and M4A/WAV encoding

**Voice conversion**

- [Seed-VC](https://github.com/Plachtaa/seed-vc) — local reference-guided voice conversion
- PyTorch with Apple Metal acceleration — local model execution on Apple Silicon
- Eight bundled reference recordings — one Female and one Male sample for each style

## How conversion runs

VoiceOver first records mono PCM audio into a temporary local file. Preview converts that source toward the selected reference voice at normal speed, then caches the result for the current style and noise setting. Speed changes are applied to that cached result, so moving the speed control during playback does not rerun Seed-VC. Choosing another style or changing Reduce Noise invalidates the old conversion and builds a new one. Save Original bypasses every modification; Save Modified writes the current processed result as WAV.

Temporary recordings and previews stay on disk only for the active session. Reset deletes them. Successful saves remain in the folder chosen by the user.

## Honest limits

- This initial version supports recordings up to 5 minutes.
- Voice conversion is not real time. A 10–15 second recording can take roughly 20–30 seconds on the tested Mac, with extra time on the first run while models load.
- A reference voice guides tone and vocal character; it does not guarantee an exact identity, accent, or performance.
- Reduce Noise attenuates quiet background sound and low rumble; it is not full voice isolation.
- The current release targets Apple Silicon Macs running macOS 14 or newer.
- The self-contained installer is large because it includes Python, PyTorch, Seed-VC, and model checkpoints.

## Development

Install `uv`, then prepare the pinned local voice runtime and run the tests:

```bash
./scripts/setup-seed-vc.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build-current
```

Build a signed local test app:

```bash
VOICEOVER_BUILD=1 ./scripts/build-app.sh
```

## Distribution

`./scripts/package-macos.sh` creates a self-contained Apple Silicon app and DMG, signs every bundled executable with Developer ID and the hardened runtime, submits the DMG with Apple's `notarytool`, staples the accepted ticket, and validates it. The script uses the `kiln` keychain notarization profile by default; set `VOICEOVER_SIGNING_IDENTITY` or `VOICEOVER_NOTARY_PROFILE` to override the local release credentials.

## License

VoiceOver application code is MIT licensed. Seed-VC is downloaded from its pinned upstream commit and distributed under GPL-3.0; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the Seed-VC license included in release builds.
