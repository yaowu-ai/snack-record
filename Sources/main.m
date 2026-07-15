#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <UserNotifications/UserNotifications.h>
#include <math.h>

static NSURL *SnackRecordApplicationSupportURL(void) {
    NSURL *applicationSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [applicationSupport URLByAppendingPathComponent:@"Snack Record" isDirectory:YES];
}

static NSString *PythonExecutablePath(void) {
    return [[SnackRecordApplicationSupportURL() URLByAppendingPathComponent:@"Runtime/venv/bin/python"] path];
}

static BOOL HasCompleteModelCacheAtPath(NSString *cachePath) {
    NSArray<NSString *> *models = @[
        @"iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
        @"iic--speech_fsmn_vad_zh-cn-16k-common-pytorch",
        @"iic--punc_ct-transformer_cn-en-common-vocab471067-large",
        @"iic--speech_campplus_sv_zh-cn_16k-common"
    ];
    for (NSString *model in models) {
        NSString *configuration = [cachePath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"models/%@/snapshots/master/configuration.json", model]];
        if (![NSFileManager.defaultManager fileExistsAtPath:configuration]) return NO;
    }
    return YES;
}

static NSString *FFmpegExecutablePath(void) {
    for (NSString *candidate in @[@"/opt/homebrew/bin/ffmpeg", @"/usr/local/bin/ffmpeg", @"/usr/bin/ffmpeg"]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

static NSColor *BrandOrange(void) {
    return [NSColor colorWithSRGBRed:1.0 green:0.45 blue:0.0 alpha:1.0];
}

static NSColor *BrandHeaderBackground(void) {
    return [NSColor colorWithSRGBRed:1.0 green:0.94 blue:0.89 alpha:1.0];
}

static NSColor *AppBackground(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [match isEqualToString:NSAppearanceNameDarkAqua]
            ? [NSColor colorWithSRGBRed:0.08 green:0.08 blue:0.08 alpha:1.0]
            : [NSColor colorWithSRGBRed:0.97 green:0.97 blue:0.96 alpha:1.0];
    }];
}

static NSColor *TaskBackground(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [match isEqualToString:NSAppearanceNameDarkAqua]
            ? [NSColor colorWithSRGBRed:0.14 green:0.14 blue:0.14 alpha:1.0]
            : NSColor.whiteColor;
    }];
}

static NSColor *StatusTextColor(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [match isEqualToString:NSAppearanceNameDarkAqua] ? NSColor.whiteColor : NSColor.secondaryLabelColor;
    }];
}

static NSImage *RoundedApplicationIcon(void) {
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"];
    NSImage *source = [[NSImage alloc] initWithContentsOfFile:iconPath];
    if (!source) return nil;
    NSSize size = NSMakeSize(1024, 1024);
    NSImage *rounded = [[NSImage alloc] initWithSize:size];
    [rounded lockFocus];
    [[NSColor clearColor] setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, size.width, size.height), NSCompositingOperationCopy);
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, size.width, size.height)
                                                         xRadius:220
                                                         yRadius:220];
    [clip addClip];
    [source drawInRect:NSMakeRect(0, 0, size.width, size.height)
              fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver
              fraction:1.0];
    [rounded unlockFocus];
    rounded.template = NO;
    return rounded;
}

typedef NS_ENUM(NSInteger, TranscriptionState) {
    TranscriptionStateReady,
    TranscriptionStateRecording,
    TranscriptionStateFinished,
    TranscriptionStateFailed,
};

typedef NS_ENUM(NSInteger, TranscriptionJobState) {
    TranscriptionJobStateQueued,
    TranscriptionJobStateProcessing,
    TranscriptionJobStateFinished,
    TranscriptionJobStateFailed,
};

static NSString *const TranscriptionModeFast = @"fast";
static NSString *const TranscriptionModeStandard = @"standard";

@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface TaskCardView : NSView
@end

@implementation TaskCardView
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:7 yRadius:7];
    [TaskBackground() setFill];
    [path fill];
    [NSColor.separatorColor setStroke];
    path.lineWidth = 1;
    [path stroke];
}
@end

@interface TranscriptionJob : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) NSURL *recordingURL;
@property(nonatomic, strong) NSURL *temporaryOutputURL;
@property(nonatomic, strong) NSURL *finalOutputURL;
@property(nonatomic, strong) NSDate *startDate;
@property(nonatomic, strong) NSTask *task;
@property(nonatomic) TranscriptionJobState state;
@property(nonatomic, copy) NSString *transcriptionMode;
@property(nonatomic) double progress;
@property(nonatomic, strong) NSDate *progressStartedAt;
@property(nonatomic, strong) NSDate *estimationStartedAt;
@property(nonatomic) double estimationStartProgress;
@property(nonatomic, strong) NSView *rowView;
@property(nonatomic, strong) NSTextField *filenameField;
@property(nonatomic, strong) NSTextField *stateLabel;
@property(nonatomic, strong) NSProgressIndicator *progressIndicator;
@property(nonatomic, strong) NSButton *revealButton;
@property(nonatomic, strong) NSButton *retryButton;
@property(nonatomic) BOOL cancelled;
@end

@implementation TranscriptionJob
@end

@interface TranscriptionController : NSObject <NSTextFieldDelegate, SCStreamOutput, SCStreamDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, copy) NSString *interfaceLanguage;
@property(nonatomic, strong) NSTextField *subtitleLabel;
@property(nonatomic, strong) NSTextField *tasksTitleLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *recordButton;
@property(nonatomic, strong) NSButton *importButton;
@property(nonatomic, strong) NSButton *clearJobsButton;
@property(nonatomic, strong) NSScrollView *jobsScrollView;
@property(nonatomic, strong) FlippedView *jobsDocumentView;
@property(nonatomic, strong) NSPanel *recordingPanel;
@property(nonatomic, strong) NSTextField *recordingTimerLabel;
@property(nonatomic, strong) NSTextField *recordingTitleLabel;
@property(nonatomic, strong) NSTimer *recordingTimer;
@property(nonatomic, strong) AVAudioEngine *audioEngine;
@property(nonatomic, strong) AVAudioFile *audioFile;
@property(nonatomic, strong) SCStream *screenStream;
@property(nonatomic, strong) AVAssetWriter *systemAudioWriter;
@property(nonatomic, strong) AVAssetWriterInput *systemAudioWriterInput;
@property(nonatomic) dispatch_queue_t screenAudioQueue;
@property(nonatomic, strong) NSURL *systemAudioURL;
@property(nonatomic) BOOL systemAudioWriterStarted;
@property(nonatomic) BOOL recordingMeetingAudio;
@property(nonatomic) BOOL finalizingMeetingAudio;
@property(nonatomic, strong) NSURL *recordingURL;
@property(nonatomic, strong) NSDate *recordingStartDate;
@property(nonatomic, strong) NSMutableArray<TranscriptionJob *> *jobs;
@property(nonatomic, strong) NSURL *storageDirectory;
@property(nonatomic, strong) NSURL *recordingsDirectory;
@property(nonatomic, strong) NSURL *jobsMetadataURL;
@property(nonatomic) dispatch_queue_t transcriptionQueue;
@property(nonatomic, strong) NSTask *modelWorkerTask;
@property(nonatomic, strong) NSFileHandle *modelWorkerInput;
@property(nonatomic, strong) NSFileHandle *modelWorkerOutput;
@property(nonatomic, strong) NSMutableData *modelWorkerReadBuffer;
@property(nonatomic) TranscriptionState currentState;
@property(nonatomic, copy) NSString *transcriptionMode;
@property(nonatomic) BOOL waitingForMicrophonePermission;
@property(nonatomic, copy) void (^stateDidChange)(TranscriptionState state);
- (void)toggleRecording;
- (void)startRecordingIfNeeded;
- (void)stopRecordingIfNeeded;
- (void)refreshMicrophoneAuthorization;
- (BOOL)hasPendingTranscriptions;
- (void)cancelTranscriptions;
- (void)applyInterfaceLanguage:(NSString *)language;
- (void)applyTranscriptionMode:(NSString *)mode;
- (void)preloadModels;
- (void)transcribeJob:(TranscriptionJob *)job;
- (BOOL)runWorkerRequest:(NSData *)requestData forJob:(TranscriptionJob *)job;
- (void)shutdownWorker;
@end

@implementation TranscriptionController

- (instancetype)init {
    self = [super init];
    if (self) {
        _audioEngine = [[AVAudioEngine alloc] init];
        _interfaceLanguage = @"en";
        _transcriptionMode = TranscriptionModeFast;
        _jobs = [NSMutableArray array];
        _transcriptionQueue = dispatch_queue_create("local.snack-record.transcription", DISPATCH_QUEUE_SERIAL);
        _screenAudioQueue = dispatch_queue_create("local.snack-record.system-audio", DISPATCH_QUEUE_SERIAL);
        [self configurePersistentStorage];
        [self loadPersistedJobs];
        [self configureWindow];
        [self configureRecordingPanel];
        [self renderState:TranscriptionStateReady message:nil];
        [self preloadModels];
        for (TranscriptionJob *job in self.jobs) {
            if (job.state == TranscriptionJobStateQueued) [self transcribeJob:job];
        }
    }
    return self;
}

