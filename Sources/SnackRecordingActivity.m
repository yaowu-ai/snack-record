#import "SnackRecordingActivity.h"

id<NSObject> SnackRecordBeginRecordingActivity(id<SnackRecordingActivityManaging> processInfo) {
    NSActivityOptions options = NSActivityUserInitiated | NSActivityIdleDisplaySleepDisabled;
    return [processInfo beginActivityWithOptions:options reason:@"Recording meeting audio"];
}

void SnackRecordEndRecordingActivity(id<SnackRecordingActivityManaging> processInfo, id<NSObject> activity) {
    if (!activity) return;
    [processInfo endActivity:activity];
}
