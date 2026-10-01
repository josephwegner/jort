#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>

extern char **environ;

static CFMutableDictionaryRef query(const char *group, const char *service,
                                    const char *account, bool returning_data) {
    CFMutableDictionaryRef value = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef group_value = CFStringCreateWithCString(NULL, group, kCFStringEncodingUTF8);
    CFStringRef service_value = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
    CFStringRef account_value = CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8);
    if (!value || !group_value || !service_value || !account_value) return NULL;
    CFDictionarySetValue(value, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(value, kSecAttrAccessGroup, group_value);
    CFDictionarySetValue(value, kSecAttrService, service_value);
    CFDictionarySetValue(value, kSecAttrAccount, account_value);
    CFDictionarySetValue(value, kSecUseDataProtectionKeychain, kCFBooleanTrue);
    CFDictionarySetValue(value, kSecAttrSynchronizable, kCFBooleanFalse);
    if (returning_data) {
        CFDictionarySetValue(value, kSecReturnData, kCFBooleanTrue);
        CFDictionarySetValue(value, kSecMatchLimit, kSecMatchLimitOne);
    }
    CFRelease(group_value); CFRelease(service_value); CFRelease(account_value);
    return value;
}

static int read_canary(UInt8 bytes[32]) {
    size_t offset = 0;
    while (offset < 32) {
        size_t read = fread(bytes + offset, 1, 32 - offset, stdin);
        if (read == 0) return 10;
        offset += read;
    }
    return 0;
}

static int create_canary(const char *group, const char *service, const char *account) {
    UInt8 bytes[32];
    if (read_canary(bytes) != 0) return 10;
    CFMutableDictionaryRef item = query(group, service, account, false);
    if (!item) return 11;
    (void)SecItemDelete(item);
    CFDataRef data = CFDataCreate(NULL, bytes, sizeof(bytes));
    if (!data) { CFRelease(item); return 12; }
    CFDictionarySetValue(item, kSecValueData, data);
    CFDictionarySetValue(item, kSecAttrAccessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
    OSStatus status = SecItemAdd(item, NULL);
    CFRelease(data); CFRelease(item);
    if (status != errSecSuccess) return 13;
    CFMutableDictionaryRef read = query(group, service, account, true);
    CFTypeRef result = NULL;
    status = read ? SecItemCopyMatching(read, &result) : errSecAllocate;
    bool valid = status == errSecSuccess && result && CFGetTypeID(result) == CFDataGetTypeID()
        && CFDataGetLength(result) == (CFIndex)sizeof(bytes)
        && memcmp(CFDataGetBytePtr(result), bytes, sizeof(bytes)) == 0;
    if (result) CFRelease(result);
    if (read) CFRelease(read);
    if (!valid) return 14;

    // Exercise the complete protected-item path without receiving another
    // credential value from process arguments or diagnostics.
    bytes[0] ^= 0xFF;
    CFMutableDictionaryRef update = query(group, service, account, false);
    CFDataRef replacement = CFDataCreate(NULL, bytes, sizeof(bytes));
    if (!update || !replacement) {
        if (update) CFRelease(update);
        if (replacement) CFRelease(replacement);
        return 15;
    }
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!attributes) { CFRelease(update); CFRelease(replacement); return 16; }
    CFDictionarySetValue(attributes, kSecValueData, replacement);
    CFDictionarySetValue(attributes, kSecAttrAccessible,
                         kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
    status = SecItemUpdate(update, attributes);
    CFRelease(attributes); CFRelease(replacement); CFRelease(update);
    if (status != errSecSuccess) return 17;

    read = query(group, service, account, true);
    result = NULL;
    status = read ? SecItemCopyMatching(read, &result) : errSecAllocate;
    valid = status == errSecSuccess && result && CFGetTypeID(result) == CFDataGetTypeID()
        && CFDataGetLength(result) == (CFIndex)sizeof(bytes)
        && memcmp(CFDataGetBytePtr(result), bytes, sizeof(bytes)) == 0;
    if (result) CFRelease(result);
    if (read) CFRelease(read);
    return valid ? 0 : 18;
}

static int probe_canary(const char *group, const char *service, const char *account) {
    CFMutableDictionaryRef read = query(group, service, account, true);
    if (!read) return 20;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching(read, &result);
    // The authorized host has already verified this query and the item. OS
    // versions may report different denial statuses; none may return an item.
    bool denied = status != errSecSuccess && result == NULL;
    if (result) CFRelease(result);
    CFRelease(read);
    return denied ? 0 : 20;
}

static int cleanup_canary(const char *group, const char *service, const char *account) {
    CFMutableDictionaryRef item = query(group, service, account, false);
    OSStatus status = item ? SecItemDelete(item) : errSecAllocate;
    if (item) CFRelease(item);
    return status == errSecSuccess || status == errSecItemNotFound ? 0 : 30;
}

static int broker_probe(const char *worker, const char *group, const char *service,
                        const char *account) {
    // Launch the inherited worker from the sandboxed broker rather than
    // executing it directly. The worker's `inherit` entitlement is therefore
    // part of the denial proof, not merely a static entitlement assertion.
    char *const child[] = {(char *)worker, "probe", (char *)group, (char *)service,
                           (char *)account, NULL};
    pid_t pid = 0;
    if (posix_spawn(&pid, worker, NULL, NULL, child, environ) != 0) return 40;
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) return 41;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 42;
}

int main(int argc, char **argv) {
    if (argc == 6 && !strcmp(argv[1], "broker-probe"))
        return broker_probe(argv[2], argv[3], argv[4], argv[5]);
    if (argc != 5) return 2;
    if (!strcmp(argv[1], "create")) return create_canary(argv[2], argv[3], argv[4]);
    if (!strcmp(argv[1], "probe")) return probe_canary(argv[2], argv[3], argv[4]);
    if (!strcmp(argv[1], "cleanup")) return cleanup_canary(argv[2], argv[3], argv[4]);
    return 2;
}
