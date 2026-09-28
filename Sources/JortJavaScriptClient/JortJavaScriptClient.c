#include "JortJavaScriptClient.h"
#include "JortJavaScriptProtocol.h"
#include <Block.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

#ifndef JORT_JS_ALLOW_ADHOC
#define JORT_JS_ALLOW_ADHOC 0
#endif

struct JortJSClient {
    atomic_uint references;
    atomic_bool started;
    dispatch_queue_t queue;
    xpc_connection_t connection;
    dispatch_source_t timer;
    JortJSClientCompletion completion;
    bool cancelled, finished;
    uint8_t nonce[16], invocation[16];
    uint8_t generation[16];
    uint32_t output_bytes, output_lines;
};
static void retain(JortJSClient *c) { atomic_fetch_add(&c->references, 1); }
void jort_js_client_release(JortJSClient *c) {
    if (c && atomic_fetch_sub(&c->references, 1) == 1) {
        dispatch_release(c->queue);
        free(c);
    }
}
static void finalized(void *c) { jort_js_client_release(c); }
JortJSClient *jort_js_client_create(void) {
    JortJSClient *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    atomic_init(&c->references, 1); atomic_init(&c->started, false);
    c->queue = dispatch_queue_create("dev.jort.javascript.client", DISPATCH_QUEUE_SERIAL);
    return c;
}

static bool broker_requirement(char *buffer, size_t capacity) {
    CFBundleRef app = CFBundleGetMainBundle();
    CFURLRef app_url = app ? CFBundleCopyBundleURL(app) : NULL;
    CFURLRef contents_url = app_url ? CFURLCreateCopyAppendingPathComponent(NULL, app_url,
        CFSTR("Contents"), true) : NULL;
    CFURLRef services_url = contents_url ? CFURLCreateCopyAppendingPathComponent(NULL, contents_url,
        CFSTR("XPCServices"), true) : NULL;
    CFURLRef broker_url = services_url ? CFURLCreateCopyAppendingPathComponent(NULL, services_url,
        CFSTR("JortJavaScriptBroker.xpc"), true) : NULL;
    SecStaticCodeRef code = NULL;
    SecCodeRef self = NULL;
    CFDictionaryRef own = NULL, target = NULL;
    SecRequirementRef designated = NULL;
    CFStringRef text = NULL;
    bool valid = false;
    if (!broker_url || SecStaticCodeCreateWithPath(broker_url, 0, &code) != errSecSuccess ||
        SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckAllArchitectures, NULL) != errSecSuccess ||
        SecCodeCopySelf(0, &self) != errSecSuccess ||
        SecCodeCopySigningInformation(self, kSecCSSigningInformation, &own) != errSecSuccess ||
        SecCodeCopySigningInformation(code, kSecCSSigningInformation, &target) != errSecSuccess) goto done;
    CFStringRef identifier = CFDictionaryGetValue(target, kSecCodeInfoIdentifier);
    if (!identifier || !CFEqual(identifier, CFSTR("dev.jort.javascript.broker"))) goto done;
    CFStringRef own_team = CFDictionaryGetValue(own, kSecCodeInfoTeamIdentifier);
    CFStringRef target_team = CFDictionaryGetValue(target, kSecCodeInfoTeamIdentifier);
    if (own_team && target_team && CFEqual(own_team, target_team)) {
        text = CFStringCreateWithFormat(NULL, NULL, CFSTR("anchor apple generic and identifier \"dev.jort.javascript.broker\" and certificate leaf[subject.OU] = \"%@\""), own_team);
    } else if (JORT_JS_ALLOW_ADHOC && !own_team && !target_team) {
        CFNumberRef a = CFDictionaryGetValue(own, kSecCodeInfoFlags);
        CFNumberRef b = CFDictionaryGetValue(target, kSecCodeInfoFlags);
        uint32_t af = 0, bf = 0;
        if (!a || !b || !CFNumberGetValue(a, kCFNumberSInt32Type, &af) ||
            !CFNumberGetValue(b, kCFNumberSInt32Type, &bf) ||
            !(af & kSecCodeSignatureAdhoc) || !(bf & kSecCodeSignatureAdhoc)) goto done;
        if (SecCodeCopyDesignatedRequirement(code, 0, &designated) != errSecSuccess ||
            SecRequirementCopyString(designated, 0, &text) != errSecSuccess) goto done;
    }
    valid = text && CFStringGetCString(text, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
done:
    if (text) CFRelease(text);
    if (designated) CFRelease(designated);
    if (target) CFRelease(target);
    if (own) CFRelease(own);
    if (self) CFRelease(self);
    if (code) CFRelease(code);
    if (broker_url) CFRelease(broker_url);
    if (services_url) CFRelease(services_url);
    if (contents_url) CFRelease(contents_url);
    if (app_url) CFRelease(app_url);
    return valid;
}

