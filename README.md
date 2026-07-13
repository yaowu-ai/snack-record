# Snack Record

Local macOS meeting recorder and Chinese transcription app powered by FunASR.

## Features

- Captures system audio and microphone audio with ScreenCaptureKit.
- Transcribes locally with Paraformer, punctuation, VAD, and speaker diarization.
- Imports local audio and video files.
- Saves TXT transcripts to Desktop.
- Keeps the seven most recent tasks and cached audio locally.
- Offers fast transcription without speaker labels and standard transcription with speaker diarization.
- Shows transcription percentage and estimated remaining time for long audio.
- Preloads the local models once at app launch and reuses them across transcription tasks.
- Supports Chinese and English UI.

## AI coding tool installation

Ask your AI coding tool to clone this repository, review `install.sh`, and run:

```bash
chmod +x install.sh build.sh scripts/download_models.py
./install.sh
```

The installer builds the app on the current Mac and uses ad-hoc signing. It does not require a Developer ID certificate or access to another person's signing identity.

The first installation downloads about 2 GB of speech models. The app is installed to:

```text
~/Applications/Snack Record.app
```

Runtime files and models are stored under:

```text
~/Library/Application Support/Snack Record/
```

## Requirements

- macOS 15 or later recommended
- Apple Silicon Mac
- Xcode Command Line Tools
- Python 3
- Homebrew and FFmpeg
- Internet connection during first installation

## Privacy

- Audio, task history, and transcripts are processed locally.
- Recordings and task metadata are not uploaded by Snack Record.
- Model files are downloaded from ModelScope during installation.
- ScreenCaptureKit permission is used to capture system audio; screen video is not saved.

See [PRIVACY.md](PRIVACY.md) for storage locations and deletion behavior.

## Signing

`install.sh` uses ad-hoc signing for source-based local installation. Privacy permissions may need to be granted again after rebuilding or updating the app. A Developer ID certificate is required only when distributing a prebuilt app or DMG that should pass Gatekeeper normally.

## Third-party models

FunASR and each downloaded ModelScope model may have separate licenses. Review the upstream repository and model cards before redistributing model files. This repository does not bundle model weights.

## License

Source code is provided under the MIT License. Third-party dependencies, models, and brand assets remain subject to their respective licenses.
