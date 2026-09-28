/* Nonshipping Apple Events receiver, positive control, and inherited sender.
 * The receiver handles only a no-data ping; no other application is targeted. */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

static OSStatus send_ping(const char *target) {
    AEAddressDesc address = {typeNull, NULL};
    AppleEvent event = {typeNull, NULL}, reply = {typeNull, NULL};
    OSStatus status = AECreateDesc(typeApplicationBundleID, target, strlen(target), &address);
    if (!status) status = AECreateAppleEvent('Jort', 'ping', &address,
        kAutoGenerateReturnID, kAnyTransactionID, &event);
    if (!status) status = AESendMessage(&event, &reply,
        kAEWaitReply | kAENeverInteract | kAEDoNotPromptForUserConsent, 120);
    if (!status) {
        SInt32 receiver_error = 0;
        Size size = 0;
        OSStatus decoded = AEGetParamPtr(&reply, keyErrorNumber, typeSInt32, NULL,
            &receiver_error, sizeof(receiver_error), &size);
        if (!decoded) status = receiver_error;
        else if (decoded != errAEDescNotFound) status = decoded;
        if (!status) {
            char pong[4] = {0};
            status = AEGetParamPtr(&reply, keyDirectObject, typeUTF8Text, NULL, pong, sizeof(pong), &size);
            if (!status && (size != sizeof(pong) || memcmp(pong, "pong", sizeof(pong)))) status = errAECoercionFail;
        }
    }
    AEDisposeDesc(&reply);
    AEDisposeDesc(&event);
    AEDisposeDesc(&address);
    return status;
}

static OSErr receive_ping(const AppleEvent *event, AppleEvent *reply, SRefCon context) {
    (void)event; (void)context;
    puts("DELIVERED");
    fflush(stdout);
    return AEPutParamPtr(reply, keyDirectObject, typeUTF8Text, "pong", 4);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 5 && (!strcmp(argv[1], "receive") || !strcmp(argv[1], "control"))) {
            if (!freopen(argv[3], "w", stdout)) return 26;
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
            [NSApp finishLaunching];
            if (!strcmp(argv[1], "receive")) {
                if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@(argv[2])]) return 25;
                if (AEInstallEventHandler('Jort', 'ping', NewAEEventHandlerUPP(receive_ping), 0, false)) return 24;
                puts("READY"); fflush(stdout);
            } else {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    AEAddressDesc address = {typeNull, NULL};
                    OSStatus permission = AECreateDesc(typeApplicationBundleID, argv[2], strlen(argv[2]), &address);
                    puts("REQUESTING_AUTOMATION_PERMISSION"); fflush(stdout);
                    if (!permission) permission = AEDeterminePermissionToAutomateTarget(&address, 'Jort', 'ping', true);
                    AEDisposeDesc(&address);
                    printf("CONTROL_STATUS %d\n", (int)(permission ?: send_ping(argv[2])));
                    fflush(stdout);
                });
                [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
                    if (![NSFileManager.defaultManager fileExistsAtPath:@(argv[4])]) return;
                    [timer invalidate];
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                        printf("CONTROL_STATUS %d\n", (int)send_ping(argv[2]));
                        fflush(stdout);
                    });
                }];
            }
            [NSApp run];
            return 0;
        }
        if (argc == 3 && !strcmp(argv[1], "send")) {
            alarm(5);
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
            [NSApp finishLaunching];
            OSStatus status = send_ping(argv[2]);
            printf("APPLE_EVENT_STATUS %d\n", (int)status);
            fflush(stdout);
            return 0;
        }
        if (argc == 4 && !strcmp(argv[1], "inherit")) {
            char *child_args[] = {(char *)argv[2], "send", (char *)argv[3], NULL};
            char *environment[] = {NULL};
            pid_t child = 0;
            int status = posix_spawn(&child, argv[2], NULL, NULL, child_args, environment);
            if (status) return 20;
            int result = 0;
            while (waitpid(child, &result, 0) == -1) if (errno != EINTR) return 21;
            return WIFEXITED(result) ? WEXITSTATUS(result) : 22;
        }
        return 23;
    }
}
