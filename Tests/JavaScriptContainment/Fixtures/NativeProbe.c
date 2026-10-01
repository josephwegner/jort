/* Nonshipping executable. Reuse the actual worker bootstrap without adding
 * modes, environment switches, or native APIs to the shipping worker. */
#define main jort_unused_worker_main
#include "../../../Sources/JortJavaScriptWorker/main.c"
#undef main

#include <arpa/inet.h>
#include <dlfcn.h>
#include <limits.h>
#include <Security/SecKeychain.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include "USBOpenProbe.h"

static int denied(int result) {
    return result == -1 && (errno == EACCES || errno == EPERM);
}

static int registered_port_count(void) {
    mach_port_array_t ports = NULL;
    mach_msg_type_number_t count = 0;
    if (mach_ports_lookup(mach_task_self(), &ports, &count) != KERN_SUCCESS) return -1;
    int valid = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (MACH_PORT_VALID(ports[i])) {
            valid++;
            mach_port_deallocate(mach_task_self(), ports[i]);
        }
    }
    if (ports) vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(*ports));
    return valid;
}

static int exception_port_count(bool current_thread) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    kern_return_t result;
    if (current_thread) {
        mach_port_t thread = mach_thread_self();
        result = thread_get_exception_ports(thread, EXC_MASK_ALL, masks, &count, ports, behaviors, flavors);
        mach_port_deallocate(mach_task_self(), thread);
    } else {
        result = task_get_exception_ports(mach_task_self(), EXC_MASK_ALL, masks, &count, ports, behaviors, flavors);
    }
    if (result != KERN_SUCCESS) return -1;
    int valid = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (MACH_PORT_VALID(ports[i])) {
            valid++;
            mach_port_deallocate(mach_task_self(), ports[i]);
        }
    }
    return valid;
}

static int mach_ports_probe(void) {
    mach_port_t access = MACH_PORT_NULL;
    kern_return_t access_result = task_get_special_port(mach_task_self(), TASK_ACCESS_PORT, &access);
    if (access_result != KERN_SUCCESS || access == MACH_PORT_DEAD) return 96;
    // This normal OS-managed slot is populated on the verification host. Its
    // write-once kernel contract makes clearing it impossible, even to null.
    if (MACH_PORT_VALID(access)
        && task_set_special_port(mach_task_self(), TASK_ACCESS_PORT, MACH_PORT_NULL) != KERN_NO_ACCESS) return 97;
    if (registered_port_count() != 1 || exception_port_count(false) < 1) return 90;
    JortJSReady ready = {0};
    if (!bootstrap(12, &ready)) return 91;
    if (registered_port_count() != 0 || exception_port_count(false) != 0 || exception_port_count(true) != 0
        || bootstrap_port != MACH_PORT_NULL) return 92;
    mach_port_t retained_access = MACH_PORT_NULL;
    if (task_get_special_port(mach_task_self(), TASK_ACCESS_PORT, &retained_access) != KERN_SUCCESS
        || retained_access != access) return 98;
    if (MACH_PORT_VALID(retained_access)) mach_port_deallocate(mach_task_self(), retained_access);
    if (MACH_PORT_VALID(access)) mach_port_deallocate(mach_task_self(), access);
    const int slots[] = {TASK_BOOTSTRAP_PORT, TASK_DEBUG_CONTROL_PORT};
    for (size_t i = 0; i < sizeof(slots) / sizeof(slots[0]); i++) {
        mach_port_t port = MACH_PORT_NULL;
        if (task_get_special_port(mach_task_self(), slots[i], &port) != KERN_SUCCESS) return 93;
        if (port != MACH_PORT_NULL) { mach_port_deallocate(mach_task_self(), port); return 94; }
    }
    static const char result[] = "CLEARED inherited-mach-capabilities\n";
    return write(STDOUT_FILENO, result, sizeof(result) - 1) == sizeof(result) - 1 ? 0 : 95;
}

static int file_denied(const char *path, int mode) {
    int descriptor = open(path, mode);
    if (descriptor >= 0) { close(descriptor); return 0; }
    return denied(descriptor);
}

static int network_denied(int server) {
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) return denied(descriptor);
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(server ? 0 : 9);
    int result = server
        ? bind(descriptor, (const struct sockaddr *)&address, sizeof(address))
        : connect(descriptor, (const struct sockaddr *)&address, sizeof(address));
    int blocked = denied(result);
    close(descriptor);
    return blocked;
}

/* These calls are intentionally resolved at runtime. The probe is a small
 * inherit-only worker fixture, so it must not acquire framework linkage that
 * the shipping worker does not have merely to test denied authority. */