- (void)showWindow {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)configurePersistentStorage {
    NSURL *applicationSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    self.storageDirectory = [applicationSupport URLByAppendingPathComponent:@"Snack Record" isDirectory:YES];
    self.recordingsDirectory = [self.storageDirectory URLByAppendingPathComponent:@"Recordings" isDirectory:YES];
    self.jobsMetadataURL = [self.storageDirectory URLByAppendingPathComponent:@"recent-jobs.plist"];
    [NSFileManager.defaultManager createDirectoryAtURL:self.recordingsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)loadPersistedJobs {
    NSArray<NSDictionary *> *storedJobs = [NSArray arrayWithContentsOfURL:self.jobsMetadataURL];
    for (NSDictionary *stored in [storedJobs subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)7, storedJobs.count))]) {
        NSString *audioPath = stored[@"audioPath"];
        if (![audioPath isKindOfClass:NSString.class]) continue;
        TranscriptionJob *job = [[TranscriptionJob alloc] init];
        job.identifier = [stored[@"identifier"] isKindOfClass:NSString.class] ? stored[@"identifier"] : NSUUID.UUID.UUIDString;
        job.recordingURL = [NSURL fileURLWithPath:audioPath];
        NSString *outputPath = stored[@"outputPath"];
        if ([outputPath isKindOfClass:NSString.class] && outputPath.length > 0) job.finalOutputURL = [NSURL fileURLWithPath:outputPath];
        job.startDate = [stored[@"startDate"] isKindOfClass:NSDate.class] ? stored[@"startDate"] : NSDate.date;
        NSString *storedMode = stored[@"transcriptionMode"];
        job.transcriptionMode = [storedMode isEqualToString:TranscriptionModeStandard]
            ? TranscriptionModeStandard
            : TranscriptionModeFast;
        NSInteger storedState = [stored[@"state"] integerValue];
        BOOL canResume = [NSFileManager.defaultManager fileExistsAtPath:job.recordingURL.path];
        if (storedState == TranscriptionJobStateFinished) {
            job.state = TranscriptionJobStateFinished;
        } else if ((storedState == TranscriptionJobStateQueued || storedState == TranscriptionJobStateProcessing) && canResume) {
            job.state = TranscriptionJobStateQueued;
            job.temporaryOutputURL = [[job.recordingURL URLByDeletingLastPathComponent]
                URLByAppendingPathComponent:[NSString stringWithFormat:@"result-%@.txt", NSUUID.UUID.UUIDString]];
        } else {
            job.state = TranscriptionJobStateFailed;
        }
        job.filenameField = [[NSTextField alloc] init];
        NSString *filename = stored[@"filename"];
        job.filenameField.stringValue = [filename isKindOfClass:NSString.class] ? filename : [self defaultFilenameForDate:job.startDate];
        job.filenameField.delegate = self;
        [self.jobs addObject:job];
    }
}

- (void)persistJobs {
    NSMutableArray<NSDictionary *> *storedJobs = [NSMutableArray array];
    for (TranscriptionJob *job in self.jobs) {
        [storedJobs addObject:@{
            @"identifier": job.identifier ?: NSUUID.UUID.UUIDString,
            @"audioPath": job.recordingURL.path ?: @"",
            @"outputPath": job.finalOutputURL.path ?: @"",
            @"filename": job.filenameField.stringValue ?: @"",
            @"startDate": job.startDate ?: NSDate.date,
            @"state": @(job.state),
            @"transcriptionMode": job.transcriptionMode ?: TranscriptionModeFast,
        }];
    }
    [storedJobs writeToURL:self.jobsMetadataURL atomically:YES];
}

- (void)trimJobHistoryIfNeeded {
    while (self.jobs.count > 7) {
        TranscriptionJob *oldest = self.jobs.lastObject;
        if ([oldest.recordingURL.path hasPrefix:self.recordingsDirectory.path]) {
            [NSFileManager.defaultManager removeItemAtURL:oldest.recordingURL error:nil];
        }
        [self.jobs removeLastObject];
    }
}

- (BOOL)isChineseInterface {
    return [self.interfaceLanguage isEqualToString:@"zh"];
}

- (NSString *)english:(NSString *)english chinese:(NSString *)chinese {
    return [self isChineseInterface] ? chinese : english;
}

- (void)applyInterfaceLanguage:(NSString *)language {
    self.interfaceLanguage = [language isEqualToString:@"zh"] ? @"zh" : @"en";
    self.subtitleLabel.stringValue = [self english:@"RECORD  ·  Local meeting transcription" chinese:@"RECORD  ·  本地会议录音与转写"];
    self.tasksTitleLabel.stringValue = [self english:@"Transcription tasks" chinese:@"转写任务"];
    self.importButton.title = [self english:@"Upload local audio" chinese:@"上传本地音频文件"];
    [self styleImportButtonTitle];
    self.importButton.toolTip = [self english:@"Choose local audio files to transcribe" chinese:@"选择本地音频文件进行转写"];
    self.clearJobsButton.toolTip = [self english:@"Clear transcription tasks" chinese:@"清空转写任务"];
    [self rebuildJobsView];
    [self renderState:self.currentState message:nil];
}

- (void)applyTranscriptionMode:(NSString *)mode {
    self.transcriptionMode = [mode isEqualToString:TranscriptionModeStandard]
        ? TranscriptionModeStandard
        : TranscriptionModeFast;
}

- (void)configureWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 520)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    self.window.title = @"Snack Record";
    self.window.releasedWhenClosed = NO;
    self.window.contentMinSize = NSMakeSize(500, 520);
    self.window.backgroundColor = AppBackground();
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    [self.window center];

    NSView *view = self.window.contentView;

    NSBox *brandHeader = [[NSBox alloc] initWithFrame:NSMakeRect(0, 400, 500, 120)];
    brandHeader.boxType = NSBoxCustom;
    brandHeader.borderWidth = 0;
    brandHeader.fillColor = BrandHeaderBackground();
    brandHeader.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [view addSubview:brandHeader];

    NSString *logoPath = [NSBundle.mainBundle pathForResource:@"SnackLogo" ofType:@"png"];
    NSImageView *logoView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 444, 190, 58)];
    logoView.image = [[NSImage alloc] initWithContentsOfFile:logoPath];
    logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
    logoView.imageAlignment = NSImageAlignLeft;
    logoView.autoresizingMask = NSViewMinYMargin;
    [view addSubview:logoView];

    self.subtitleLabel = [NSTextField labelWithString:@"RECORD  ·  Local meeting transcription"];
    self.subtitleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.subtitleLabel.textColor = [NSColor colorWithSRGBRed:0.16 green:0.14 blue:0.12 alpha:0.72];
    self.subtitleLabel.frame = NSMakeRect(22, 420, 270, 20);
    self.subtitleLabel.autoresizingMask = NSViewMinYMargin;
    [view addSubview:self.subtitleLabel];

    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = StatusTextColor();
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.statusLabel.frame = NSMakeRect(94, 365, 312, 22);
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [view addSubview:self.statusLabel];

    self.recordButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:@"Start recording"] target:self action:@selector(toggleRecording:)];
    self.recordButton.bezelStyle = NSBezelStyleCircular;
    self.recordButton.imagePosition = NSImageOnly;
    self.recordButton.toolTip = @"Start meeting recording (Control+R)";
    self.recordButton.bezelColor = BrandOrange();
    self.recordButton.contentTintColor = NSColor.whiteColor;
    self.recordButton.frame = NSMakeRect(426, 434, 52, 52);
    self.recordButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [view addSubview:self.recordButton];

    NSBox *divider = [[NSBox alloc] initWithFrame:NSMakeRect(20, 352, 460, 1)];
    divider.boxType = NSBoxSeparator;
    divider.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [view addSubview:divider];

    self.tasksTitleLabel = [NSTextField labelWithString:@"Transcription tasks"];
    self.tasksTitleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.tasksTitleLabel.frame = NSMakeRect(20, 320, 200, 20);
    self.tasksTitleLabel.autoresizingMask = NSViewMinYMargin;
    [view addSubview:self.tasksTitleLabel];

    self.importButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"square.and.arrow.up" accessibilityDescription:@"上传本地音频文件"] target:self action:@selector(importAudioFiles:)];
    self.importButton.title = @"Upload local audio";
    self.importButton.imagePosition = NSImageLeading;
    self.importButton.bezelStyle = NSBezelStyleRounded;
    self.importButton.bezelColor = BrandOrange();
    self.importButton.contentTintColor = NSColor.whiteColor;
    self.importButton.toolTip = @"Choose local audio files to transcribe";
    self.importButton.frame = NSMakeRect(274, 313, 162, 30);
    self.importButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self styleImportButtonTitle];
    [view addSubview:self.importButton];

    self.clearJobsButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"trash" accessibilityDescription:@"清空转写任务"] target:self action:@selector(clearAllJobs:)];
    self.clearJobsButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.clearJobsButton.imagePosition = NSImageOnly;
    self.clearJobsButton.contentTintColor = NSColor.systemRedColor;
    self.clearJobsButton.toolTip = @"清空转写任务";
    self.clearJobsButton.frame = NSMakeRect(446, 313, 34, 30);
    self.clearJobsButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [view addSubview:self.clearJobsButton];

    self.jobsDocumentView = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 452, 280)];
    self.jobsDocumentView.autoresizingMask = NSViewWidthSizable;
    self.jobsScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 22, 460, 286)];
    self.jobsScrollView.documentView = self.jobsDocumentView;
    self.jobsScrollView.hasVerticalScroller = YES;
    self.jobsScrollView.autohidesScrollers = YES;
    self.jobsScrollView.drawsBackground = NO;
    self.jobsScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [view addSubview:self.jobsScrollView];

    [self rebuildJobsView];
}

- (void)styleImportButtonTitle {
    self.importButton.attributedTitle = [[NSAttributedString alloc] initWithString:self.importButton.title
                                                                        attributes:@{
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
    }];
}