static void finish(JortJSClient *c, uint32_t status, const uint8_t *output,
                   size_t output_length, const uint8_t *error, size_t error_length) {
    if (c->finished) return;
    c->finished = true;
    if (c->timer) { dispatch_source_cancel(c->timer); dispatch_release(c->timer); c->timer = NULL; }
    if (c->connection) { xpc_connection_cancel(c->connection); xpc_release(c->connection); c->connection = NULL; }
    if (c->completion) {
        JortJSClientCompletion completion = c->completion;
        c->completion = NULL;
        completion(status, output, output_length, error, error_length);
        Block_release(completion);
    }
}
static void fail(JortJSClient *c, uint32_t status) {
    static const uint8_t message[] = "JavaScript worker failed.";
    finish(c, status, NULL, 0, message, sizeof(message) - 1);
}
void jort_js_client_cancel(JortJSClient *c) {
    if (!c) return;
    retain(c);
    dispatch_async(c->queue, ^{
        c->cancelled = true;
        if (c->completion) fail(c, JORT_JS_CANCELLED);
        jort_js_client_release(c);
    });
}

static void reply(JortJSClient *c, xpc_object_t message) {
    if (c->finished) return;
    if (xpc_get_type(message) == XPC_TYPE_ERROR) { fail(c, JORT_JS_UNAVAILABLE); return; }
    static const char *const keys[] = {"version", "nonce", "invocation", "generation", "status", "output", "error"};
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_count(message) != 7) {
        fail(c, JORT_JS_PROTOCOL); return;
    }
    __block bool valid = true;
    xpc_dictionary_apply(message, ^bool(const char *key, xpc_object_t value) {
        unsigned i = 0; while (i < 7 && strcmp(key, keys[i])) i++;
        bool data = i == 1 || i == 2 || i == 3 || i == 5 || i == 6;
        valid = i < 7 && xpc_get_type(value) == (data ? XPC_TYPE_DATA : XPC_TYPE_UINT64);
        return valid;
    });
    size_t nn = 0, ni = 0, ng = 0, no = 0, ne = 0;
    const void *nonce = xpc_dictionary_get_data(message, "nonce", &nn);
    const void *invocation = xpc_dictionary_get_data(message, "invocation", &ni);
    const void *generation = xpc_dictionary_get_data(message, "generation", &ng);
    const uint8_t *output = xpc_dictionary_get_data(message, "output", &no);
    const uint8_t *error = xpc_dictionary_get_data(message, "error", &ne);
    uint64_t status = xpc_dictionary_get_uint64(message, "status");
    if (!valid || xpc_dictionary_get_uint64(message, "version") != JORT_JS_VERSION ||
        nn != 16 || ni != 16 || memcmp(nonce, c->nonce, 16) || memcmp(invocation, c->invocation, 16) ||
        ng != 16 || memcmp(generation, c->generation, 16) || status > JORT_JS_ENGINE_LIMIT ||
        no > c->output_bytes || ne > JORT_JS_ERROR_MAX ||
        (status == JORT_JS_OK ? ne != 0 : no != 0 || ne == 0) ||
        !jort_js_utf8_valid(output, no) || !jort_js_utf8_valid(error, ne)) { fail(c, JORT_JS_PROTOCOL); return; }
    if (!jort_js_lines_valid(output, no, c->output_lines)) { fail(c, JORT_JS_OUTPUT_LIMIT); return; }
    finish(c, (uint32_t)status, output, no, error, ne);
}

