#import <Security/Security.h>
#include <stdio.h>

static BOOL JortProbeSigningConfiguration(NSDictionary<NSString *, NSString *> *environment,
    NSString **identity, NSString **team, NSString **failure) {
    NSString *configuredIdentity = environment[@"JORT_CONTAINMENT_SIGNING_IDENTITY"];
    NSString *configuredTeam = environment[@"JORT_CONTAINMENT_TEAM_ID"];
    if (!configuredIdentity && !configuredTeam) {
        *identity = nil;
        *team = nil;
        return YES;
    }
    NSRegularExpression *identityPattern = [NSRegularExpression regularExpressionWithPattern:@"^[A-Fa-f0-9]{40}$"
        options:0 error:nil];
    NSRegularExpression *teamPattern = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9]{10}$"
        options:0 error:nil];
    BOOL validIdentity = configuredIdentity && [identityPattern numberOfMatchesInString:configuredIdentity
        options:0 range:NSMakeRange(0, configuredIdentity.length)] == 1;
    BOOL validTeam = configuredTeam && [teamPattern numberOfMatchesInString:configuredTeam
        options:0 range:NSMakeRange(0, configuredTeam.length)] == 1;
    if (!validIdentity || !validTeam) {
        *failure = @"Set both JORT_CONTAINMENT_SIGNING_IDENTITY (40 hex characters) and JORT_CONTAINMENT_TEAM_ID (10 alphanumeric characters), or unset both.";
        return NO;
    }
    *identity = configuredIdentity;
    *team = configuredTeam;
    return YES;
}

static BOOL JortProbeSign(NSURL *codeURL, NSString *identity, NSString *identifier,
    NSURL *entitlementsURL, NSString *team, NSString **failure) {
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"--force", @"--sign",
        identity ?: @"-", nil];
    if (identifier) [arguments addObjectsFromArray:@[@"--identifier", identifier]];
    if (entitlementsURL) [arguments addObjectsFromArray:@[@"--entitlements", entitlementsURL.path]];
    [arguments addObjectsFromArray:@[@"--options", @"runtime", @"--timestamp=none", codeURL.path]];

    NSTask *sign = [NSTask new];
    sign.executableURL = [NSURL fileURLWithPath:@"/usr/bin/codesign"];
    sign.arguments = arguments;
    NSPipe *diagnostics = NSPipe.pipe;
    sign.standardOutput = diagnostics;
    sign.standardError = diagnostics;
    NSError *launchError = nil;
    if (![sign launchAndReturnError:&launchError]) {
        *failure = launchError.localizedDescription;
        return NO;
    }
    [sign waitUntilExit];
    NSData *signOutput = [diagnostics.fileHandleForReading readDataToEndOfFile];
    NSString *signDiagnostic = [[NSString alloc] initWithData:signOutput encoding:NSUTF8StringEncoding] ?: @"";
    if (sign.terminationStatus != 0) {
        *failure = [NSString stringWithFormat:@"codesign exited %d: %@", sign.terminationStatus, signDiagnostic];
        return NO;
    }
    if (!team) return YES;

    SecStaticCodeRef staticCode = NULL;
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)codeURL, kSecCSDefaultFlags, &staticCode);
    CFDictionaryRef information = NULL;
    if (status == errSecSuccess) status = SecCodeCopySigningInformation((SecCodeRef)staticCode,
        kSecCSSigningInformation, &information);
    NSDictionary *signing = CFBridgingRelease(information);
    NSArray *certificates = signing[(id)kSecCodeInfoCertificates];
    NSString *actualTeam = signing[(id)kSecCodeInfoTeamIdentifier];
    SecCertificateRef leaf = certificates.count ? (__bridge SecCertificateRef)certificates.firstObject : NULL;
    NSString *leafSummary = leaf ? CFBridgingRelease(SecCertificateCopySubjectSummary(leaf)) : nil;
    NSString *requirementText = [NSString stringWithFormat:
        @"anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"%@\"",
        team];
    SecRequirementRef requirement = NULL;
    if (status == errSecSuccess) status = SecRequirementCreateWithString((__bridge CFStringRef)requirementText,
        kSecCSDefaultFlags, &requirement);
    if (status == errSecSuccess) status = SecStaticCodeCheckValidity(staticCode,
        kSecCSStrictValidate, requirement);
    if (requirement) CFRelease(requirement);
    BOOL developerID = [leafSummary hasPrefix:@"Developer ID Application:"];
    if (staticCode) CFRelease(staticCode);
    if (status != errSecSuccess || !developerID || ![actualTeam isEqualToString:team]) {
        *failure = [NSString stringWithFormat:@"strict Developer ID signature check failed (status %d, certificate=%@, team=%@; expected %@)",
            (int)status, leafSummary ?: @"missing", actualTeam ?: @"missing", team];
        return NO;
    }
    // Public signing selectors make the retained test log distinguish a real
    // Developer ID qualification run from the default ad-hoc local fixtures.
    fprintf(stderr, "Sandbox probe verified Developer ID Application: Team %s, certificate %s\n",
        team.UTF8String, identity.UTF8String);
    fflush(stderr);
    return YES;
}