- (void)importAudioFiles:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = [self english:@"Choose audio to transcribe" chinese:@"选择要转写的音频"];
    panel.prompt = [self english:@"Upload" chinese:@"上传"];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray array];
    for (NSString *extension in @[@"wav", @"m4a", @"mp3", @"aac", @"flac", @"ogg", @"caf", @"aiff", @"mp4", @"mov"]) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if (type) [contentTypes addObject:type];
    }
    panel.allowedContentTypes = contentTypes;
    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        for (NSURL *url in panel.URLs) {
            NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
            NSDate *startDate = attributes[NSFileCreationDate] ?: NSDate.date;
            NSString *baseName = url.lastPathComponent.stringByDeletingPathExtension;
            NSString *fallbackName = [weakSelf english:@"Local audio" chinese:@"本地音频"];
            NSString *suffix = [weakSelf english:@"-transcript.txt" chinese:@"-转写.txt"];
            NSString *filename = [NSString stringWithFormat:@"%@%@", baseName.length > 0 ? baseName : fallbackName, suffix];
            [weakSelf enqueueRecordingURL:url startDate:startDate suggestedFilename:filename];
        }
        [weakSelf renderState:TranscriptionStateReady message:[weakSelf english:@"Local files added to the transcription queue" chinese:@"本地文件已加入转写任务"]];
    }];
}

- (void)clearAllJobs:(id)sender {
    if (self.jobs.count == 0) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [self english:@"Clear all transcription tasks?" chinese:@"清空全部转写任务？"];
    alert.informativeText = [self english:@"Queued and running tasks will be cancelled, and cached audio will be deleted. TXT files already saved to Desktop will not be deleted." chinese:@"等待中和正在处理的任务将被取消，内部音频缓存会被删除；已经保存到桌面的 TXT 文件不会被删除。"];
    [alert addButtonWithTitle:[self english:@"Cancel" chinese:@"取消"]];
    [alert addButtonWithTitle:[self english:@"Clear" chinese:@"清空"]];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertSecondButtonReturn) return;
        for (TranscriptionJob *job in self.jobs) {
            job.cancelled = YES;
            if (job.task.isRunning) [job.task terminate];
            if ([job.recordingURL.path hasPrefix:self.recordingsDirectory.path]) {
                [NSFileManager.defaultManager removeItemAtURL:job.recordingURL error:nil];
            }
            if ([job.temporaryOutputURL.path hasPrefix:self.storageDirectory.path]) {
                [NSFileManager.defaultManager removeItemAtURL:job.temporaryOutputURL error:nil];
            }
        }
        [self.jobs removeAllObjects];
        [self persistJobs];
        [self rebuildJobsView];
        if (!self.audioEngine.isRunning) [self renderState:TranscriptionStateReady message:nil];
    }];
}

- (void)configureRecordingPanel {
    self.recordingPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 248, 78)
                                                     styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    self.recordingPanel.opaque = NO;
    self.recordingPanel.backgroundColor = NSColor.clearColor;
    self.recordingPanel.hasShadow = YES;
    self.recordingPanel.level = NSStatusWindowLevel;
    self.recordingPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSVisualEffectView *card = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 248, 78)];
    card.material = NSVisualEffectMaterialHUDWindow;
    card.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    card.state = NSVisualEffectStateActive;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 10;
    card.layer.masksToBounds = YES;
    self.recordingPanel.contentView = card;

    NSImageView *recordingIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(18, 27, 24, 24)];
    recordingIcon.image = [NSImage imageWithSystemSymbolName:@"record.circle.fill" accessibilityDescription:@"正在录音"];
    recordingIcon.contentTintColor = NSColor.systemRedColor;
    [card addSubview:recordingIcon];

    self.recordingTitleLabel = [NSTextField labelWithString:@"Recording meeting"];
    self.recordingTitleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.recordingTitleLabel.frame = NSMakeRect(52, 40, 136, 20);
    [card addSubview:self.recordingTitleLabel];

    self.recordingTimerLabel = [NSTextField labelWithString:@"00:00"];
    self.recordingTimerLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.recordingTimerLabel.textColor = NSColor.secondaryLabelColor;
    self.recordingTimerLabel.frame = NSMakeRect(52, 17, 100, 20);
    [card addSubview:self.recordingTimerLabel];

    NSButton *stopButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"stop.fill" accessibilityDescription:@"停止录音"] target:self action:@selector(stopRecordingFromCard:)];
    stopButton.bezelStyle = NSBezelStyleCircular;
    stopButton.imagePosition = NSImageOnly;
    stopButton.contentTintColor = NSColor.systemRedColor;
    stopButton.toolTip = @"Stop and transcribe";
    stopButton.frame = NSMakeRect(196, 21, 36, 36);
    [card addSubview:stopButton];
}

- (void)showRecordingCard {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visibleFrame = screen.visibleFrame;
    NSSize size = self.recordingPanel.frame.size;
    [self.recordingPanel setFrameOrigin:NSMakePoint(NSMaxX(visibleFrame) - size.width - 20,
                                                     NSMaxY(visibleFrame) - size.height - 20)];
    [self.recordingPanel orderFrontRegardless];
    [self.recordingTimer invalidate];
    self.recordingTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateRecordingTimer:) userInfo:nil repeats:YES];
    [self updateRecordingTimer:nil];
}

- (void)hideRecordingCard {
    [self.recordingTimer invalidate];
    self.recordingTimer = nil;
    [self.recordingPanel orderOut:nil];
}

- (void)updateRecordingTimer:(NSTimer *)timer {
    NSTimeInterval elapsed = self.recordingStartDate ? [NSDate.date timeIntervalSinceDate:self.recordingStartDate] : 0;
    NSInteger totalSeconds = MAX(0, (NSInteger)elapsed);
    self.recordingTimerLabel.stringValue = [NSString stringWithFormat:@"%02ld:%02ld", (long)(totalSeconds / 60), (long)(totalSeconds % 60)];
}

- (void)stopRecordingFromCard:(id)sender { [self stopRecordingIfNeeded]; }
- (void)toggleRecording:(id)sender { [self toggleRecording]; }

- (void)toggleRecording {
    if (self.audioEngine.isRunning) {
        [self stopRecording];
    } else if (!self.finalizingMeetingAudio) {
        [self startRecording];
    }
}

- (void)startRecordingIfNeeded {
    if (!self.audioEngine.isRunning && !self.finalizingMeetingAudio) {
        [self startRecording];
    }
}

- (void)stopRecordingIfNeeded {
    if (self.audioEngine.isRunning) {
        [self stopRecording];
    }
}

- (void)startRecording {
    __weak typeof(self) weakSelf = self;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                weakSelf.waitingForMicrophonePermission = YES;
                [weakSelf renderState:TranscriptionStateFailed message:[weakSelf english:@"Allow microphone access in System Settings" chinese:@"请在系统设置中允许麦克风访问"]];
                return;
            }
            weakSelf.waitingForMicrophonePermission = NO;
            weakSelf.recordingMeetingAudio = YES;
            [weakSelf beginSystemAudioCapture];
        });
    }];
}

- (void)beginSystemAudioCapture {
    self.recordButton.enabled = NO;
    self.statusLabel.stringValue = [self english:@"Requesting system audio access…" chinese:@"正在请求会议音频访问…"];
    __weak typeof(self) weakSelf = self;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent *content, NSError *contentError) {
        if (contentError || content.displays.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.recordButton.enabled = YES;
                [weakSelf renderState:TranscriptionStateFailed message:[weakSelf english:@"Allow screen and system audio recording, then try again" chinese:@"请允许屏幕与系统音频录制后重试"]];
            });
            return;
        }

        SCDisplay *selectedDisplay = content.displays.firstObject;
        CGDirectDisplayID mainDisplayID = CGMainDisplayID();
        for (SCDisplay *display in content.displays) {
            if (display.displayID == mainDisplayID) {
                selectedDisplay = display;
                break;
            }
        }

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:selectedDisplay excludingWindows:@[]];
        SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
        configuration.capturesAudio = YES;
        configuration.excludesCurrentProcessAudio = YES;
        configuration.sampleRate = 48000;
        configuration.channelCount = 2;
        configuration.width = 2;
        configuration.height = 2;
        configuration.minimumFrameInterval = CMTimeMake(1, 1);

        NSError *directoryError = nil;
        NSURL *directory = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"SnackRecord" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&directoryError];
        weakSelf.systemAudioURL = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"system-%@.m4a", NSUUID.UUID.UUIDString]];
        [[NSFileManager defaultManager] removeItemAtURL:weakSelf.systemAudioURL error:nil];

        NSError *writerError = nil;
        weakSelf.systemAudioWriter = [[AVAssetWriter alloc] initWithURL:weakSelf.systemAudioURL fileType:AVFileTypeAppleM4A error:&writerError];
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @48000,
            AVNumberOfChannelsKey: @2,
            AVEncoderBitRateKey: @128000,
        };
        weakSelf.systemAudioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:settings];
        weakSelf.systemAudioWriterInput.expectsMediaDataInRealTime = YES;
        if (writerError || ![weakSelf.systemAudioWriter canAddInput:weakSelf.systemAudioWriterInput]) {
            [weakSelf failStartingSystemAudio:[weakSelf english:@"Unable to prepare meeting audio" chinese:@"无法准备会议音频文件"]];
            return;
        }
        [weakSelf.systemAudioWriter addInput:weakSelf.systemAudioWriterInput];
        weakSelf.systemAudioWriterStarted = NO;

        weakSelf.screenStream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:weakSelf];
        NSError *outputError = nil;
        if (![weakSelf.screenStream addStreamOutput:weakSelf type:SCStreamOutputTypeAudio sampleHandlerQueue:weakSelf.screenAudioQueue error:&outputError]) {
            [weakSelf failStartingSystemAudio:[weakSelf english:@"Unable to capture system audio" chinese:@"无法读取会议音频"]];
            return;
        }
        [weakSelf.screenStream startCaptureWithCompletionHandler:^(NSError *startError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (startError) {
                    [weakSelf failStartingSystemAudio:[weakSelf english:@"Allow screen and system audio recording, then try again" chinese:@"请允许屏幕与系统音频录制后重试"]];
                } else {
                    weakSelf.recordButton.enabled = YES;
                    [weakSelf beginAudioCapture];
                }
            });
        }];
    }];
}