static int keychain_denied(const char *path, const char *service, const char *account, OSStatus *result) {
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    if (!security) return 0;
    OSStatus (*open_keychain)(const char *, SecKeychainRef *) = dlsym(security, "SecKeychainOpen");
    OSStatus (*find_password)(CFTypeRef, UInt32, const char *, UInt32, const char *, UInt32 *, void **,
        SecKeychainItemRef *) = dlsym(security, "SecKeychainFindGenericPassword");
    void (*free_content)(SecKeychainAttributeList *, void *) = dlsym(security, "SecKeychainItemFreeContent");
    if (!open_keychain || !find_password || !free_content) { dlclose(security); return 0; }
    SecKeychainRef keychain = NULL;
    OSStatus status = open_keychain(path, &keychain);
    bool opened = status == errSecSuccess;
    if (status == errSecSuccess) {
        UInt32 length = 0;
        void *password = NULL;
        status = find_password(keychain, (UInt32)strlen(service), service,
            (UInt32)strlen(account), account, &length, &password, NULL);
        if (password) free_content(NULL, password);
        CFRelease(keychain);
    }
    dlclose(security);
    *result = status;
    // The test parent proves the exact disposable keychain and canary exist.
    // Keychain Services intentionally hides an inaccessible matching item as
    // errSecItemNotFound, but only accept that privacy-preserving denial after
    // this worker opened that same keychain file successfully.
    return status == errSecAuthFailed || status == errSecInteractionNotAllowed
        || status == errSecMissingEntitlement || status == errSecNotAvailable
        || (opened && status == errSecItemNotFound);
}

static int parse_config(char *input, char **file, char **keychain, char **service, char **account) {
    char *fields[4] = {0};
    char *cursor = input;
    for (size_t index = 0; index < 4; index++) {
        fields[index] = cursor;
        char *newline = strchr(cursor, '\n');
        if (!newline || (index == 3 && newline[1])) return 0;
        *newline = 0;
        cursor = newline + 1;
    }
    if (!fields[0][0] || fields[0][0] != '/' || !fields[1][0] || fields[1][0] != '/'
        || !fields[2][0] || !fields[3][0]) return 0;
    *file = fields[0]; *keychain = fields[1]; *service = fields[2]; *account = fields[3];
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 3 || strcmp(argv[1], "1")) return 64;
    if (!strcmp(argv[2], "12")) return mach_ports_probe();
    if (!strcmp(argv[2], "11")) {
        char input[32] = {0};
        ssize_t length = read(STDIN_FILENO, input, sizeof(input) - 1);
        if (length <= 0) return 65;
        char *end = NULL;
        uint64_t identifier = strtoull(input, &end, 10);
        if (!identifier || !end || *end) return 65;
        JortUSBProbe usb = {0};
        if (!jort_usb_load(&usb)) return 88;
        bool present = false, opened = false;
        kern_return_t status = jort_usb_open_close(&usb, identifier, &present, &opened);
        dlclose(usb.library);
        // A missing service or an unrelated busy/unsupported error proves
        // nothing. Require the exact known-present service and policy denial.
        if (!present || opened || (status != kIOReturnNotPrivileged && status != kIOReturnNotPermitted)) {
            dprintf(STDOUT_FILENO, "USB open present=%d opened=%d status=0x%x\n", present, opened, status);
            return 89;
        }
        static const char denied[] = "DENIED protected-device open-close\n";
        return write(STDOUT_FILENO, denied, sizeof(denied) - 1) == sizeof(denied) - 1 ? 0 : 74;
    }
    if (!strcmp(argv[2], "1000")) {
        JortJSReady ready = { .status = JORT_JS_BOOTSTRAP };
        if (bootstrap(1000, &ready)) ready.status = JORT_JS_OK;
        if (jort_js_ready_write(STDOUT_FILENO, &ready, jort_js_monotonic() + 3)
            || ready.status != JORT_JS_OK) return 70;
        // Bypass QuickJS interrupts while retaining the real bootstrap's
        // default SIGXCPU disposition. Darwin enforces RLIMIT_CPU with SIGXCPU;
        // ignoring it is not guaranteed to produce a later hard-limit SIGKILL.
        volatile uint64_t counter = 0;
        for (;;) counter++;
    }
    if (strcmp(argv[2], "10")) return 64;

    // The test runner creates this file outside either sandbox container and
    // proves it exists and is readable/writable before sending its path.
    char path[PATH_MAX];
    size_t length = 0;
    for (;;) {
        ssize_t count = read(STDIN_FILENO, path + length, sizeof(path) - 1 - length);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return 65;
        if (!count) break;
        length += (size_t)count;
        if (length == sizeof(path) - 1) return 65;
    }
    path[length] = 0;
    char *file = NULL, *keychain = NULL, *service = NULL, *account = NULL;
    if (!parse_config(path, &file, &keychain, &service, &account)) return 65;
    // Run these before resource limits: denial must come from the inherited
    // sandbox, rather than RLIMIT_FSIZE or a descriptor/process quota.
    if (!file_denied(file, O_RDONLY)) return 81;
    if (!file_denied(file, O_WRONLY)) return 82;
    if (!network_denied(0)) return 83;
    if (!network_denied(1)) return 84;
    OSStatus keychain_status = errSecSuccess;
    if (!keychain_denied(keychain, service, account, &keychain_status)) {
        dprintf(STDOUT_FILENO, "Keychain probe returned %d\n", (int)keychain_status);
        return 87;
    }

    JortJSReady ready = {0};
    if (!bootstrap(10, &ready)) return 70;
    pid_t child = 0;
    char *arguments[] = { "/usr/bin/true", NULL };
    char *environment[] = { "LANG=C", NULL };
    int result = posix_spawn(&child, arguments[0], NULL, NULL, arguments, environment);
    if (!result) { int status; (void)waitpid(child, &status, 0); return 85; }
    if (result != EPERM && result != EACCES && result != EAGAIN) return 86;
    static const char success[] = "DENIED file-read file-write network-client network-server keychain subprocess\n";
    return write(STDOUT_FILENO, success, sizeof(success) - 1) == sizeof(success) - 1 ? 0 : 74;
}
