#include "JortJavaScript.h"
#include "quickjs.h"
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
        JS_AddIntrinsicPromise(ctx) || JS_AddIntrinsicStringNormalize(ctx)) {
        JS_FreeContext(ctx); return NULL;
    }
    // No Date, random numbers, module loader, native exports, or I/O bindings.
    JSValue global = JS_GetGlobalObject(ctx);
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
char *jort_js_run(const char *source, const char *input_json, const char *entry, size_t memory_limit,
                  double timeout_seconds, size_t result_limit, JortJSCancellation *token, int *status) {
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
    JSValue input = JS_ParseJSON(ctx, input_json, strlen(input_json), "input.json");
    if (!JS_IsException(input)) {
        JSAtom key = JS_NewAtom(ctx, "cancelled");
        JS_DefinePropertyGetSet(ctx, input, key, JS_NewCFunction(ctx, cancelled, "get cancelled", 0), JS_UNDEFINED, JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE);
        JS_FreeAtom(ctx, key);
    }
    const char *freeze_source = "(value => { Object.freeze(value); return value; })";
    JSValue freeze = JS_Eval(ctx, freeze_source, strlen(freeze_source), "host.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(compiled) || !JS_IsToolModule(compiled) || JS_IsException(input) || JS_IsException(freeze)) goto cleanup;
    JSValue frozen = JS_Call(ctx, freeze, JS_UNDEFINED, 1, &input);
    if (JS_IsException(frozen)) goto cleanup;
    JS_FreeValue(ctx, frozen);
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
        JS_FreeValue(ctx, fn); result = strdup("{\"output\":\"\"}"); *status = 0; goto cleanup;
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
        JSValue json = JS_JSONStringify(ctx, output, JS_UNDEFINED, JS_UNDEFINED);
        if (!JS_IsException(json)) {
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
    JS_FreeContext(ctx); JS_FreeRuntime(rt);
    return result;
}