- (void)failStartingSystemAudio:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.screenStream = nil;
        self.systemAudioWriter = nil;
        self.systemAudioWriterInput = nil;
        self.systemAudioURL = nil;
        self.recordingMeetingAudio = NO;
        self.recordButton.enabled = YES;
        [self renderState:TranscriptionStateFailed message:message];
    });
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeAudio || !CMSampleBufferDataIsReady(sampleBuffer)) return;
    if (!self.systemAudioWriterStarted) {
        if (![self.systemAudioWriter startWriting]) return;
        [self.systemAudioWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
        self.systemAudioWriterStarted = YES;
    }
    if (self.systemAudioWriterInput.readyForMoreMediaData) {
        [self.systemAudioWriterInput appendSampleBuffer:sampleBuffer];
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (!self.finalizingMeetingAudio) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopRecordingIfNeeded];
            [self renderState:TranscriptionStateFailed message:[self english:@"System audio capture was interrupted" chinese:@"会议音频采集已中断"]];
        });
    }
}

- (void)refreshMicrophoneAuthorization {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (self.waitingForMicrophonePermission && status == AVAuthorizationStatusAuthorized) {
        self.waitingForMicrophonePermission = NO;
        [self renderState:TranscriptionStateReady message:nil];
    }
}

- (void)beginAudioCapture {
    NSError *error = nil;
    NSURL *directory = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"SnackRecord" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        [self renderState:TranscriptionStateFailed message:[self english:@"Unable to create a temporary recording file" chinese:@"无法创建临时录音文件"]];
        return;
    }

    self.recordingURL = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"recording-%@.wav", NSUUID.UUID.UUIDString]];
    AVAudioInputNode *input = self.audioEngine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    self.audioFile = [[AVAudioFile alloc] initForWriting:self.recordingURL settings:format.settings commonFormat:format.commonFormat interleaved:format.isInterleaved error:&error];
    if (error || !self.audioFile) {
        [self renderState:TranscriptionStateFailed message:[self english:@"Unable to prepare recording" chinese:@"无法准备录音"]];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [input removeTapOnBus:0];
    [input installTapOnBus:0 bufferSize:2048 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        NSError *writeError = nil;
        [weakSelf.audioFile writeFromBuffer:buffer error:&writeError];
        if (writeError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf renderState:TranscriptionStateFailed message:[weakSelf english:@"Unable to write recording" chinese:@"录音写入失败"]];
            });
        }
    }];

    [self.audioEngine prepare];
    if (![self.audioEngine startAndReturnError:&error]) {
        [input removeTapOnBus:0];
        [self renderState:TranscriptionStateFailed message:[self english:@"Unable to start recording" chinese:@"无法开始录音"]];
        return;
    }
    self.recordingStartDate = NSDate.date;
    [self renderState:TranscriptionStateRecording message:nil];
}

- (void)stopRecording {
    NSURL *microphoneURL = self.recordingURL;
    NSDate *startDate = self.recordingStartDate ?: NSDate.date;
    BOOL wasMeetingRecording = self.recordingMeetingAudio;
    [self.audioEngine.inputNode removeTapOnBus:0];
    [self.audioEngine stop];
    self.audioFile = nil;
    if (!microphoneURL) {
        [self renderState:TranscriptionStateFailed message:[self english:@"Recording file was not found" chinese:@"未找到录音文件"]];
        return;
    }

    self.recordingURL = nil;
    self.recordingStartDate = nil;
    if (wasMeetingRecording && self.screenStream) {
        self.finalizingMeetingAudio = YES;
        [self renderState:TranscriptionStateReady message:[self english:@"Preparing meeting audio…" chinese:@"正在整理会议音频…"]];
        self.recordButton.enabled = NO;
        __weak typeof(self) weakSelf = self;
        [self.screenStream stopCaptureWithCompletionHandler:^(NSError *stopError) {
            dispatch_async(weakSelf.screenAudioQueue, ^{
                [weakSelf finishSystemAudioRecordingWithMicrophoneURL:microphoneURL startDate:startDate];
            });
        }];
        return;
    }

    self.recordingMeetingAudio = NO;
    [self enqueueRecordingURL:microphoneURL startDate:startDate suggestedFilename:nil];
}

- (void)finishSystemAudioRecordingWithMicrophoneURL:(NSURL *)microphoneURL startDate:(NSDate *)startDate {
    AVAssetWriter *writer = self.systemAudioWriter;
    if (!self.systemAudioWriterStarted || writer.status != AVAssetWriterStatusWriting) {
        [writer cancelWriting];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishMeetingPreparationWithURL:microphoneURL startDate:startDate message:[self english:@"No system audio detected; transcribing microphone audio" chinese:@"未检测到系统声音，已转写麦克风"]];
        });
        return;
    }

    [self.systemAudioWriterInput markAsFinished];
    __weak typeof(self) weakSelf = self;
    [writer finishWritingWithCompletionHandler:^{
        [weakSelf mixMicrophoneURL:microphoneURL systemURL:weakSelf.systemAudioURL startDate:startDate];
    }];
}

- (void)mixMicrophoneURL:(NSURL *)microphoneURL systemURL:(NSURL *)systemURL startDate:(NSDate *)startDate {
    NSURL *combinedURL = [[microphoneURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:[NSString stringWithFormat:@"meeting-%@.wav", NSUUID.UUID.UUIDString]];
    NSString *ffmpegPath = FFmpegExecutablePath();
    if (!ffmpegPath) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishMeetingPreparationWithURL:systemURL startDate:startDate message:[self english:@"FFmpeg not found; transcribing system audio" chinese:@"未找到 FFmpeg，已转写系统声音"]];
        });
        return;
    }
    NSTask *mixTask = [[NSTask alloc] init];
    mixTask.executableURL = [NSURL fileURLWithPath:ffmpegPath];
    mixTask.arguments = @[@"-y", @"-i", microphoneURL.path, @"-i", systemURL.path,
                          @"-filter_complex", @"[0:a][1:a]amix=inputs=2:duration=longest:normalize=1",
                          @"-ac", @"1", @"-ar", @"16000", combinedURL.path];
    mixTask.standardOutput = [NSPipe pipe];
    mixTask.standardError = [NSPipe pipe];
    NSError *launchError = nil;
    BOOL launched = [mixTask launchAndReturnError:&launchError];
    if (launched) [mixTask waitUntilExit];
    NSURL *resultURL = launched && mixTask.terminationStatus == 0 ? combinedURL : systemURL;
    NSString *message = resultURL == combinedURL
        ? [self english:@"Meeting audio added to the transcription queue" chinese:@"会议音频已加入转写任务"]
        : [self english:@"Audio mixing failed; transcribing system audio" chinese:@"混音失败，已转写系统声音"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishMeetingPreparationWithURL:resultURL startDate:startDate message:message];
    });
}

- (void)finishMeetingPreparationWithURL:(NSURL *)recordingURL startDate:(NSDate *)startDate message:(NSString *)message {
    self.screenStream = nil;
    self.systemAudioWriter = nil;
    self.systemAudioWriterInput = nil;
    self.systemAudioURL = nil;
    self.systemAudioWriterStarted = NO;
    self.recordingMeetingAudio = NO;
    self.finalizingMeetingAudio = NO;
    self.recordButton.enabled = YES;
    [self enqueueRecordingURL:recordingURL startDate:startDate suggestedFilename:nil];
    [self renderState:TranscriptionStateReady message:message];
}

- (void)enqueueRecordingURL:(NSURL *)recordingURL startDate:(NSDate *)startDate suggestedFilename:(NSString *)suggestedFilename {
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSString *extension = recordingURL.pathExtension.length > 0 ? recordingURL.pathExtension : @"wav";
    NSURL *cachedURL = [self.recordingsDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", identifier, extension]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *copyError = nil;
        [NSFileManager.defaultManager copyItemAtURL:recordingURL toURL:cachedURL error:&copyError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (copyError) {
                [self renderState:TranscriptionStateFailed message:[self english:@"Unable to cache the audio file" chinese:@"无法缓存本地音频文件"]];
                return;
            }
            [self createJobWithIdentifier:identifier recordingURL:cachedURL startDate:startDate suggestedFilename:suggestedFilename];
        });
    });
}

- (void)createJobWithIdentifier:(NSString *)identifier recordingURL:(NSURL *)recordingURL startDate:(NSDate *)startDate suggestedFilename:(NSString *)suggestedFilename {
    TranscriptionJob *job = [[TranscriptionJob alloc] init];
    job.identifier = identifier;
    job.recordingURL = recordingURL;
    job.startDate = startDate;
    job.state = TranscriptionJobStateQueued;
    job.transcriptionMode = self.transcriptionMode ?: TranscriptionModeFast;
    job.progress = 0.0;
    job.temporaryOutputURL = [[job.recordingURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:[NSString stringWithFormat:@"result-%@.txt", NSUUID.UUID.UUIDString]];
    job.filenameField = [[NSTextField alloc] init];
    job.filenameField.stringValue = suggestedFilename ?: [self defaultFilenameForDate:job.startDate];
    job.filenameField.delegate = self;
    [self.jobs insertObject:job atIndex:0];
    [self trimJobHistoryIfNeeded];
    [self persistJobs];
    [self rebuildJobsView];

    [self renderState:TranscriptionStateReady message:[self english:@"Added to the queue. You can record again." chinese:@"已加入转写任务，可以继续录音"]];
    [self transcribeJob:job];
}

- (NSString *)defaultFilenameForDate:(NSDate *)date {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    return [NSString stringWithFormat:@"Snack Record-%@.txt", [formatter stringFromDate:date]];
}

- (void)updateProgress:(double)progress forJob:(TranscriptionJob *)job {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (job.cancelled || job.state != TranscriptionJobStateProcessing) return;
        job.progress = MAX(job.progress, MIN(100.0, progress));
        if (!job.estimationStartedAt && job.progress >= 8.0) {
            job.estimationStartedAt = NSDate.date;
            job.estimationStartProgress = job.progress;
        }
        [self updateJobRow:job];
    });
}

