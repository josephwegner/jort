#include "JortJavaScript.h"
#include "quickjs.h"
#include "ProtocolHelpers.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct JortJSCancellation { atomic_bool cancelled; };
typedef struct { double deadline; JortJSCancellation *token; int interrupted; } Run;
static double now(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
static int interrupt(JSRuntime *rt, void *opaque) {
    Run *run = opaque;
    if (atomic_load(&run->token->cancelled)) run->interrupted = 2;
    else if (now() >= run->deadline) run->interrupted = 3;
    return run->interrupted != 0;
}
static JSValue cancelled(JSContext *ctx, JSValueConst receiver, int argc, JSValueConst *argv) {
    Run *run = JS_GetRuntimeOpaque(JS_GetRuntime(ctx));
    return JS_NewBool(ctx, atomic_load(&run->token->cancelled));
}
JortJSCancellation *jort_js_cancellation_new(void) {
    JortJSCancellation *token = malloc(sizeof(*token));
    if (token) atomic_init(&token->cancelled, false);
    return token;
}
void jort_js_cancel(JortJSCancellation *token) { if (token) atomic_store(&token->cancelled, true); }
void jort_js_cancellation_free(JortJSCancellation *token) { free(token); }
void jort_js_free(char *value) { free(value); }
static char *exception(JSContext *ctx) {
    JSValue error = JS_GetException(ctx);
    // Never call a user-defined toString/getter while trying to report failure.
    JS_FreeValue(ctx, error);
    return strdup("JavaScript failed or exceeded its resource limit.");
}
static JSContext *context(JSRuntime *rt) {
    JSContext *ctx = JS_NewContextRaw(rt);
    if (!ctx) return NULL;
    if (JS_AddIntrinsicBaseObjects(ctx) || JS_AddIntrinsicEval(ctx) ||
        JS_AddIntrinsicJSON(ctx) || JS_AddIntrinsicMapSet(ctx) ||
        JS_AddIntrinsicPromise(ctx) || JS_AddIntrinsicStringNormalize(ctx) || JS_AddIntrinsicRegExp(ctx) ||
        JS_AddIntrinsicTypedArrays(ctx)) {
        JS_FreeContext(ctx); return NULL;
    }
    // Typed-array setup also registers shared-memory/Atomics intrinsics. Remove
    // those globals: pure text tools need neither blocking waits nor shared buffers.
    // No Date, random numbers, module loader, native exports, or I/O bindings.
    JSValue global = JS_GetGlobalObject(ctx);
    const char *excluded[] = { "Atomics", "SharedArrayBuffer" };
    for (size_t i = 0; i < sizeof(excluded) / sizeof(excluded[0]); ++i) {
        JSAtom key = JS_NewAtom(ctx, excluded[i]);
        JS_DeleteProperty(ctx, global, key, 0); JS_FreeAtom(ctx, key);
    }
    JSValue math = JS_GetPropertyStr(ctx, global, "Math");
    JSAtom random = JS_NewAtom(ctx, "random");
    JS_DeleteProperty(ctx, math, random, 0);
    JS_FreeAtom(ctx, random); JS_FreeValue(ctx, math); JS_FreeValue(ctx, global);
    return ctx;
}
char *jort_js_validate(const char *source) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return strdup("Unable to allocate JavaScript runtime.");
    JS_SetMemoryLimit(rt, 16 * 1024 * 1024); JS_SetMaxStackSize(rt, 512 * 1024);
    JSContext *ctx = context(rt);
    char *error = NULL;
    if (!ctx) error = strdup("Unable to allocate JavaScript context.");
    else {
        JSValue value = JS_Eval(ctx, source, strlen(source), "tool.js", JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
        if (JS_IsException(value)) error = exception(ctx);
        else if (!JS_IsToolModule(value)) error = strdup("A tool needs a default export and cannot import modules.");
        JS_FreeValue(ctx, value); JS_FreeContext(ctx);
    }
    JS_FreeRuntime(rt); return error;
}
static int line_limit(const char *bytes, size_t length, size_t maximum) {
    size_t lines = 1;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)bytes[i];
        if (c == '\r' || (c == '\n' && (i == 0 || bytes[i - 1] != '\r')) ||
            (c == 0xc2 && i + 1 < length && (unsigned char)bytes[i + 1] == 0x85) ||
            (c == 0xe2 && i + 2 < length && (unsigned char)bytes[i + 1] == 0x80 &&
             ((unsigned char)bytes[i + 2] == 0xa8 || (unsigned char)bytes[i + 2] == 0xa9))) ++lines;
        if (lines > maximum) return 0;
    }
    return 1;
}

