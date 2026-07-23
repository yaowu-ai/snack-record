#import <Foundation/Foundation.h>

typedef struct {
    BOOL audioEngineRunning;
    BOOL recordingMeetingAudio;
    BOOL recordingStartInProgress;
    BOOL recordingStopInProgress;
    BOOL finalizingMeetingAudio;
} SnackRecordingSessionState;

BOOL SnackRecordingSessionCanStart(SnackRecordingSessionState state);
BOOL SnackRecordingSessionShouldStop(SnackRecordingSessionState state);