void jort_js_client_send(JortJSClient *c, const JortJSClientRequest *r,
                         JortJSClientCompletion completion) {
    if (!c || !completion || atomic_exchange(&c->started, true)) return;
    JortJSFrame f = {0};
    bool valid = r && r->nonce && r->invocation && r->generation;
    if (valid) {
        f.kind = JORT_JS_REQUEST; f.tag = r->operation;
        memcpy(f.generation, r->generation, 16);
        memcpy(f.nonce, r->nonce, 16); memcpy(f.invocation, r->invocation, 16);
        f.deadline_ms = r->deadline_ms; f.output_bytes = r->output_bytes; f.output_lines = r->output_lines;
        const uint8_t *fields[] = {r->contract, r->source, r->input, r->clock, r->uuid};
        size_t lengths[] = {r->contract_length, r->source_length, r->input_length, r->clock_length, r->uuid_length};
        for (unsigned i = 0; i < 5; i++) {
            if (lengths[i] > UINT32_MAX) valid = false;
            f.fields[i] = (uint8_t *)fields[i]; f.lengths[i] = (uint32_t)lengths[i];
        }
        valid = valid && jort_js_frame_validate(&f) == JORT_JS_IO_OK;
    }
    xpc_object_t message = valid ? xpc_dictionary_create(NULL, NULL, 0) : NULL;
    if (message) {
        xpc_dictionary_set_uint64(message, "version", JORT_JS_VERSION);
        xpc_dictionary_set_uint64(message, "operation", f.tag);
        xpc_dictionary_set_data(message, "nonce", f.nonce, 16);
        xpc_dictionary_set_data(message, "invocation", f.invocation, 16);
        xpc_dictionary_set_data(message, "generation", f.generation, 16);
        xpc_dictionary_set_uint64(message, "deadlineMilliseconds", f.deadline_ms);
        xpc_dictionary_set_uint64(message, "outputBytes", f.output_bytes);
        xpc_dictionary_set_uint64(message, "outputLines", f.output_lines);
        const char *keys[] = {"contract", "source", "input", "clock", "uuid"};
        for (unsigned i = 0; i < 5; i++) xpc_dictionary_set_data(message, keys[i], f.fields[i], f.lengths[i]);
    }
    retain(c);
    // Captured frame contains borrowed pointers; only scalar identity/limits are
    // read asynchronously. All payload data above is already owned by XPC.
    dispatch_async(c->queue, ^{
        c->completion = Block_copy(completion);
        memcpy(c->nonce, f.nonce, 16); memcpy(c->invocation, f.invocation, 16);
        memcpy(c->generation, f.generation, 16);
        c->output_bytes = f.output_bytes; c->output_lines = f.output_lines;
        char requirement[4096];
        if (c->cancelled) fail(c, JORT_JS_CANCELLED);
        else if (!message) fail(c, JORT_JS_PROTOCOL);
        else if (!broker_requirement(requirement, sizeof(requirement))) fail(c, JORT_JS_IDENTITY);
        else {
            c->connection = xpc_connection_create("dev.jort.javascript.broker", c->queue);
            if (!c->connection) fail(c, JORT_JS_UNAVAILABLE);
            else if (xpc_connection_set_peer_code_signing_requirement(c->connection, requirement) != 0) {
                // A newly created connection is suspended; balance it before
                // cancellation/release even when peer policy installation fails.
                xpc_connection_set_event_handler(c->connection, ^(xpc_object_t event) { (void)event; });
                xpc_connection_resume(c->connection);
                fail(c, JORT_JS_IDENTITY);
            }
            else {
                retain(c);
                xpc_connection_set_context(c->connection, c);
                xpc_connection_set_finalizer_f(c->connection, finalized);
                xpc_connection_set_event_handler(c->connection, ^(xpc_object_t event) {
                    if (xpc_get_type(event) == XPC_TYPE_ERROR) fail(c, JORT_JS_UNAVAILABLE);
                });
                c->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, c->queue);
                retain(c);
                dispatch_source_set_cancel_handler(c->timer, ^{ jort_js_client_release(c); });
                dispatch_source_set_event_handler(c->timer, ^{ fail(c, JORT_JS_TIMEOUT); });
                dispatch_source_set_timer(c->timer, dispatch_time(DISPATCH_TIME_NOW,
                    ((int64_t)f.deadline_ms + 3500) * NSEC_PER_MSEC), DISPATCH_TIME_FOREVER, NSEC_PER_MSEC);
                dispatch_resume(c->timer);
                xpc_connection_resume(c->connection);
                retain(c);
                xpc_connection_send_message_with_reply(c->connection, message, c->queue, ^(xpc_object_t response) {
                    reply(c, response); jort_js_client_release(c);
                });
            }
        }
        if (message) xpc_release(message);
        jort_js_client_release(c);
    });
}