static char *raw_result(JSContext *ctx, JSValueConst output, size_t byte_limit,
                        size_t lines, int *status) {
    if (!JS_IsObject(output)) return NULL;
    JSValue value = JS_GetPropertyStr(ctx, output, "output");
    JSValue error = JS_GetPropertyStr(ctx, output, "error");
    char *result = NULL;
    int has_output = JS_IsString(value), has_error = JS_IsString(error);
    if ((has_output && (JS_IsUndefined(error) || JS_IsNull(error))) ||
        (has_error && (JS_IsUndefined(value) || JS_IsNull(value)))) {
        size_t length = 0;
        const char *bytes = JS_ToCStringLen(ctx, &length, has_output ? value : error);
        if (bytes) {
            if (has_output && (length > byte_limit || !line_limit(bytes, length, lines))) {
                *status = 4;
                result = strdup("Output exceeds the tool limit.");
            } else if (memchr(bytes, 0, length)) {
                *status = 5;
                result = strdup("JavaScript returned an invalid result.");
            } else {
                // Public errors are truncated on UTF-8 scalar boundaries.
                if (has_error && length > 512) {
                    length = 512;
                    while (length && ((unsigned char)bytes[length] & 0xc0) == 0x80) --length;
                }
                if (has_error && length == 0) {
                    result = strdup("JavaScript failed.");
                } else {
                    result = malloc(length + 1);
                    if (result) { memcpy(result, bytes, length); result[length] = 0; }
                }
                if (result) *status = has_output ? 0 : 1;
            }
            JS_FreeCString(ctx, bytes);
        }
    }
    JS_FreeValue(ctx, value); JS_FreeValue(ctx, error);
    return result;
}

static char *structured_result(JSContext *ctx, JSValueConst output, JSValueConst helpers,
                               JSValueConst contract, const char *content,
                               size_t byte_limit, size_t lines, int *status) {
    JSValue checker = JS_GetPropertyStr(ctx, helpers, "result");
    JSValue captured = JS_NewString(ctx, content);
    JSValue arguments[] = { output, contract, captured };
    JSValue clean = JS_Call(ctx, checker, JS_UNDEFINED, 3, arguments);
    JS_FreeValue(ctx, captured);
    JS_FreeValue(ctx, checker);
    char *result = NULL;
    if (JS_IsException(clean)) { *status = 5; goto done; }
    JSValue error = JS_GetPropertyStr(ctx, clean, "error");
    if (JS_IsString(error)) {
        JS_FreeValue(ctx, error);
        result = raw_result(ctx, clean, byte_limit, lines, status);
        goto done;
    }
    JS_FreeValue(ctx, error);
    JSValue text = JS_GetPropertyStr(ctx, clean, "output");
    if (JS_IsUndefined(text)) { JS_FreeValue(ctx, text); text = JS_GetPropertyStr(ctx, clean, "report"); }
    if (JS_IsUndefined(text)) {
        JS_FreeValue(ctx, text);
        JSValue action = JS_GetPropertyStr(ctx, clean, "action");
        text = JS_GetPropertyStr(ctx, action, "content"); JS_FreeValue(ctx, action);
    }
    size_t length = 0;
    const char *bytes = JS_ToCStringLen(ctx, &length, text);
    if (!bytes || length > byte_limit || !line_limit(bytes, length, lines)) {
        *status = 4; result = strdup("Output exceeds the tool limit.");
    }
    if (bytes) JS_FreeCString(ctx, bytes);
    JS_FreeValue(ctx, text);
    if (result) goto done;
    JSValue json = JS_JSONStringify(ctx, clean, JS_UNDEFINED, JS_UNDEFINED);
    bytes = JS_IsException(json) ? NULL : JS_ToCStringLen(ctx, &length, json);
    // JSON escaping can expand valid text; the response envelope is an independent limit.
    if (bytes && length <= 1179520) {
        result = malloc(length + 1);
        if (result) { memcpy(result, bytes, length); result[length] = 0; *status = 0; }
    } else { *status = 4; result = strdup("Serialized result exceeds the response limit."); }
    if (bytes) JS_FreeCString(ctx, bytes);
    JS_FreeValue(ctx, json);
done:
    JS_FreeValue(ctx, clean);
    if (!result && *status == 5) result = strdup("JavaScript returned an invalid result.");
    return result;
}

