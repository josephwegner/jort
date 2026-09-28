#include "BrokerIdentity.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef JORT_JS_ALLOW_ADHOC
#define JORT_JS_ALLOW_ADHOC 0
#endif

static bool bundle_paths(char broker[PATH_MAX], char worker[PATH_MAX]) {
    char executable[PATH_MAX], resolved[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, resolved)) return false;
    const char *suffix = "/Contents/MacOS/JortJavaScriptBroker";
    size_t length = strlen(resolved), suffix_length = strlen(suffix);
    if (length <= suffix_length || strcmp(resolved + length - suffix_length, suffix) != 0) return false;
    resolved[length - suffix_length] = '\0';
    if (snprintf(broker, PATH_MAX, "%s", resolved) >= PATH_MAX) return false;
    return snprintf(worker, PATH_MAX, "%s/Contents/Helpers/JortJavaScriptWorker", broker) < PATH_MAX;
}

static SecStaticCodeRef checked_code(const char *path, const char *identifier, bool nested) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    SecStaticCodeRef code = NULL;
    if (!url) return NULL;
    OSStatus result = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    CFRelease(url);
    if (result != errSecSuccess) return NULL;
    SecCSFlags flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures;
    if (nested) flags |= kSecCSCheckNestedCode;
    if (SecStaticCodeCheckValidity(code, flags, NULL) != errSecSuccess) {
        CFRelease(code);
        return NULL;
    }
    CFDictionaryRef information = NULL;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information) != errSecSuccess) {
        CFRelease(code);
        return NULL;
    }
    CFStringRef actual = CFDictionaryGetValue(information, kSecCodeInfoIdentifier);
    CFStringRef expected = CFStringCreateWithCString(NULL, identifier, kCFStringEncodingUTF8);
    bool valid = actual && expected && CFEqual(actual, expected);
    if (expected) CFRelease(expected);
    CFRelease(information);
    if (!valid) { CFRelease(code); return NULL; }
    return code;
}

static bool signer_matches(SecStaticCodeRef code, CFStringRef *team) {
    SecCodeRef self = NULL;
    CFDictionaryRef self_info = NULL, target_info = NULL;
    bool valid = false;
    *team = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess) goto done;
    if (SecCodeCopySigningInformation(self, kSecCSSigningInformation, &self_info) != errSecSuccess) goto done;
    if (SecCodeCopySigningInformation(code, kSecCSSigningInformation, &target_info) != errSecSuccess) goto done;
    CFStringRef own_team = CFDictionaryGetValue(self_info, kSecCodeInfoTeamIdentifier);
    CFStringRef target_team = CFDictionaryGetValue(target_info, kSecCodeInfoTeamIdentifier);
    if (own_team && target_team && CFEqual(own_team, target_team)) {
        *team = CFRetain(own_team);
        valid = true;
    } else if (JORT_JS_ALLOW_ADHOC && !own_team && !target_team) {
        CFNumberRef self_flags = CFDictionaryGetValue(self_info, kSecCodeInfoFlags);
        CFNumberRef target_flags = CFDictionaryGetValue(target_info, kSecCodeInfoFlags);
        uint32_t a = 0, b = 0;
        valid = self_flags && target_flags && CFNumberGetValue(self_flags, kCFNumberSInt32Type, &a)
            && CFNumberGetValue(target_flags, kCFNumberSInt32Type, &b) && (a & kSecCodeSignatureAdhoc)
            && (b & kSecCodeSignatureAdhoc);
    }
done:
    if (self) CFRelease(self);
    if (self_info) CFRelease(self_info);
    if (target_info) CFRelease(target_info);
    return valid;
}

bool jort_broker_copy_app_requirement(char *requirement, size_t capacity) {
    SecCodeRef self = NULL;
    CFDictionaryRef information = NULL;
    CFStringRef text = NULL;
    bool valid = false;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess
        || SecCodeCopySigningInformation(self, kSecCSSigningInformation, &information) != errSecSuccess) goto done;
    CFStringRef identifier = CFDictionaryGetValue(information, kSecCodeInfoIdentifier);
    if (!identifier || !CFEqual(identifier, CFSTR(JORT_BROKER_IDENTIFIER))) goto done;
    CFStringRef team = CFDictionaryGetValue(information, kSecCodeInfoTeamIdentifier);
    if (team) {
        text = CFStringCreateWithFormat(NULL, NULL,
            CFSTR("anchor apple generic and identifier \"%s\" and certificate leaf[subject.OU] = \"%@\""),
            JORT_APP_IDENTIFIER, team);
    } else if (JORT_JS_ALLOW_ADHOC) {
        CFNumberRef flags = CFDictionaryGetValue(information, kSecCodeInfoFlags);
        uint32_t value = 0;
        if (!flags || !CFNumberGetValue(flags, kCFNumberSInt32Type, &value)
            || !(value & kSecCodeSignatureAdhoc)) goto done;
        text = CFStringCreateWithFormat(NULL, NULL, CFSTR("identifier \"%s\""),
            JORT_APP_IDENTIFIER);
    }
    valid = text && CFStringGetCString(text, requirement, (CFIndex)capacity, kCFStringEncodingUTF8);
done:
    if (text) CFRelease(text);
    if (information) CFRelease(information);
    if (self) CFRelease(self);
    return valid;
}

bool jort_broker_verified_worker_path(char *path, size_t capacity) {
    char broker[PATH_MAX], worker[PATH_MAX], resolved[PATH_MAX];
    if (!bundle_paths(broker, worker) || !realpath(worker, resolved) || strcmp(worker, resolved) != 0) return false;
    SecStaticCodeRef bundle = checked_code(broker, JORT_BROKER_IDENTIFIER, true);
    if (!bundle) return false;
    SecStaticCodeRef code = checked_code(worker, JORT_WORKER_IDENTIFIER, false);
    CFStringRef team = NULL;
    bool valid = code && signer_matches(code, &team);
    if (team) CFRelease(team);
    if (code) CFRelease(code);
    CFRelease(bundle);
    return valid && snprintf(path, capacity, "%s", worker) < (int)capacity;
}