- (NSMutableDictionary<NSString *, NSString *> *)workerEnvironment {
    NSMutableDictionary<NSString *, NSString *> *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *modelCache = [[SnackRecordApplicationSupportURL() URLByAppendingPathComponent:@"Models"] path];
    if (HasCompleteModelCacheAtPath(modelCache)) {
        environment[@"MODELSCOPE_CACHE"] = modelCache;
    } else {
        [environment removeObjectForKey:@"MODELSCOPE_CACHE"];
    }
    environment[@"PYTHONUNBUFFERED"] = @"1";
    NSString *ffmpeg = FFmpegExecutablePath();
    if (ffmpeg) environment[@"FFMPEG_PATH"] = ffmpeg;
    return environment;
}

- (void)clearWorkerReferences {
    self.modelWorkerTask = nil;
    self.modelWorkerInput = nil;
    self.modelWorkerOutput = nil;
    self.modelWorkerReadBuffer = nil;
}

- (NSString *)readWorkerLine {
    if (!self.modelWorkerOutput) return nil;
    if (!self.modelWorkerReadBuffer) self.modelWorkerReadBuffer = [NSMutableData data];
    NSData *newlineData = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    while (YES) {
        NSRange searchRange = NSMakeRange(0, self.modelWorkerReadBuffer.length);
        NSRange newline = [self.modelWorkerReadBuffer rangeOfData:newlineData options:0 range:searchRange];
        if (newline.location != NSNotFound) {
            NSData *lineData = [self.modelWorkerReadBuffer subdataWithRange:NSMakeRange(0, newline.location)];
            [self.modelWorkerReadBuffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(newline)) withBytes:NULL length:0];
            return [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        }
        NSData *chunk = self.modelWorkerOutput.availableData;
        if (chunk.length == 0) return nil;
        [self.modelWorkerReadBuffer appendData:chunk];
    }
}

- (NSDictionary *)readWorkerEvent {
    while (self.modelWorkerTask.isRunning || self.modelWorkerReadBuffer.length > 0) {
        NSString *line = [self readWorkerLine];
        if (!line) return nil;
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *event = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([event isKindOfClass:NSDictionary.class]) return event;
    }
    return nil;
}

- (BOOL)startWorkerIfNeeded {
    if (self.modelWorkerTask.isRunning && self.modelWorkerInput && self.modelWorkerOutput) return YES;
    [self clearWorkerReferences];

    NSString *pythonExecutable = PythonExecutablePath();
    NSString *script = [NSBundle.mainBundle pathForResource:@"funasr_transcribe" ofType:@"py"];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:pythonExecutable] || !script) return NO;

    NSTask *task = [[NSTask alloc] init];
    NSPipe *inputPipe = [NSPipe pipe];
    NSPipe *outputPipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:pythonExecutable];
    task.arguments = @[script, @"--worker"];
    task.environment = [self workerEnvironment];
    task.standardInput = inputPipe;
    task.standardOutput = outputPipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) return NO;

    self.modelWorkerTask = task;
    self.modelWorkerInput = inputPipe.fileHandleForWriting;
    self.modelWorkerOutput = outputPipe.fileHandleForReading;
    self.modelWorkerReadBuffer = [NSMutableData data];
    while (task.isRunning) {
        NSDictionary *event = [self readWorkerEvent];
        if (!event) break;
        if ([event[@"type"] isEqualToString:@"ready"]) return YES;
    }
    if (task.isRunning) [task terminate];
    [self clearWorkerReferences];
    return NO;
}

- (void)preloadModels {
    dispatch_async(self.transcriptionQueue, ^{ [self startWorkerIfNeeded]; });
}

- (void)shutdownWorker {
    if (self.modelWorkerTask.isRunning) [self.modelWorkerTask terminate];
}

- (BOOL)runWorkerRequest:(NSData *)requestData forJob:(TranscriptionJob *)job {
    if (![self startWorkerIfNeeded]) return NO;
    @try {
        [self.modelWorkerInput writeData:requestData];
    } @catch (NSException *exception) {
        return NO;
    }

    job.task = self.modelWorkerTask;
    BOOL completed = NO;
    while (self.modelWorkerTask.isRunning && !job.cancelled) {
        NSDictionary *event = [self readWorkerEvent];
        if (!event) break;
        if (![event[@"id"] isEqualToString:job.identifier]) continue;
        NSString *type = event[@"type"];
        if ([type isEqualToString:@"progress"]) {
            [self updateProgress:[event[@"percent"] doubleValue] forJob:job];
        } else if ([type isEqualToString:@"completed"]) {
            completed = YES;
            break;
        } else if ([type isEqualToString:@"error"]) {
            break;
        }
    }
    job.task = nil;
    return completed && [NSFileManager.defaultManager fileExistsAtPath:job.temporaryOutputURL.path];
}

- (void)transcribeJob:(TranscriptionJob *)job {
    dispatch_async(self.transcriptionQueue, ^{
        if (job.cancelled) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (job.cancelled) return;
            job.state = TranscriptionJobStateProcessing;
            job.progress = 0.0;
            job.progressStartedAt = NSDate.date;
            job.estimationStartedAt = nil;
            job.estimationStartProgress = 0.0;
            [self updateJobRow:job];
            [self persistJobs];
        });

        if (![NSFileManager.defaultManager isExecutableFileAtPath:PythonExecutablePath()]) {
            [self failJob:job message:[self english:@"Local FunASR environment not found" chinese:@"未找到本地环境"]];
            return;
        }
        NSDateFormatter *startFormatter = [[NSDateFormatter alloc] init];
        startFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"];
        startFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSString *mode = [job.transcriptionMode isEqualToString:TranscriptionModeStandard]
            ? TranscriptionModeStandard
            : TranscriptionModeFast;
        NSDictionary *request = @{
            @"id": job.identifier,
            @"input": job.recordingURL.path,
            @"output": job.temporaryOutputURL.path,
            @"start_time": [startFormatter stringFromDate:job.startDate],
            @"mode": mode,
        };
        NSMutableData *requestData = [[NSJSONSerialization dataWithJSONObject:request options:0 error:nil] mutableCopy];
        [requestData appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        BOOL completed = NO;
        for (NSInteger attempt = 0; attempt < 2 && !job.cancelled; attempt++) {
            completed = [self runWorkerRequest:requestData forJob:job];
            if (completed) break;
            [NSFileManager.defaultManager removeItemAtURL:job.temporaryOutputURL error:nil];
            [self shutdownWorker];
            [self clearWorkerReferences];
            if (attempt == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    job.progress = 0.0;
                    job.progressStartedAt = NSDate.date;
                    job.estimationStartedAt = nil;
                    job.estimationStartProgress = 0.0;
                    [self updateJobRow:job];
                });
            }
        }
        if (job.cancelled) {
            [NSFileManager.defaultManager removeItemAtURL:job.temporaryOutputURL error:nil];
            return;
        }
        if (!completed) {
            if (!self.modelWorkerTask.isRunning) [self clearWorkerReferences];
            [self failJob:job message:[self english:@"Transcription failed" chinese:@"转写失败"]];
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishJob:job];
        });
    });
}

- (void)failJob:(TranscriptionJob *)job message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (job.cancelled) return;
        job.state = TranscriptionJobStateFailed;
        job.stateLabel.stringValue = message;
        [self updateJobRow:job];
        [self persistJobs];
    });
}

- (NSString *)safeFilename:(NSString *)filename {
    NSString *trimmed = [filename stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/:\\"];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:invalid];
    NSString *safe = [parts componentsJoinedByString:@"-"];
    if (safe.length == 0) safe = [self defaultFilenameForDate:NSDate.date];
    if (![safe.pathExtension.lowercaseString isEqualToString:@"txt"]) safe = [safe stringByAppendingPathExtension:@"txt"];
    return safe;
}

- (NSURL *)availableDesktopURLForFilename:(NSString *)filename {
    NSURL *desktop = [NSFileManager.defaultManager URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *candidate = [desktop URLByAppendingPathComponent:filename];
    NSString *stem = filename.stringByDeletingPathExtension;
    NSInteger suffix = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:candidate.path]) {
        candidate = [desktop URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%ld.txt", stem, (long)suffix++]];
    }
    return candidate;
}

- (void)finishJob:(TranscriptionJob *)job {
    if (job.cancelled) return;
    NSString *filename = [self safeFilename:job.filenameField.stringValue];
    job.filenameField.stringValue = filename;
    NSURL *destination = [self availableDesktopURLForFilename:filename];
    NSError *moveError = nil;
    [NSFileManager.defaultManager moveItemAtURL:job.temporaryOutputURL toURL:destination error:&moveError];
    if (moveError) {
        job.state = TranscriptionJobStateFailed;
        job.stateLabel.stringValue = [self english:@"Unable to save" chinese:@"保存失败"];
        [self updateJobRow:job];
        [self persistJobs];
        return;
    }
    job.finalOutputURL = destination;
    job.state = TranscriptionJobStateFinished;
    job.progress = 100.0;
    job.filenameField.stringValue = destination.lastPathComponent;
    [self updateJobRow:job];
    [self persistJobs];

    NSString *text = [NSString stringWithContentsOfURL:destination encoding:NSUTF8StringEncoding error:nil];
    if (text) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    }
    [self sendCompletionNotificationForURL:destination];
    [self renderState:self.audioEngine.isRunning ? TranscriptionStateRecording : TranscriptionStateReady message:nil];
}