static char *run(const char *source, const char *input_json, const char *content,
                  const char *clock, const char *uuid, const char *contract_json,
                  const char *metadata_json, const char *entry, size_t memory_limit,
                  double timeout_seconds, size_t result_limit, size_t output_lines,
                  JortJSCancellation *token, int *status) {
    *status = 1;
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return strdup("Unable to allocate JavaScript runtime.");
    JS_SetMemoryLimit(rt, memory_limit); JS_SetMaxStackSize(rt, 512 * 1024);
    Run run = { now() + timeout_seconds, token, 0 };
    JS_SetRuntimeOpaque(rt, &run);
    JS_SetInterruptHandler(rt, interrupt, &run);
    JSContext *ctx = context(rt);
    char *result = NULL;
    if (!ctx) { JS_FreeRuntime(rt); return strdup("Unable to allocate JavaScript context."); }
    JSValue compiled = JS_Eval(ctx, source, strlen(source), "tool.js", JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    JSValue helpers = JS_UNDEFINED, contract = JS_UNDEFINED;
    JSValue input;
    if (input_json) input = JS_ParseJSON(ctx, input_json, strlen(input_json), "input.json");
    else {
        input = JS_NewObject(ctx);
        if (JS_SetPropertyStr(ctx, input, "content", JS_NewString(ctx, content)) < 0 ||
            JS_SetPropertyStr(ctx, input, "clock", JS_NewString(ctx, clock)) < 0 ||
            JS_SetPropertyStr(ctx, input, "uuid", JS_NewString(ctx, uuid)) < 0) {
            JS_FreeValue(ctx, input); input = JS_EXCEPTION;
        }
    }
    if (!JS_IsException(input)) {
        JSAtom key = JS_NewAtom(ctx, "cancelled");
        JS_DefinePropertyGetSet(ctx, input, key, JS_NewCFunction(ctx, cancelled, "get cancelled", 0), JS_UNDEFINED, JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE);
        JS_FreeAtom(ctx, key);
    }
    if (contract_json && !JS_IsException(input)) {
        helpers = JS_Eval(ctx, protocol_helpers, strlen(protocol_helpers), "protocol.js", JS_EVAL_TYPE_GLOBAL);
        contract = JS_ParseJSON(ctx, contract_json, strlen(contract_json), "contract.json");
        JSValue metadata = JS_ParseJSON(ctx, metadata_json && *metadata_json ? metadata_json : "{}",
          metadata_json && *metadata_json ? strlen(metadata_json) : 2, "metadata.json");
        JSValue prepare = JS_GetPropertyStr(ctx, helpers, "prepare");
        JSValue arguments[] = { contract, metadata, input, JS_NewBool(ctx, !strcmp(entry, "compile")) };
        JSValue prepared = JS_Call(ctx, prepare, JS_UNDEFINED, 4, arguments);
        JS_FreeValue(ctx, prepare); JS_FreeValue(ctx, metadata);
        if (JS_IsException(prepared)) { JS_FreeValue(ctx, input); input = JS_EXCEPTION; *status = 5; }
        else {
            JS_FreeValue(ctx, prepared);
            const char *keys[] = { "maximumInputBytes", "maximumOutputBytes", "maximumOutputLines" };
            int64_t limits[3] = {0};
            for (int i = 0; i < 3; ++i) {
                JSValue limit = JS_GetPropertyStr(ctx, contract, keys[i]);
                JS_ToInt64(ctx, &limits[i], limit); JS_FreeValue(ctx, limit);
            }
            if (strlen(content) > (size_t)limits[0] || strlen(clock) > 128 || strlen(uuid) != 36) {
                JS_FreeValue(ctx, input); input = JS_EXCEPTION; *status = 5;
            }
            if ((size_t)limits[1] < result_limit) result_limit = (size_t)limits[1];
            if ((size_t)limits[2] < output_lines) output_lines = (size_t)limits[2];
        }
    }
    const char *freeze_source = "(value => { const freeze = v => { if (v && typeof v === 'object') { for (const key of Object.keys(v)) freeze(v[key]); Object.freeze(v); } }; freeze(value); return value; })";
    JSValue freeze = JS_Eval(ctx, freeze_source, strlen(freeze_source), "host.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(compiled) || !JS_IsToolModule(compiled) || JS_IsException(input) || JS_IsException(freeze)) goto cleanup;
    JSValue frozen = JS_Call(ctx, freeze, JS_UNDEFINED, 1, &input);
    if (JS_IsException(frozen)) goto cleanup;
    JS_FreeValue(ctx, frozen);
    if (!strcmp(entry, "compile")) { result = strdup("{\"output\":\"\"}"); *status = 0; goto cleanup; }
    JSModuleDef *module = JS_VALUE_GET_PTR(compiled);
    JS_DisableEval(ctx);
    JSValue evaluated = JS_EvalFunction(ctx, JS_DupValue(ctx, compiled));
    if (JS_IsException(evaluated)) goto cleanup;
    while (JS_PromiseState(ctx, evaluated) == JS_PROMISE_PENDING && !interrupt(rt, &run)) {
        JSContext *job_ctx = NULL;
        if (JS_ExecutePendingJob(rt, &job_ctx) <= 0) { run.interrupted = 3; break; }
    }
    if (run.interrupted || JS_PromiseState(ctx, evaluated) == JS_PROMISE_REJECTED) {
        JS_FreeValue(ctx, evaluated); goto cleanup;
    }
    JS_FreeValue(ctx, evaluated);
    JSValue ns = JS_GetModuleNamespace(ctx, module);
    if (JS_IsException(ns)) goto cleanup;
    JSValue fn = JS_GetPropertyStr(ctx, ns, entry); JS_FreeValue(ctx, ns);
    if (!strcmp(entry, "validate") && JS_IsUndefined(fn)) {
        JS_FreeValue(ctx, fn); result = strdup(input_json || contract_json ? "{\"output\":\"\"}" : ""); *status = 0; goto cleanup;
    }
    JSValue promise = JS_Call(ctx, fn, JS_UNDEFINED, 1, &input); JS_FreeValue(ctx, fn);
    if (JS_IsException(promise)) { JS_FreeValue(ctx, promise); goto cleanup; }
    while (JS_PromiseState(ctx, promise) == JS_PROMISE_PENDING && !interrupt(rt, &run)) {
        JSContext *job_ctx = NULL;
        int jobs = JS_ExecutePendingJob(rt, &job_ctx);
        if (jobs < 0) break;
        if (jobs == 0) { run.interrupted = 3; break; }
    }
    if (!run.interrupted && JS_PromiseState(ctx, promise) == JS_PROMISE_FULFILLED) {
        JSValue output = JS_PromiseResult(ctx, promise);
        JSValue json = input_json && !contract_json ? JS_JSONStringify(ctx, output, JS_UNDEFINED, JS_UNDEFINED) : JS_UNDEFINED;
        if (contract_json && !interrupt(rt, &run)) {
            result = structured_result(ctx, output, helpers, contract, content, result_limit, output_lines, status);
        } else if (!input_json && !interrupt(rt, &run)) {
            result = raw_result(ctx, output, result_limit, output_lines, status);
        }
        if (input_json && !contract_json && !JS_IsException(json)) {
            size_t length; const char *bytes = JS_ToCStringLen(ctx, &length, json);
            if (bytes && length <= result_limit && !interrupt(rt, &run)) {
                result = malloc(length + 1);
                if (result) { memcpy(result, bytes, length); result[length] = 0; *status = 0; }
            }
            if (bytes) JS_FreeCString(ctx, bytes);
        }
        JS_FreeValue(ctx, json); JS_FreeValue(ctx, output);
    }
    JS_FreeValue(ctx, promise);
cleanup:
    if (!result) result = exception(ctx);
    if (run.interrupted) *status = run.interrupted;
    JS_FreeValue(ctx, freeze); JS_FreeValue(ctx, input); JS_FreeValue(ctx, compiled);
    JS_FreeValue(ctx, helpers); JS_FreeValue(ctx, contract);
    JS_FreeContext(ctx); JS_FreeRuntime(rt);
    return result;
}

char *jort_js_run(const char *source, const char *input_json, const char *entry, size_t memory_limit,
                  double timeout_seconds, size_t result_limit, JortJSCancellation *token, int *status) {
    return run(source, input_json, NULL, NULL, NULL, NULL, NULL, entry, memory_limit,
               timeout_seconds, result_limit, 100000, token, status);
}

char *jort_js_run_text(const char *source, const char *content, const char *clock,
                      const char *uuid, const char *entry, double timeout_seconds,
                      size_t output_bytes, size_t output_lines, JortJSCancellation *token,
                      int *status) {
    return run(source, NULL, content, clock, uuid, NULL, NULL, entry, 16 * 1024 * 1024,
               timeout_seconds, output_bytes, output_lines, token, status);
}

char *jort_js_run_captured(const char *source, const char *content, const char *clock,
                         const char *uuid, const char *contract, const char *metadata,
                         const char *entry, double timeout_seconds, size_t output_bytes,
                         size_t output_lines, JortJSCancellation *token, int *status) {
    return run(source, NULL, content, clock, uuid, contract, metadata, entry, 16 * 1024 * 1024,
               timeout_seconds, output_bytes, output_lines, token, status);
}
