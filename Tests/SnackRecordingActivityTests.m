#import <Foundation/Foundation.h>

#import "../Sources/SnackRecordingActivity.h"

static void Assert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"FAIL: %@", message);
    exit(1);
}

@interface FakeProcessActivityManager : NSObject <SnackRecordingActivityManaging>
@property(nonatomic) NSActivityOptions options;
@property(nonatomic, strong) id<NSObject> startedToken;
@property(nonatomic, strong) id<NSObject> endedToken;
@property(nonatomic) NSUInteger beginCount;
@property(nonatomic) NSUInteger endCount;
@end

@implementation FakeProcessActivityManager

- (id<NSObject>)beginActivityWithOptions:(NSActivityOptions)options reason:(NSString *)reason {
    self.beginCount += 1;
    self.options = options;
    self.startedToken = [[NSObject alloc] init];
    return self.startedToken;
}

- (void)endActivity:(id<NSObject>)activity {
    self.endCount += 1;
    self.endedToken = activity;
}

@end

int main(void) {
    @autoreleasepool {
        FakeProcessActivityManager *manager = [[FakeProcessActivityManager alloc] init];
        id<NSObject> token = SnackRecordBeginRecordingActivity(manager);

        Assert(token != nil, @"recording activity returns a token");
        Assert(manager.beginCount == 1, @"recording activity begins exactly once");
        Assert((manager.options & NSActivityIdleDisplaySleepDisabled) != 0,
               @"recording activity prevents idle display sleep");
        Assert((manager.options & NSActivityIdleSystemSleepDisabled) != 0,
               @"recording activity prevents idle system sleep");

        SnackRecordEndRecordingActivity(manager, token);
        Assert(manager.endCount == 1, @"recording activity ends exactly once");
        Assert(manager.endedToken == token, @"recording activity ends the matching token");

        SnackRecordEndRecordingActivity(manager, nil);
        Assert(manager.endCount == 1, @"ending a missing recording activity is a no-op");

        NSLog(@"PASS: SnackRecordingActivityTests");
    }
    return 0;
}