- (void)sendCompletionNotificationForURL:(NSURL *)outputURL {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [self english:@"Transcription complete" chinese:@"转写完成"];
    content.body = [self english:[NSString stringWithFormat:@"Saved %@ to Desktop", outputURL.lastPathComponent]
                            chinese:[NSString stringWithFormat:@"%@ 已保存到桌面", outputURL.lastPathComponent]];
    content.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

- (void)rebuildJobsView {
    self.clearJobsButton.enabled = self.jobs.count > 0;
    for (NSView *subview in self.jobsDocumentView.subviews.copy) [subview removeFromSuperview];
    CGFloat rowHeight = 78;
    CGFloat contentHeight = MAX(278, self.jobs.count * rowHeight);
    CGFloat contentWidth = MAX(460, self.jobsScrollView.contentSize.width);
    self.jobsDocumentView.frame = NSMakeRect(0, 0, contentWidth, contentHeight);

    if (self.jobs.count == 0) {
        NSTextField *empty = [NSTextField labelWithString:[self english:@"Recordings and imported files will appear here" chinese:@"录音结束后，转写任务会显示在这里"]];
        empty.textColor = NSColor.tertiaryLabelColor;
        empty.alignment = NSTextAlignmentCenter;
        empty.frame = NSMakeRect(30, 112, MAX(200, self.jobsDocumentView.bounds.size.width - 60), 22);
        empty.autoresizingMask = NSViewWidthSizable;
        [self.jobsDocumentView addSubview:empty];
        return;
    }

    [self.jobs enumerateObjectsUsingBlock:^(TranscriptionJob *job, NSUInteger index, BOOL *stop) {
        [self configureRowForJob:job y:index * rowHeight];
        [self.jobsDocumentView addSubview:job.rowView];
    }];
}

- (void)configureRowForJob:(TranscriptionJob *)job y:(CGFloat)y {
    CGFloat rowWidth = MAX(360, self.jobsDocumentView.bounds.size.width);
    job.rowView = [[TaskCardView alloc] initWithFrame:NSMakeRect(0, y + 4, rowWidth, 70)];
    job.rowView.autoresizingMask = NSViewWidthSizable;

    job.filenameField.frame = NSMakeRect(14, 34, rowWidth - 114, 24);
    job.filenameField.autoresizingMask = NSViewWidthSizable;
    job.filenameField.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    job.filenameField.placeholderString = [self english:@"Transcript filename.txt" chinese:@"转写文件名.txt"];
    job.filenameField.toolTip = [self english:@"Rename before transcription finishes" chinese:@"可在转写完成前修改保存文件名"];
    [job.rowView addSubview:job.filenameField];

    job.progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(15, 11, 14, 14)];
    job.progressIndicator.style = NSProgressIndicatorStyleSpinning;
    job.progressIndicator.controlSize = NSControlSizeSmall;
    [job.rowView addSubview:job.progressIndicator];

    job.stateLabel = [NSTextField labelWithString:@""];
    job.stateLabel.font = [NSFont systemFontOfSize:11];
    job.stateLabel.textColor = NSColor.secondaryLabelColor;
    job.stateLabel.frame = NSMakeRect(36, 8, rowWidth - 136, 19);
    job.stateLabel.autoresizingMask = NSViewWidthSizable;
    [job.rowView addSubview:job.stateLabel];

    job.revealButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"doc.text" accessibilityDescription:@"打开转写文件"] target:self action:@selector(openJobOutput:)];
    job.revealButton.bezelStyle = NSBezelStyleTexturedRounded;
    job.revealButton.imagePosition = NSImageOnly;
    job.revealButton.toolTip = [self english:@"Open transcript" chinese:@"打开转写文件"];
    job.revealButton.contentTintColor = BrandOrange();
    job.revealButton.tag = [self.jobs indexOfObjectIdenticalTo:job];
    job.revealButton.frame = NSMakeRect(rowWidth - 54, 31, 34, 30);
    job.revealButton.autoresizingMask = NSViewMinXMargin;
    [job.rowView addSubview:job.revealButton];

    job.retryButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"重新转写"] target:self action:@selector(retryJob:)];
    job.retryButton.bezelStyle = NSBezelStyleTexturedRounded;
    job.retryButton.imagePosition = NSImageOnly;
    job.retryButton.toolTip = [self english:@"Transcribe again" chinese:@"重新转写"];
    job.retryButton.contentTintColor = NSColor.systemBlueColor;
    job.retryButton.identifier = job.identifier;
    job.retryButton.frame = NSMakeRect(rowWidth - 94, 31, 34, 30);
    job.retryButton.autoresizingMask = NSViewMinXMargin;
    [job.rowView addSubview:job.retryButton];
    [self updateJobRow:job];
}

- (NSString *)remainingTimeText:(NSTimeInterval)seconds {
    NSInteger total = MAX(1, (NSInteger)ceil(seconds));
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger remainingSeconds = total % 60;
    if ([self isChineseInterface]) {
        if (hours > 0) return [NSString stringWithFormat:@"%ld小时%ld分钟", (long)hours, (long)minutes];
        if (minutes > 0) return [NSString stringWithFormat:@"%ld分%ld秒", (long)minutes, (long)remainingSeconds];
        return [NSString stringWithFormat:@"%ld秒", (long)remainingSeconds];
    }
    if (hours > 0) return [NSString stringWithFormat:@"%ldh %ldm", (long)hours, (long)minutes];
    if (minutes > 0) return [NSString stringWithFormat:@"%ldm %lds", (long)minutes, (long)remainingSeconds];
    return [NSString stringWithFormat:@"%lds", (long)remainingSeconds];
}

- (NSString *)processingTextForJob:(TranscriptionJob *)job {
    BOOL standard = [job.transcriptionMode isEqualToString:TranscriptionModeStandard];
    NSString *modeName = standard
        ? [self english:@"Standard" chinese:@"标准转写"]
        : [self english:@"Fast" chinese:@"快速转写"];
    NSInteger percent = MAX(0, MIN(99, (NSInteger)llround(job.progress)));
    if (percent < 8 || !job.progressStartedAt) {
        return [self english:[NSString stringWithFormat:@"%@ %ld%% · Preparing models…", modeName, (long)percent]
                         chinese:[NSString stringWithFormat:@"%@ %ld%% · 正在准备模型…", modeName, (long)percent]];
    }
    NSTimeInterval elapsed = job.estimationStartedAt ? [NSDate.date timeIntervalSinceDate:job.estimationStartedAt] : 0.0;
    double completedSinceEstimate = job.progress - job.estimationStartProgress;
    if (elapsed < 2.0 || completedSinceEstimate < 1.0) {
        return [self english:[NSString stringWithFormat:@"%@ %ld%% · Calculating remaining time…", modeName, (long)percent]
                         chinese:[NSString stringWithFormat:@"%@ %ld%% · 正在计算剩余时间…", modeName, (long)percent]];
    }
    NSTimeInterval remaining = (100.0 - job.progress) / (completedSinceEstimate / elapsed);
    NSString *duration = [self remainingTimeText:remaining];
    return [self english:[NSString stringWithFormat:@"%@ %ld%% · About %@ remaining", modeName, (long)percent, duration]
                     chinese:[NSString stringWithFormat:@"%@ %ld%% · 预计剩余 %@", modeName, (long)percent, duration]];
}

- (void)updateJobRow:(TranscriptionJob *)job {
    BOOL audioAvailable = [NSFileManager.defaultManager fileExistsAtPath:job.recordingURL.path];
    BOOL outputAvailable = job.finalOutputURL && [NSFileManager.defaultManager fileExistsAtPath:job.finalOutputURL.path];
    job.retryButton.enabled = audioAvailable && job.state != TranscriptionJobStateQueued && job.state != TranscriptionJobStateProcessing;
    NSColor *retryColor = job.retryButton.enabled ? NSColor.systemBlueColor : NSColor.tertiaryLabelColor;
    job.retryButton.contentTintColor = retryColor;
    switch (job.state) {
        case TranscriptionJobStateQueued:
            job.stateLabel.frame = NSMakeRect(36, 8, job.rowView.bounds.size.width - 136, 19);
            job.stateLabel.stringValue = [self english:@"Waiting…" chinese:@"等待处理…"];
            job.stateLabel.textColor = NSColor.secondaryLabelColor;
            job.progressIndicator.hidden = NO;
            [job.progressIndicator startAnimation:nil];
            job.revealButton.enabled = NO;
            job.filenameField.editable = YES;
            break;
        case TranscriptionJobStateProcessing:
            job.stateLabel.frame = NSMakeRect(36, 8, job.rowView.bounds.size.width - 136, 19);
            job.stateLabel.stringValue = [self processingTextForJob:job];
            job.stateLabel.textColor = NSColor.secondaryLabelColor;
            job.progressIndicator.hidden = NO;
            [job.progressIndicator startAnimation:nil];
            job.revealButton.enabled = NO;
            job.filenameField.editable = YES;
            break;
        case TranscriptionJobStateFinished:
            job.stateLabel.frame = NSMakeRect(14, 8, job.rowView.bounds.size.width - 114, 19);
            job.stateLabel.stringValue = outputAvailable
                ? [self english:@"Complete · Local file available" chinese:@"已完成 · 本地有效"]
                : [self english:@"Complete · Local file missing" chinese:@"已完成 · 本地失效"];
            job.stateLabel.textColor = outputAvailable ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
            [job.progressIndicator stopAnimation:nil];
            job.progressIndicator.hidden = YES;
            job.filenameField.editable = NO;
            job.revealButton.enabled = outputAvailable;
            break;
        case TranscriptionJobStateFailed:
            job.stateLabel.frame = NSMakeRect(14, 8, job.rowView.bounds.size.width - 114, 19);
            if (job.stateLabel.stringValue.length == 0) job.stateLabel.stringValue = [self english:@"Transcription failed" chinese:@"转写失败"];
            job.stateLabel.textColor = NSColor.systemOrangeColor;
            [job.progressIndicator stopAnimation:nil];
            job.progressIndicator.hidden = YES;
            job.filenameField.editable = YES;
            job.revealButton.enabled = outputAvailable;
            break;
    }
    job.revealButton.contentTintColor = job.revealButton.enabled ? BrandOrange() : NSColor.tertiaryLabelColor;
    job.revealButton.toolTip = outputAvailable
        ? [self english:@"Open transcript" chinese:@"打开转写文件"]
        : [self english:@"File not found" chinese:@"文件未找到"];
    if (!audioAvailable && job.state != TranscriptionJobStateProcessing) {
        job.retryButton.enabled = NO;
        job.retryButton.toolTip = [self english:@"Audio cache not found" chinese:@"音频缓存未找到"];
        job.stateLabel.stringValue = [self english:@"Audio cache missing · Local data invalid" chinese:@"音频缓存丢失 · 本地失效"];
        job.stateLabel.textColor = NSColor.systemOrangeColor;
    }
}

