# Privacy

Snack Record performs transcription on the local Mac.

## Local data

The app stores runtime files, downloaded models, cached recordings, and the seven most recent task records in:

```text
~/Library/Application Support/Snack Record/
```

Completed TXT transcripts are saved to Desktop. Clearing the task list removes cached recordings and task metadata, but does not delete TXT files already saved to Desktop.

## Network use

The installation script downloads Python dependencies and speech models. Normal recording and transcription do not require uploading audio to an external transcription service.

## Permissions

The app requests microphone, system audio/screen capture, Desktop folder, and notification permissions. ScreenCaptureKit is configured for audio capture; the app does not save screen video.
