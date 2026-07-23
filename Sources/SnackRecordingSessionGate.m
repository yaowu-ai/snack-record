#import "SnackRecordingSessionGate.h"

BOOL SnackRecordingSessionCanStart(SnackRecordingSessionState state) {
    return !state.audioEngineRunning
        && !state.recordingMeetingAudio
        && !state.recordingStartInProgress
        && !state.recordingStopInProgress
        && !state.finalizingMeetingAudio;
}

BOOL SnackRecordingSessionShouldStop(SnackRecordingSessionState state) {
    return state.audioEngineRunning || state.recordingMeetingAudio;
}