- (void)openJobOutput:(NSButton *)sender {
    NSInteger index = sender.tag;
    if (index >= 0 && index < (NSInteger)self.jobs.count) {
        TranscriptionJob *job = self.jobs[index];
        if (!job.finalOutputURL || ![NSFileManager.defaultManager fileExistsAtPath:job.finalOutputURL.path]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.alertStyle = NSAlertStyleWarning;
            alert.messageText = [self english:@"File not found" chinese:@"文件未找到"];
            alert.informativeText = [self english:@"The transcript was moved or deleted. You can transcribe the cached audio again." chinese:@"桌面上的转写文件可能已被移动或删除，可以使用缓存音频重新转写。"];
            [alert addButtonWithTitle:[self english:@"OK" chinese:@"知道了"]];
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
            [self updateJobRow:job];
            [self persistJobs];
            return;
        }
        [NSWorkspace.sharedWorkspace openURL:job.finalOutputURL];
    }
}

- (void)retryJob:(NSButton *)sender {
    TranscriptionJob *job = nil;
    for (TranscriptionJob *candidate in self.jobs) {
        if ([candidate.identifier isEqualToString:sender.identifier]) {
            job = candidate;
            break;
        }
    }
    if (!job) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:job.recordingURL.path]) {
        [self updateJobRow:job];
        return;
    }
    job.state = TranscriptionJobStateQueued;
    job.cancelled = NO;
    job.transcriptionMode = self.transcriptionMode ?: TranscriptionModeFast;
    job.progress = 0.0;
    job.progressStartedAt = nil;
    job.estimationStartedAt = nil;
    job.estimationStartProgress = 0.0;
    job.temporaryOutputURL = [self.storageDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"result-%@.txt", NSUUID.UUID.UUIDString]];
    job.filenameField.editable = YES;
    job.progressIndicator.hidden = NO;
    job.stateLabel.stringValue = @"";
    job.stateLabel.textColor = NSColor.secondaryLabelColor;
    [self updateJobRow:job];
    [self persistJobs];
    [self transcribeJob:job];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSTextField *field = notification.object;
    for (TranscriptionJob *job in self.jobs) {
        if (job.filenameField == field) {
            [self persistJobs];
            break;
        }
    }
}

- (BOOL)hasPendingTranscriptions {
    for (TranscriptionJob *job in self.jobs) {
        if (!job.cancelled && (job.state == TranscriptionJobStateQueued || job.state == TranscriptionJobStateProcessing)) return YES;
    }
    return NO;
}

- (void)cancelTranscriptions {
    for (TranscriptionJob *job in self.jobs) {
        if (job.task.isRunning) [job.task terminate];
    }
}

- (void)renderState:(TranscriptionState)state message:(NSString *)message {
    self.currentState = state;
    NSString *symbol = @"mic.fill";
    NSString *status = message ?: [self english:@"Click record or press Control+R to start" chinese:@"点击录音或按 Control+R 开始"];
    NSString *tooltip = [self english:@"Start meeting recording (Control+R)" chinese:@"开始会议录音（Control+R）"];
    NSColor *color = BrandOrange();

    switch (state) {
        case TranscriptionStateRecording:
            symbol = @"stop.fill";
            status = [self english:@"Recording system audio and microphone" chinese:@"正在录制系统音频与麦克风"];
            tooltip = [self english:@"Stop and transcribe" chinese:@"停止录音并转写"];
            color = NSColor.systemRedColor;
            self.recordingTitleLabel.stringValue = [self english:@"Recording meeting" chinese:@"正在录制会议"];
            break;
        case TranscriptionStateFinished:
            symbol = @"mic.fill";
            status = message ?: [self english:@"Transcript saved to Desktop" chinese:@"转写已保存到桌面"];
            color = NSColor.systemGreenColor;
            break;
        case TranscriptionStateFailed:
            symbol = @"exclamationmark.triangle";
            status = message ?: [self english:@"Something went wrong. Please try again." chinese:@"出现错误，请重试"];
            color = NSColor.systemOrangeColor;
            break;
        case TranscriptionStateReady:
            break;
    }

    self.statusLabel.stringValue = status;
    self.recordButton.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tooltip];
    self.recordButton.toolTip = tooltip;
    self.recordButton.bezelColor = state == TranscriptionStateRecording ? NSColor.systemRedColor : BrandOrange();
    self.recordButton.contentTintColor = NSColor.whiteColor;
    self.recordButton.enabled = YES;
    if (state == TranscriptionStateRecording) [self showRecordingCard]; else [self hideRecordingCard];
    if (self.stateDidChange) self.stateDidChange(state);
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, UNUserNotificationCenterDelegate>
@property(nonatomic, strong) TranscriptionController *controller;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSImage *statusIcon;
@property(nonatomic, strong) NSMenuItem *startRecordingItem;
@property(nonatomic, strong) NSMenuItem *stopRecordingItem;
@property(nonatomic, strong) NSMenuItem *showWindowItem;
@property(nonatomic, strong) NSMenuItem *quitItem;
@property(nonatomic, strong) NSMenuItem *mainQuitItem;
@property(nonatomic, strong) NSMenuItem *interfaceLanguageItem;
@property(nonatomic, strong) NSMenuItem *englishInterfaceItem;
@property(nonatomic, strong) NSMenuItem *chineseInterfaceItem;
@property(nonatomic, strong) NSMenuItem *transcriptionModeItem;
@property(nonatomic, strong) NSMenuItem *fastTranscriptionItem;
@property(nonatomic, strong) NSMenuItem *standardTranscriptionItem;
@property(nonatomic, copy) NSString *interfaceLanguage;
@property(nonatomic, copy) NSString *transcriptionMode;
@property(nonatomic, strong) id shortcutMonitor;
@property(nonatomic) EventHotKeyRef recordingHotKey;
@property(nonatomic) EventHandlerRef hotKeyEventHandler;
- (void)handleGlobalRecordingShortcut;
@end

static const OSType SnackRecordHotKeySignature = 'SnRc';
static const UInt32 SnackRecordHotKeyIdentifier = 1;

static OSStatus HandleSnackRecordHotKey(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    EventHotKeyID hotKeyID = {0};
    OSStatus status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                        NULL, sizeof(hotKeyID), NULL, &hotKeyID);
    if (status == noErr && hotKeyID.signature == SnackRecordHotKeySignature &&
        hotKeyID.id == SnackRecordHotKeyIdentifier) {
        AppDelegate *delegate = (__bridge AppDelegate *)userData;
        dispatch_async(dispatch_get_main_queue(), ^{ [delegate handleGlobalRecordingShortcut]; });
        return noErr;
    }
    return CallNextEventHandler(nextHandler, event);
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *error) {}];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        @"SnackRecordInterfaceLanguage": @"zh",
        @"SnackRecordTranscriptionMode": TranscriptionModeFast,
    }];
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"SnackRecordChineseDefaultsApplied"]) {
        [NSUserDefaults.standardUserDefaults setObject:@"zh" forKey:@"SnackRecordInterfaceLanguage"];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"SnackRecordChineseDefaultsApplied"];
    }
    self.interfaceLanguage = [NSUserDefaults.standardUserDefaults stringForKey:@"SnackRecordInterfaceLanguage"] ?: @"en";
    self.transcriptionMode = [NSUserDefaults.standardUserDefaults stringForKey:@"SnackRecordTranscriptionMode"] ?: TranscriptionModeFast;
    NSImage *applicationIcon = RoundedApplicationIcon();
    if (applicationIcon) NSApp.applicationIconImage = applicationIcon;
    self.controller = [[TranscriptionController alloc] init];
    [self.controller applyInterfaceLanguage:self.interfaceLanguage];
    [self.controller applyTranscriptionMode:self.transcriptionMode];
    self.controller.window.miniwindowImage = applicationIcon;
    self.controller.window.miniwindowTitle = @"Snack Record";
    [self configureStatusItem];
    [self configureMainMenu];
    __weak typeof(self) weakSelf = self;
    self.controller.stateDidChange = ^(TranscriptionState state) { [weakSelf updateStatusItemForState:state]; };
    [self updateStatusItemForState:TranscriptionStateReady];
    [self configureShortcut];
    [self.controller showWindow];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)configureShortcut {
    EventTypeSpec eventType = {kEventClassKeyboard, kEventHotKeyPressed};
    OSStatus handlerStatus = InstallApplicationEventHandler(&HandleSnackRecordHotKey, 1, &eventType,
                                                             (__bridge void *)self, &_hotKeyEventHandler);
    EventHotKeyID hotKeyID = {SnackRecordHotKeySignature, SnackRecordHotKeyIdentifier};
    OSStatus registrationStatus = handlerStatus == noErr
        ? RegisterEventHotKey(kVK_ANSI_R, controlKey, hotKeyID, GetApplicationEventTarget(),
                              0, &_recordingHotKey)
        : handlerStatus;
    if (registrationStatus == noErr) return;

    if (self.hotKeyEventHandler) {
        RemoveEventHandler(self.hotKeyEventHandler);
        self.hotKeyEventHandler = NULL;
    }
    __weak typeof(self) weakSelf = self;
    self.shortcutMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        NSString *key = event.charactersIgnoringModifiers.lowercaseString;
        if (modifiers == NSEventModifierFlagControl && [key isEqualToString:@"r"]) {
            [weakSelf.controller startRecordingIfNeeded];
            return nil;
        }
        return event;
    }];
}

