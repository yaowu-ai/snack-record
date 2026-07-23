#import <Foundation/Foundation.h>

#import "../Sources/SnackRecordingSessionGate.h"

static void Assert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"FAIL: %@", message);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        SnackRecordingSessionState idle = {0};
        Assert(SnackRecordingSessionCanStart(idle), @"an idle session can start");
        Assert(!SnackRecordingSessionShouldStop(idle), @"an idle session should not stop");

        SnackRecordingSessionState activeWithStoppedEngine = {
            .recordingMeetingAudio = YES,
        };
        Assert(!SnackRecordingSessionCanStart(activeWithStoppedEngine),
               @"an active meeting cannot restart when the audio engine stops unexpectedly");
        Assert(SnackRecordingSessionShouldStop(activeWithStoppedEngine),
               @"an active meeting with a stopped engine should finalize on the next click");

        SnackRecordingSessionState starting = {
            .recordingStartInProgress = YES,
        };
        Assert(!SnackRecordingSessionCanStart(starting), @"a pending asynchronous start cannot start twice");

        SnackRecordingSessionState stopping = {
            .recordingStopInProgress = YES,
        };
        Assert(!SnackRecordingSessionCanStart(stopping), @"a stopping session cannot start");

        SnackRecordingSessionState finalizing = {
            .finalizingMeetingAudio = YES,
        };
        Assert(!SnackRecordingSessionCanStart(finalizing), @"a finalizing session cannot start");

        NSLog(@"PASS: SnackRecordingSessionGateTests");
    }
    return 0;
}
