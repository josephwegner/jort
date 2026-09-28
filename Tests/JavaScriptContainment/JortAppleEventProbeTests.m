#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <signal.h>

@interface JortAppleEventProbeTests : XCTestCase
@end

@implementation JortAppleEventProbeTests
- (NSRunningApplication *)launch:(NSURL *)bundle arguments:(NSArray<NSString *> *)arguments {
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = NO;
    configuration.createsNewApplicationInstance = YES;
    configuration.arguments = arguments;
    XCTestExpectation *launched = [self expectationWithDescription:@"LaunchServices fixture launch"];
    __block NSRunningApplication *result = nil;
    __block NSError *launchError = nil;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:bundle configuration:configuration
        completionHandler:^(NSRunningApplication *application, NSError *failure) {
            result = application;
            launchError = failure;
            [launched fulfill];
        }];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[launched] timeout:8], XCTWaiterResultCompleted);
    XCTAssertNotNil(result, @"%@", launchError);
    return result;
}

- (NSString *)run:(NSURL *)executable arguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [NSTask new];
    task.executableURL = executable;
    task.arguments = arguments;
    NSPipe *pipe = NSPipe.pipe;
    task.standardOutput = pipe;
    task.standardError = pipe;
    XCTestExpectation *finished = [self expectationWithDescription:@"bounded Apple Events helper"];
    task.terminationHandler = ^(NSTask *completed) { [finished fulfill]; };
    NSError *error = nil;
    XCTAssertTrue([task launchAndReturnError:&error], @"%@", error);
    if (error) return nil;
    XCTWaiterResult result = [XCTWaiter waitForExpectations:@[finished] timeout:8];
    if (result != XCTWaiterResultCompleted) { kill(task.processIdentifier, SIGKILL); [task waitUntilExit]; }
    NSString *output = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile]
        encoding:NSUTF8StringEncoding];
    XCTAssertEqual(result, XCTWaiterResultCompleted, @"%@", output);
    XCTAssertEqual(task.terminationStatus, 0, @"%@", output);
    return output;
}

