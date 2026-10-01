#import <XCTest/XCTest.h>

#include <dlfcn.h>
#include <signal.h>
#include <Security/SecKeychain.h>
#include "Fixtures/USBOpenProbe.h"

static OSStatus JortCreateProbeKeychain(NSString *path, NSString *service, NSString *account,
    SecKeychainRef *created) {
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    if (!security) return errSecNotAvailable;
    OSStatus (*create)(const char *, UInt32, const void *, Boolean, SecAccessRef, SecKeychainRef *) = dlsym(security, "SecKeychainCreate");
    OSStatus (*add)(SecKeychainRef, UInt32, const char *, UInt32, const char *, UInt32,
        const void *, SecKeychainItemRef *) = dlsym(security, "SecKeychainAddGenericPassword");
    OSStatus (*find)(CFTypeRef, UInt32, const char *, UInt32, const char *, UInt32 *, void **,
        SecKeychainItemRef *) = dlsym(security, "SecKeychainFindGenericPassword");
    void (*free_content)(SecKeychainAttributeList *, void *) = dlsym(security, "SecKeychainItemFreeContent");
    if (!create || !add || !find || !free_content) { dlclose(security); return errSecNotAvailable; }
    static const char keychainPassword[] = "Jort sandbox probe keychain";
    static const char password[] = "Jort containment canary";
    SecKeychainRef keychain = NULL;
    OSStatus status = create(path.fileSystemRepresentation, sizeof(keychainPassword) - 1,
        keychainPassword, false, NULL, &keychain);
    if (status == errSecSuccess) status = add(keychain, (UInt32)[service lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        service.UTF8String, (UInt32)[account lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        account.UTF8String, sizeof(password) - 1, password, NULL);
    UInt32 length = 0;
    void *found = NULL;
    if (status == errSecSuccess) status = find(keychain,
        (UInt32)[service lengthOfBytesUsingEncoding:NSUTF8StringEncoding], service.UTF8String,
        (UInt32)[account lengthOfBytesUsingEncoding:NSUTF8StringEncoding], account.UTF8String,
        &length, &found, NULL);
    if (status == errSecSuccess && (length != sizeof(password) - 1 || memcmp(found, password, length))) status = errSecDecode;
    if (found) free_content(NULL, found);
    if (status == errSecSuccess) *created = keychain;
    else if (keychain) CFRelease(keychain);
    dlclose(security);
    return status;
}

@interface JortSignedNativeProbeTests : XCTestCase
@end

@implementation JortSignedNativeProbeTests

- (NSString *)vmmapForProcess:(pid_t)pid error:(NSError **)error {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/vmmap"];
    task.arguments = @[@"-wide", [NSString stringWithFormat:@"%d", pid]];
    // vmmap can emit more than a pipe buffer for an instrumented process.
    // A disposable file lets it finish without blocking on an unread pipe.
    char outputPath[] = "/private/tmp/jort-vmmap-XXXXXX";
    int descriptor = mkstemp(outputPath);
    if (descriptor < 0) return nil;
    unlink(outputPath);
    NSFileHandle *output = [[NSFileHandle alloc] initWithFileDescriptor:descriptor closeOnDealloc:YES];
    task.standardOutput = output;
    task.standardError = output;
    XCTestExpectation *finished = [self expectationWithDescription:@"bounded vmmap inspection"];
    task.terminationHandler = ^(NSTask *process) { [finished fulfill]; };
    if (![task launchAndReturnError:error]) return nil;
    XCTWaiterResult result = [XCTWaiter waitForExpectations:@[finished] timeout:10];
    if (result != XCTWaiterResultCompleted) {
        kill(task.processIdentifier, SIGKILL);
        [task waitUntilExit];
    }
    [output seekToFileOffset:0];
    NSData *data = [output readDataToEndOfFile];
    NSString *report = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (task.terminationStatus != 0) {
        if (error) *error = [NSError errorWithDomain:@"JortSignedNativeProbeTests"
            code:task.terminationStatus userInfo:@{NSLocalizedDescriptionKey: report ?: @"vmmap produced no diagnostic"}];
        return nil;
    }
    return report;
}

- (void)runProbe:(NSString *)mode {
    uint64_t deviceIdentifier = 0;
    if ([mode isEqualToString:@"device"]) {
        JortUSBProbe usb = {0};
        bool loaded = jort_usb_load(&usb);
        XCTAssertTrue(loaded, @"IOKit probe API unavailable");
        if (!loaded) { if (usb.library) dlclose(usb.library); return; }
        deviceIdentifier = jort_usb_yubikey(&usb);
        if (!deviceIdentifier) {
            dlclose(usb.library);
            XCTSkip(@"No approved Yubico USB device is connected; protected-device denial remains unverified on this host");
            return;
        }
        bool present = false, opened = false;
        kern_return_t status = jort_usb_open_close(&usb, deviceIdentifier, &present, &opened);
        dlclose(usb.library);
        XCTAssertTrue(present, @"Approved USB device disappeared before positive control");
        XCTAssertTrue(opened, @"Positive control did not open the approved USB service");
        XCTAssertEqual(status, KERN_SUCCESS, @"Unsandboxed open/close control failed: 0x%x; a sandbox denial cannot be inferred", status);
        if (!present || !opened || status != KERN_SUCCESS) return;
    }
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *products = [[NSBundle bundleForClass:self.class].bundleURL URLByDeletingLastPathComponent];
    // __FILE__ is supplied by Xcode as an absolute source path. The fixture is
    // deliberately in the repository, outside both App Sandbox containers.
    NSURL *source = [NSURL fileURLWithPath:@(__FILE__)];
    NSURL *root = [[[source URLByDeletingLastPathComponent] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    NSURL *fixtures = [[source URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Fixtures"];
    NSURL *scratch = [[root URLByAppendingPathComponent:@".build-validation"]
        URLByAppendingPathComponent:[@"native-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    SecKeychainRef probeKeychain = NULL;
    XCTAssertTrue([files createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    if (error) return;
    @try {
        NSURL *code = [scratch URLByAppendingPathComponent:@"code"];
        error = nil;
        XCTAssertTrue([files createDirectoryAtURL:code withIntermediateDirectories:NO attributes:nil error:&error], @"%@", error);
        if (error) return;
        NSURL *file = [scratch URLByAppendingPathComponent:@"outside-container.txt"];
        NSData *expected = [@"Native sandbox fixture; no credential or user data.\n" dataUsingEncoding:NSUTF8StringEncoding];
        XCTAssertTrue([expected writeToURL:file options:NSDataWritingAtomic error:&error], @"%@", error);
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], expected);
        XCTAssertTrue([files isWritableFileAtPath:file.path]);

        NSString *service = [@"dev.jort.containment." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *account = @"authority-probe";
        NSURL *keychainURL = [scratch URLByAppendingPathComponent:@"JortAuthorityProbe.keychain"];
        if ([mode isEqualToString:@"sandbox"]) {
            OSStatus keychainStatus = JortCreateProbeKeychain(keychainURL.path, service, account, &probeKeychain);
            XCTAssertEqual(keychainStatus, errSecSuccess, @"unable to create and read disposable Keychain canary: %d", (int)keychainStatus);
            if (keychainStatus != errSecSuccess) return;
        }

        BOOL productionWorker = [mode isEqualToString:@"heap"] || [mode isEqualToString:@"mapping"];
        NSString *childName = productionWorker ? @"JortJavaScriptWorker" : @"JortJavaScriptNativeProbe";
        NSURL *harnessTarget = [code URLByAppendingPathComponent:@"JortJavaScriptSandboxHarness"];
        NSURL *childTarget = [code URLByAppendingPathComponent:childName];
        if (productionWorker) {
            // Mirror the shipping topology instead of staging both executables
            // as siblings. This exercises inherited-sandbox launch from the
            // broker's own nested Contents/Helpers directory.
            NSURL *contents = [[code URLByAppendingPathComponent:@"Jort.app"]
                URLByAppendingPathComponent:@"Contents"];
            harnessTarget = [[[[contents URLByAppendingPathComponent:@"XPCServices"]
                URLByAppendingPathComponent:@"JortJavaScriptBroker.xpc"]
                URLByAppendingPathComponent:@"Contents/MacOS"]
                URLByAppendingPathComponent:@"JortJavaScriptSandboxHarness"];
            childTarget = [[[[[contents URLByAppendingPathComponent:@"XPCServices"]
                URLByAppendingPathComponent:@"JortJavaScriptBroker.xpc"]
                URLByAppendingPathComponent:@"Contents"]
                URLByAppendingPathComponent:@"Helpers"]
                URLByAppendingPathComponent:childName];
            XCTAssertTrue([files createDirectoryAtURL:[harnessTarget URLByDeletingLastPathComponent]
                withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
            if (error) return;
            XCTAssertTrue([files createDirectoryAtURL:[childTarget URLByDeletingLastPathComponent]
                withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
            if (error) return;
        }
        NSArray<NSString *> *names = @[@"JortJavaScriptSandboxHarness", childName];
        NSArray<NSURL *> *targets = @[harnessTarget, childTarget];
        NSArray<NSString *> *identifiers = @[@"dev.jort.javascript.sandbox-harness",
            productionWorker ? @"dev.jort.editor.javascript-worker" : @"dev.jort.javascript.native-probe"];
        NSArray<NSURL *> *entitlements = @[
            [fixtures URLByAppendingPathComponent:@"Harness.entitlements"],
            [root URLByAppendingPathComponent:@"Configuration/JortJavaScriptWorker.entitlements"]
        ];
        for (NSUInteger index = 0; index < names.count; index++) {
            NSURL *target = targets[index];
            error = nil;
            XCTAssertTrue([files copyItemAtURL:[products URLByAppendingPathComponent:names[index]] toURL:target error:&error], @"%@", error);
            if (error) return;
            // Test builds may inject get-task-allow. Sign disposable copies with
            // the exact production sandbox policy and no XCTest exceptions.
            NSTask *sign = [NSTask new];
            sign.executableURL = [NSURL fileURLWithPath:@"/usr/bin/codesign"];
            sign.arguments = @[@"--force", @"--sign", @"-", @"--identifier", identifiers[index],
                @"--entitlements", entitlements[index].path, @"--options", @"runtime", @"--timestamp=none", target.path];
            XCTAssertTrue([sign launchAndReturnError:&error], @"%@", error);
            if (error) return;
            [sign waitUntilExit];
            XCTAssertEqual(sign.terminationStatus, 0);
            if (sign.terminationStatus) return;
        }
        NSTask *task = [NSTask new];
        task.executableURL = harnessTarget;
        NSString *probeInput = file.path;
        if ([mode isEqualToString:@"device"]) probeInput = [NSString stringWithFormat:@"%llu", (unsigned long long)deviceIdentifier];
        if ([mode isEqualToString:@"sandbox"]) {
            probeInput = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n",
                file.path, keychainURL.path, service, account];
        }
        task.arguments = @[mode, childTarget.path, probeInput];
        NSPipe *output = NSPipe.pipe;
        task.standardOutput = output;
        task.standardError = output;
        NSPipe *control = nil;
        XCTestExpectation *ready = nil;
        XCTestExpectation *drained = nil;
        __block NSString *mappingOutput = @"";
        __block BOOL mappingReady = NO;
        if ([mode isEqualToString:@"mapping"]) {
            control = NSPipe.pipe;
            task.standardInput = control;
            ready = [self expectationWithDescription:@"production worker ready without source"];
            drained = [self expectationWithDescription:@"mapping probe output drained"];
            output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
                NSData *data = handle.availableData;
                if (!data.length) {
                    handle.readabilityHandler = nil;
                    [drained fulfill];
                    return;
                }
                NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
                @synchronized (self) {
                    mappingOutput = [mappingOutput stringByAppendingString:chunk];
                    if (!mappingReady && [mappingOutput rangeOfString:@"READY [0-9]+\n"
                        options:NSRegularExpressionSearch].location != NSNotFound) {
                        mappingReady = YES;
                        [ready fulfill];
                    }
                }
            };
        }
        XCTestExpectation *finished = [self expectationWithDescription:@"bounded native containment probe"];
        task.terminationHandler = ^(NSTask *process) { [finished fulfill]; };
        error = nil;
        XCTAssertTrue([task launchAndReturnError:&error], @"%@", error);
        if (error) return;
        if (ready) {
            XCTWaiterResult readyResult = [XCTWaiter waitForExpectations:@[ready] timeout:4];
            NSString *readyOutput;
            @synchronized (self) { readyOutput = [mappingOutput copy]; }
            XCTAssertEqual(readyResult, XCTWaiterResultCompleted, @"%@", readyOutput);
            NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"READY ([0-9]+)"
                options:0 error:&error];
            NSTextCheckingResult *match = [expression firstMatchInString:readyOutput options:0
                range:NSMakeRange(0, readyOutput.length)];
            XCTAssertNotNil(match, @"%@", readyOutput);
            pid_t workerPID = match ? [[readyOutput substringWithRange:[match rangeAtIndex:1]] intValue] : 0;
            NSString *maps = workerPID > 0 ? [self vmmapForProcess:workerPID error:&error] : nil;
            XCTAssertNotNil(maps, @"vmmap host restriction or failure: %@", error);
            XCTAssertTrue([maps containsString:childTarget.path], @"vmmap did not map the exact production worker: %@", maps);
            // EOF is the explicit bounded control signal. The harness then
            // SIGTERMs and waitpid-reaps its owned worker.
            [control.fileHandleForWriting closeFile];
        }
        XCTWaiterResult result = [XCTWaiter waitForExpectations:@[finished] timeout:12];
        if (result != XCTWaiterResultCompleted) {
            kill(task.processIdentifier, SIGKILL);
            [task waitUntilExit];
        }
        XCTAssertEqual(result, XCTWaiterResultCompleted);
        NSString *diagnostic;
        if (drained) {
            XCTAssertEqual([XCTWaiter waitForExpectations:@[drained] timeout:2], XCTWaiterResultCompleted);
            output.fileHandleForReading.readabilityHandler = nil;
            @synchronized (self) { diagnostic = [mappingOutput copy]; }
        } else {
            diagnostic = [[NSString alloc] initWithData:[output.fileHandleForReading readDataToEndOfFile]
                encoding:NSUTF8StringEncoding];
        }
        XCTAssertEqual(task.terminationStatus, 0, @"%@", diagnostic);
        if (ready) XCTAssertTrue([diagnostic containsString:@"REAPED"], @"%@", diagnostic);
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], expected);
    } @finally {
        if (probeKeychain) CFRelease(probeKeychain);
        [files removeItemAtURL:scratch error:nil];
    }
}

- (void)testSignedInheritedSandboxDeniesFilesNetworkAndAdditionalProcess {
    [self runProbe:@"sandbox"];
}

- (void)testNativeCPULimitAndProductionBrokerReaping {
    [self runProbe:@"cpu"];
}

- (void)testWorkerDropsInheritedMachCapabilitiesBeforeReady {
    [self runProbe:@"ports"];
}

- (void)testSignedInheritedSandboxDeniesProtectedUSBDeviceOpen {
    [self runProbe:@"device"];
}

- (void)testProductionWorkerHeapExhaustionAndFreshWorkerRecovery {
    [self runProbe:@"heap"];
}

- (void)testProductionWorkerMapsQuickJSOnlyInPausedWorkerAndIsReaped {
    [self runProbe:@"mapping"];
}

@end
