#import <XCTest/XCTest.h>
#include <signal.h>

@interface JortBrokerFaultTests : XCTestCase
@end

@implementation JortBrokerFaultTests
- (NSInteger)runIdentityProbe:(NSURL *)broker error:(NSError **)error {
    NSTask *task = [NSTask new];
    task.executableURL = broker;
    task.arguments = @[@"identity-verify"];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:error]) return -1;
    [task waitUntilExit];
    return task.terminationStatus;
}

- (BOOL)sign:(NSArray<NSString *> *)arguments error:(NSError **)error {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/codesign"];
    task.arguments = arguments;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    XCTAssertTrue([task launchAndReturnError:error], @"%@", error);
    if (*error) return NO;
    [task waitUntilExit];
    XCTAssertEqual(task.terminationStatus, 0);
    return task.terminationStatus == 0;
}

- (void)checkWorkerIdentity:(NSString *)fault {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *products = [[NSBundle bundleForClass:self.class].bundleURL URLByDeletingLastPathComponent];
    NSURL *source = [products URLByAppendingPathComponent:@"JortJavaScriptBrokerFaultHarness"];
    NSURL *scratch = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error = nil;
    XCTAssertTrue([files createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    if (error) return;
    @try {
        NSURL *bundle = [scratch URLByAppendingPathComponent:@"JortJavaScriptBroker.xpc"];
        NSURL *contents = [bundle URLByAppendingPathComponent:@"Contents"];
        NSURL *broker = [contents URLByAppendingPathComponent:@"MacOS/JortJavaScriptBroker"];
        NSURL *worker = [contents URLByAppendingPathComponent:@"Helpers/JortJavaScriptWorker"];
        XCTAssertTrue([files createDirectoryAtURL:broker.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
        XCTAssertTrue([files createDirectoryAtURL:worker.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
        if (error) return;
        NSDictionary *info = @{
            @"CFBundleExecutable": @"JortJavaScriptBroker",
            @"CFBundleIdentifier": @"dev.jort.javascript.broker",
            @"CFBundlePackageType": @"XPC!"
        };
        XCTAssertTrue([info writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"] atomically:YES]);
        XCTAssertTrue([files copyItemAtURL:source toURL:broker error:&error], @"%@", error);
        XCTAssertTrue([files copyItemAtURL:source toURL:worker error:&error], @"%@", error);
        if (error) return;
        NSString *workerID = [fault isEqualToString:@"identifier"]
            ? @"dev.jort.javascript.untrusted-worker" : @"dev.jort.javascript.worker";
        if (![self sign:@[@"--force", @"--sign", @"-", @"--identifier", workerID,
            @"--options", @"runtime", @"--timestamp=none", worker.path] error:&error]) return;
        // Seal only after the nested helper is signed, exactly as shipping does.
        if (![self sign:@[@"--force", @"--sign", @"-", @"--identifier", @"dev.jort.javascript.broker",
            @"--options", @"runtime", @"--timestamp=none", bundle.path] error:&error]) return;
        if ([fault isEqualToString:@"tamper"]) {
            if (![self sign:@[@"--remove-signature", worker.path] error:&error]) return;
        }
        NSInteger status = [self runIdentityProbe:broker error:&error];
        XCTAssertNil(error, @"%@", error);
        if (error) return;
        if (fault.length) XCTAssertNotEqual(status, 0, @"%@ fixture unexpectedly passed", fault);
        else XCTAssertEqual(status, 0, @"valid nested broker/worker fixture was rejected (%ld)", (long)status);
    } @finally { [files removeItemAtURL:scratch error:nil]; }
}

- (void)testVerifiedWorkerPathAcceptsSealedNestedWorker { [self checkWorkerIdentity:@""]; }
- (void)testVerifiedWorkerPathRejectsWrongSignedWorkerIdentifier { [self checkWorkerIdentity:@"identifier"]; }
- (void)testVerifiedWorkerPathRejectsTamperedWorkerSignature { [self checkWorkerIdentity:@"tamper"]; }

- (void)testSignedBrokerProcessInterruptionCompletesClientAndCleansUp {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *products = [[NSBundle bundleForClass:self.class].bundleURL URLByDeletingLastPathComponent];
    NSURL *source = [NSURL fileURLWithPath:@(__FILE__)];
    NSURL *root = [[[source URLByDeletingLastPathComponent] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    NSURL *scratch = [[root URLByAppendingPathComponent:@".build-validation"]
        URLByAppendingPathComponent:[@"broker-interruption-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    @try {
        NSURL *app = [scratch URLByAppendingPathComponent:@"Jort.app"];
        NSURL *appContents = [app URLByAppendingPathComponent:@"Contents"];
        NSURL *client = [appContents URLByAppendingPathComponent:@"MacOS/Jort"];
        NSURL *bundle = [appContents URLByAppendingPathComponent:@"XPCServices/JortJavaScriptBroker.xpc"];
        NSURL *contents = [bundle URLByAppendingPathComponent:@"Contents"];
        NSURL *broker = [contents URLByAppendingPathComponent:@"MacOS/JortJavaScriptBroker"];
        NSURL *worker = [contents URLByAppendingPathComponent:@"Helpers/JortJavaScriptWorker"];
        for (NSURL *binary in @[client, broker, worker]) {
            XCTAssertTrue([files createDirectoryAtURL:binary.URLByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
            if (error) return;
            NSString *name = [binary isEqual:worker] ? @"JortJavaScriptWorker" : @"JortJavaScriptBrokerFaultHarness";
            XCTAssertTrue([files copyItemAtURL:[products URLByAppendingPathComponent:name] toURL:binary error:&error], @"%@", error);
            if (error) return;
        }
        NSDictionary *appInfo = @{@"CFBundleExecutable": @"Jort", @"CFBundleIdentifier": @"dev.jort.editor",
            @"CFBundlePackageType": @"APPL"};
        NSDictionary *brokerInfo = @{@"CFBundleExecutable": @"JortJavaScriptBroker",
            @"CFBundleIdentifier": @"dev.jort.javascript.broker", @"CFBundlePackageType": @"XPC!",
            @"XPCService": @{@"ServiceType": @"Application"}};
        XCTAssertTrue([appInfo writeToURL:[appContents URLByAppendingPathComponent:@"Info.plist"] atomically:YES]);
        XCTAssertTrue([brokerInfo writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"] atomically:YES]);
        if (![self sign:@[@"--force", @"--sign", @"-", @"--identifier", @"dev.jort.javascript.worker",
            @"--entitlements", [root URLByAppendingPathComponent:@"Configuration/JortJavaScriptWorker.entitlements"].path,
            @"--options", @"runtime", @"--timestamp=none", worker.path] error:&error]) return;
        if (![self sign:@[@"--force", @"--sign", @"-", @"--identifier", @"dev.jort.javascript.broker",
            @"--entitlements", [root URLByAppendingPathComponent:@"Configuration/JortJavaScriptBroker.entitlements"].path,
            @"--options", @"runtime", @"--timestamp=none", bundle.path] error:&error]) return;
        if (![self sign:@[@"--force", @"--sign", @"-", @"--identifier", @"dev.jort.editor",
            @"--options", @"runtime", @"--timestamp=none", app.path] error:&error]) return;
        NSTask *task = [NSTask new];
        task.executableURL = client;
        task.arguments = @[@"signed-interruption", broker.path, worker.path];
        NSPipe *output = NSPipe.pipe;
        task.standardOutput = output; task.standardError = output;
        XCTestExpectation *finished = [self expectationWithDescription:@"signed broker interruption"];
        task.terminationHandler = ^(NSTask *process) { [finished fulfill]; };
        XCTAssertTrue([task launchAndReturnError:&error], @"%@", error);
        if (error) return;
        XCTWaiterResult waited = [XCTWaiter waitForExpectations:@[finished] timeout:18];
        if (waited != XCTWaiterResultCompleted) { kill(task.processIdentifier, SIGKILL); [task waitUntilExit]; }
        NSString *diagnostic = [[NSString alloc] initWithData:[output.fileHandleForReading readDataToEndOfFile]
            encoding:NSUTF8StringEncoding];
        XCTAssertEqual(waited, XCTWaiterResultCompleted, @"%@", diagnostic);
        XCTAssertEqual(task.terminationStatus, 0, @"%@", diagnostic);
    } @finally { [files removeItemAtURL:scratch error:nil]; }
}

- (void)checkMode:(NSString *)mode {
    NSURL *products = [[NSBundle bundleForClass:self.class].bundleURL URLByDeletingLastPathComponent];
    NSURL *harness = [products URLByAppendingPathComponent:@"JortJavaScriptBrokerFaultHarness"];
    NSURL *scratch = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager *files = NSFileManager.defaultManager;
    NSError *error = nil;
    XCTAssertTrue([files createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    @try {
        NSURL *worker = [scratch URLByAppendingPathComponent:mode];
        if (![mode isEqualToString:@"launch"]) {
            XCTAssertTrue([files createSymbolicLinkAtURL:worker withDestinationURL:harness error:&error], @"%@", error);
        }
        NSTask *task = [NSTask new];
        task.executableURL = harness;
        task.arguments = @[mode, worker.path];
        NSPipe *output = NSPipe.pipe;
        task.standardOutput = output; task.standardError = output;
        XCTestExpectation *finished = [self expectationWithDescription:mode];
        task.terminationHandler = ^(NSTask *process) { [finished fulfill]; };
        XCTAssertTrue([task launchAndReturnError:&error], @"%@", error);
        if (error) return;
        XCTWaiterResult waited = [XCTWaiter waitForExpectations:@[finished] timeout:24];
        if (waited != XCTWaiterResultCompleted) { kill(task.processIdentifier, SIGKILL); [task waitUntilExit]; }
        NSString *diagnostic = [[NSString alloc] initWithData:[output.fileHandleForReading readDataToEndOfFile]
            encoding:NSUTF8StringEncoding];
        XCTAssertEqual(waited, XCTWaiterResultCompleted, @"%@", diagnostic);
        XCTAssertEqual(task.terminationStatus, 0, @"%@", diagnostic);
    } @finally { [files removeItemAtURL:scratch error:nil]; }
}
- (void)testRealBrokerSuccessAndCleanup { [self checkMode:@"success"]; }
- (void)testRealBrokerPartialWrites { [self checkMode:@"partial"]; }
- (void)testRealBrokerBackpressure { [self checkMode:@"backpressure"]; }
- (void)testRealBrokerCapacity { [self checkMode:@"capacity"]; }
- (void)testRealBrokerIdentityFailure { [self checkMode:@"identity"]; }
- (void)testRealBrokerLaunchFailure { [self checkMode:@"launch"]; }
- (void)testRealBrokerSecondFrame { [self checkMode:@"second"]; }
- (void)testRealBrokerTruncatedFrame { [self checkMode:@"truncated"]; }
- (void)testRealBrokerMalformedFrame { [self checkMode:@"malformed"]; }
- (void)testRealBrokerOversizedFrame { [self checkMode:@"oversized"]; }
- (void)testRealBrokerCrash { [self checkMode:@"crash"]; }
- (void)testRealBrokerHangAndKillEscalation { [self checkMode:@"hang"]; }
- (void)testRealBrokerBootstrapWatchdog { [self checkMode:@"bootstrap"]; }
- (void)testRealBrokerCancellationAndCleanup { [self checkMode:@"cancel"]; }
- (void)testRealBrokerCancellationReplyRace { [self checkMode:@"cancel-race"]; }
- (void)testRealBrokerLateReply { [self checkMode:@"late"]; }
- (void)testRealBrokerWatchdogReplyRace { [self checkMode:@"race"]; }
@end