- (void)testInheritedSandboxDeniesAppleEventToLiveReceiver {
    // This probe may request macOS Automation consent. Keep it out of the
    // unattended Foundation/gate lane; run it explicitly after approval.
    if (![NSProcessInfo.processInfo.environment[@"JORT_APPLE_EVENT_PROBE"] isEqualToString:@"1"]) {
        XCTSkip(@"Run ./scripts/validate focused containment --only JortJavaScriptContainmentTests/JortAppleEventProbeTests for the interactive signed Apple Events probe.");
    }
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *products = [[NSBundle bundleForClass:self.class].bundleURL URLByDeletingLastPathComponent];
    NSURL *root = [[[[NSURL fileURLWithPath:@(__FILE__)] URLByDeletingLastPathComponent]
        URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    NSURL *scratch = [[root URLByAppendingPathComponent:@".build-validation"]
        URLByAppendingPathComponent:[@"apple-event-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    XCTAssertTrue([files createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:&error]);
    if (error) return;
    __block NSRunningApplication *receiver = nil;
    __block NSRunningApplication *control = nil;
    NSURL *eventFile = [scratch URLByAppendingPathComponent:@"events"];
    NSURL *commandFile = [scratch URLByAppendingPathComponent:@"ping-again"];
    NSURL *controlFile = [scratch URLByAppendingPathComponent:@"control-events"];
    NSString *(^events)(void) = ^NSString *{
        return [NSString stringWithContentsOfURL:eventFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
    };
    NSString *(^controls)(void) = ^NSString *{
        return [NSString stringWithContentsOfURL:controlFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
    };
    @try {
        NSURL *bundle = [scratch URLByAppendingPathComponent:@"JortAppleEventReceiver.app"];
        XCTAssertTrue([files copyItemAtURL:[products URLByAppendingPathComponent:@"JortAppleEventReceiver.app"]
            toURL:bundle error:&error], @"%@", error);
        if (error) return;
        NSString *receiverID = [@"dev.jort.javascript.apple-event-receiver."
            stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
        NSURL *infoURL = [bundle URLByAppendingPathComponent:@"Contents/Info.plist"];
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfURL:infoURL];
        XCTAssertNotNil(info);
        info[@"CFBundleIdentifier"] = receiverID;
        XCTAssertTrue([info writeToURL:infoURL atomically:YES]);
        NSURL *original = [products URLByAppendingPathComponent:@"JortAppleEventProbe"];
        NSURL *harness = [scratch URLByAppendingPathComponent:@"Harness"];
        NSURL *child = [scratch URLByAppendingPathComponent:@"Child"];
        for (NSURL *copy in @[harness, child]) {
            XCTAssertTrue([files copyItemAtURL:original toURL:copy error:&error], @"%@", error);
            if (error) return;
        }
        // Sign disposable code with the shipping broker / inherit-only policy.
        NSArray *signedFiles = @[harness, child];
        NSArray *policies = @[@"Configuration/JortJavaScriptBroker.entitlements", @"Configuration/JortJavaScriptWorker.entitlements"];
        for (NSUInteger index = 0; index < signedFiles.count; index++) {
            [self run:[NSURL fileURLWithPath:@"/usr/bin/codesign"] arguments:@[@"--force", @"--sign", @"-",
                @"--options", @"runtime", @"--timestamp=none", @"--entitlements",
                [root URLByAppendingPathComponent:policies[index]].path, [signedFiles[index] path]]];
        }
        [self run:[NSURL fileURLWithPath:@"/usr/bin/codesign"] arguments:@[@"--force", @"--sign", @"-",
            @"--timestamp=none", bundle.path]];
        OSStatus registration = LSRegisterURL((__bridge CFURLRef)bundle, true);
        XCTAssertEqual(registration, noErr, @"failed to register disposable receiver");
        if (registration != noErr) return;
        // LaunchServices must own application registration; direct exec can leave
        // a live process that cannot receive a bundle-addressed Apple Event.
        receiver = [self launch:bundle arguments:@[@"receive", receiverID, eventFile.path, commandFile.path]];
        if (!receiver) return;
        XCTAssertEqualObjects(receiver.bundleIdentifier, receiverID);
        XCTestExpectation *ready = [[XCTNSPredicateExpectation alloc]
            initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
                return [events() containsString:@"READY\n"];
            }] object:nil];
        XCTWaiterResult readyResult = [XCTWaiter waitForExpectations:@[ready] timeout:8];
        XCTAssertEqual(readyResult, XCTWaiterResultCompleted, @"%@", events());
        if (readyResult != XCTWaiterResultCompleted) return;
        NSURL *controlBundle = [scratch URLByAppendingPathComponent:@"JortAppleEventControl.app"];
        XCTAssertTrue([files copyItemAtURL:bundle toURL:controlBundle error:&error], @"%@", error);
        if (error) return;
        NSURL *controlInfoURL = [controlBundle URLByAppendingPathComponent:@"Contents/Info.plist"];
        info[@"CFBundleIdentifier"] = [receiverID stringByAppendingString:@".control"];
        info[@"CFBundleName"] = @"Jort Apple Event Test Sender";
        XCTAssertTrue([info writeToURL:controlInfoURL atomically:YES]);
        NSURL *controlPolicy = [scratch URLByAppendingPathComponent:@"control.entitlements"];
        XCTAssertTrue([@{@"com.apple.security.automation.apple-events": @YES} writeToURL:controlPolicy atomically:YES]);
        [self run:[NSURL fileURLWithPath:@"/usr/bin/codesign"] arguments:@[@"--force", @"--sign", @"-",
            @"--options", @"runtime", @"--timestamp=none", @"--entitlements", controlPolicy.path, controlBundle.path]];
        XCTAssertEqual(LSRegisterURL((__bridge CFURLRef)controlBundle, true), noErr);
        control = [self launch:controlBundle arguments:@[@"control", receiverID, controlFile.path, commandFile.path]];
        if (!control) return;
        XCTestExpectation *controlStarted = [[XCTNSPredicateExpectation alloc]
            initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
                return [controls() containsString:@"REQUESTING_AUTOMATION_PERMISSION\n"] || control.terminated;
            }] object:nil];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[controlStarted] timeout:8], XCTWaiterResultCompleted,
            @"external control did not start");
        XCTAssertFalse(control.terminated, @"external control exited before its permission request");
        if (![controls() containsString:@"REQUESTING_AUTOMATION_PERMISSION\n"]) return;
        XCTestExpectation *permission = [[XCTNSPredicateExpectation alloc]
            initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
                return [controls() containsString:@"CONTROL_STATUS "];
            }] object:nil];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[permission] timeout:120], XCTWaiterResultCompleted,
            @"%@", controls());
        XCTAssertTrue([controls() containsString:@"CONTROL_STATUS 0\n"], @"%@", controls());
        if (![controls() containsString:@"CONTROL_STATUS 0\n"]) return;
        NSString *denied = [self run:harness arguments:@[@"inherit", child.path, receiverID]];
        // macOS may conceal a sandbox-denied target as "process not found"
        // (-600). The independent sender and delivery count below distinguish
        // that result from an actually missing or unroutable receiver.
        NSString *explicitDenial = [NSString stringWithFormat:@"APPLE_EVENT_STATUS %d\n", errAEEventNotPermitted];
        NSString *concealedTarget = [NSString stringWithFormat:@"APPLE_EVENT_STATUS %d\n", procNotFound];
        XCTAssertTrue([denied containsString:explicitDenial] || [denied containsString:concealedTarget],
            @"expected sandbox authority denial: %@", denied);
        // The separately launched positive control must receive the exact pong
        // both before and after the inherited-sandbox sender is denied.
        XCTestExpectation *after = [[XCTNSPredicateExpectation alloc]
            initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
                return [controls() componentsSeparatedByString:@"CONTROL_STATUS 0\n"].count == 3;
            }] object:nil];
        XCTAssertTrue([@"ping" writeToURL:commandFile atomically:YES encoding:NSUTF8StringEncoding error:&error]);
        XCTAssertEqual([XCTWaiter waitForExpectations:@[after] timeout:8], XCTWaiterResultCompleted, @"%@", controls());
        XCTAssertEqual([events() componentsSeparatedByString:@"DELIVERED"].count - 1, 2u, @"%@", events());
    } @finally {
        for (NSRunningApplication *application in @[control ?: NSNull.null, receiver ?: NSNull.null]) {
            if ((id)application == NSNull.null || application.terminated) continue;
            [application forceTerminate];
            XCTestExpectation *terminated = [[XCTNSPredicateExpectation alloc]
                initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
                    return application.terminated;
                }] object:nil];
            XCTAssertEqual([XCTWaiter waitForExpectations:@[terminated] timeout:8], XCTWaiterResultCompleted);
        }
        [files removeItemAtURL:scratch error:nil];
    }
}
@end