- (void)handleGlobalRecordingShortcut {
    [self.controller startRecordingIfNeeded];
}

- (NSImage *)menuBarTemplateIcon {
    NSImage *icon = RoundedApplicationIcon();
    icon.size = NSMakeSize(20, 20);
    icon.template = NO;
    return icon;
}

- (BOOL)isChineseInterface {
    return [self.interfaceLanguage isEqualToString:@"zh"];
}

- (void)updateLanguageMenus {
    BOOL chinese = [self isChineseInterface];
    self.startRecordingItem.title = chinese ? @"开始录音" : @"Start recording";
    self.stopRecordingItem.title = chinese ? @"停止录音" : @"Stop recording";
    self.transcriptionModeItem.title = chinese ? @"转写模式" : @"Transcription mode";
    self.fastTranscriptionItem.title = chinese ? @"快速转写（不区分说话人）" : @"Fast transcription (no speakers)";
    self.standardTranscriptionItem.title = chinese ? @"标准转写（区分说话人）" : @"Standard transcription (speakers)";
    self.interfaceLanguageItem.title = chinese ? @"系统语言" : @"Language";
    self.showWindowItem.title = chinese ? @"显示窗口" : @"Show window";
    self.quitItem.title = chinese ? @"退出 Snack Record" : @"Quit Snack Record";
    self.mainQuitItem.title = chinese ? @"退出 Snack Record" : @"Quit Snack Record";
    self.englishInterfaceItem.state = chinese ? NSControlStateValueOff : NSControlStateValueOn;
    self.chineseInterfaceItem.state = chinese ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL standard = [self.transcriptionMode isEqualToString:TranscriptionModeStandard];
    self.fastTranscriptionItem.state = standard ? NSControlStateValueOff : NSControlStateValueOn;
    self.standardTranscriptionItem.state = standard ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)changeInterfaceLanguage:(NSString *)language {
    self.interfaceLanguage = [language isEqualToString:@"zh"] ? @"zh" : @"en";
    [NSUserDefaults.standardUserDefaults setObject:self.interfaceLanguage forKey:@"SnackRecordInterfaceLanguage"];
    [self.controller applyInterfaceLanguage:self.interfaceLanguage];
    [self updateLanguageMenus];
}

- (void)selectEnglishInterface:(id)sender { [self changeInterfaceLanguage:@"en"]; }
- (void)selectChineseInterface:(id)sender { [self changeInterfaceLanguage:@"zh"]; }

- (void)changeTranscriptionMode:(NSString *)mode {
    self.transcriptionMode = [mode isEqualToString:TranscriptionModeStandard]
        ? TranscriptionModeStandard
        : TranscriptionModeFast;
    [NSUserDefaults.standardUserDefaults setObject:self.transcriptionMode forKey:@"SnackRecordTranscriptionMode"];
    [self.controller applyTranscriptionMode:self.transcriptionMode];
    [self updateLanguageMenus];
}

- (void)selectFastTranscription:(id)sender { [self changeTranscriptionMode:TranscriptionModeFast]; }
- (void)selectStandardTranscription:(id)sender { [self changeTranscriptionMode:TranscriptionModeStandard]; }

- (void)configureStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusIcon = [self menuBarTemplateIcon];
    self.statusItem.button.image = self.statusIcon;
    self.statusItem.button.imageScaling = NSImageScaleProportionallyDown;
    self.statusItem.button.contentTintColor = nil;
    self.statusItem.button.toolTip = @"Snack Record";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Snack Record"];
    self.startRecordingItem = [[NSMenuItem alloc] initWithTitle:@"Start recording" action:@selector(startRecordingFromMenu:) keyEquivalent:@""];
    self.startRecordingItem.target = self;
    [menu addItem:self.startRecordingItem];
    self.stopRecordingItem = [[NSMenuItem alloc] initWithTitle:@"Stop recording" action:@selector(stopRecordingFromMenu:) keyEquivalent:@""];
    self.stopRecordingItem.target = self;
    [menu addItem:self.stopRecordingItem];
    [menu addItem:NSMenuItem.separatorItem];

    self.transcriptionModeItem = [[NSMenuItem alloc] initWithTitle:@"Transcription mode" action:nil keyEquivalent:@""];
    NSMenu *transcriptionModeMenu = [[NSMenu alloc] initWithTitle:@"Transcription mode"];
    self.fastTranscriptionItem = [[NSMenuItem alloc] initWithTitle:@"Fast transcription (no speakers)" action:@selector(selectFastTranscription:) keyEquivalent:@""];
    self.fastTranscriptionItem.target = self;
    [transcriptionModeMenu addItem:self.fastTranscriptionItem];
    self.standardTranscriptionItem = [[NSMenuItem alloc] initWithTitle:@"Standard transcription (speakers)" action:@selector(selectStandardTranscription:) keyEquivalent:@""];
    self.standardTranscriptionItem.target = self;
    [transcriptionModeMenu addItem:self.standardTranscriptionItem];
    self.transcriptionModeItem.submenu = transcriptionModeMenu;
    [menu addItem:self.transcriptionModeItem];

    self.interfaceLanguageItem = [[NSMenuItem alloc] initWithTitle:@"Language" action:nil keyEquivalent:@""];
    NSMenu *interfaceMenu = [[NSMenu alloc] initWithTitle:@"Language"];
    self.englishInterfaceItem = [[NSMenuItem alloc] initWithTitle:@"English" action:@selector(selectEnglishInterface:) keyEquivalent:@""];
    self.englishInterfaceItem.target = self;
    [interfaceMenu addItem:self.englishInterfaceItem];
    self.chineseInterfaceItem = [[NSMenuItem alloc] initWithTitle:@"中文" action:@selector(selectChineseInterface:) keyEquivalent:@""];
    self.chineseInterfaceItem.target = self;
    [interfaceMenu addItem:self.chineseInterfaceItem];
    self.interfaceLanguageItem.submenu = interfaceMenu;
    [menu addItem:self.interfaceLanguageItem];

    [menu addItem:NSMenuItem.separatorItem];
    self.showWindowItem = [[NSMenuItem alloc] initWithTitle:@"Show window" action:@selector(showWindowFromMenu:) keyEquivalent:@""];
    self.showWindowItem.target = self;
    [menu addItem:self.showWindowItem];
    [menu addItem:NSMenuItem.separatorItem];
    self.quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Snack Record" action:@selector(quitFromMenu:) keyEquivalent:@"q"];
    self.quitItem.target = self;
    [menu addItem:self.quitItem];
    self.statusItem.menu = menu;
    [self updateLanguageMenus];
}

- (void)configureMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *applicationMenuItem = [[NSMenuItem alloc] initWithTitle:@"Snack Record" action:nil keyEquivalent:@""];
    [mainMenu addItem:applicationMenuItem];

    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"Snack Record"];
    self.mainQuitItem = [[NSMenuItem alloc] initWithTitle:@"退出 Snack Record" action:@selector(quitFromMenu:) keyEquivalent:@"q"];
    self.mainQuitItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.mainQuitItem.target = self;
    [applicationMenu addItem:self.mainQuitItem];
    applicationMenuItem.submenu = applicationMenu;
    NSApp.mainMenu = mainMenu;
    [self updateLanguageMenus];
}

- (void)startRecordingFromMenu:(id)sender { [self.controller startRecordingIfNeeded]; }
- (void)stopRecordingFromMenu:(id)sender { [self.controller stopRecordingIfNeeded]; }
- (void)showWindowFromMenu:(id)sender { [self.controller showWindow]; }
- (void)quitFromMenu:(id)sender { [NSApp terminate:nil]; }

- (void)updateStatusItemForState:(TranscriptionState)state {
    self.startRecordingItem.enabled = state != TranscriptionStateRecording;
    self.stopRecordingItem.enabled = state == TranscriptionStateRecording;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (![self.controller hasPendingTranscriptions]) return NSTerminateNow;
    BOOL chinese = [self isChineseInterface];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = chinese ? @"仍有转写任务正在处理" : @"Transcription is still in progress";
    alert.informativeText = chinese ? @"现在退出会中断尚未完成的转写，相关文本可能不会保存。" : @"Quitting now will interrupt unfinished tasks and their transcripts may not be saved.";
    [alert addButtonWithTitle:chinese ? @"继续处理" : @"Keep processing"];
    [alert addButtonWithTitle:chinese ? @"退出" : @"Quit"];
    if ([alert runModal] == NSAlertSecondButtonReturn) {
        [self.controller cancelTranscriptions];
        return NSTerminateNow;
    }
    return NSTerminateCancel;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { [self.controller showWindow]; return NO; }
- (void)applicationDidBecomeActive:(NSNotification *)notification { [self.controller refreshMicrophoneAuthorization]; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.shortcutMonitor) [NSEvent removeMonitor:self.shortcutMonitor];
    if (self.recordingHotKey) UnregisterEventHotKey(self.recordingHotKey);
    if (self.hotKeyEventHandler) RemoveEventHandler(self.hotKeyEventHandler);
    [self.controller shutdownWorker];
}

@end


int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        NSImage *applicationIcon = RoundedApplicationIcon();
        if (applicationIcon) application.applicationIconImage = applicationIcon;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
