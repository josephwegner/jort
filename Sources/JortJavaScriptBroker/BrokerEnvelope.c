#include "BrokerEnvelope.h"

#include <stdlib.h>
#include <string.h>

static const char *const keys[] = {
    "version", "operation", "nonce", "invocation", "generation", "contract", "source",
    "input", "clock", "uuid", "deadlineMilliseconds", "outputBytes", "outputLines", "metadata"
};
static const char *const payload_keys[] = {"contract", "source", "input", "clock", "uuid", "metadata"};

bool jort_broker_decode_request(xpc_object_t message, JortJSFrame *frame) {
    memset(frame, 0, sizeof(*frame));
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_count(message) != 14) return false;
    __block bool shape_valid = true;
    xpc_dictionary_apply(message, ^bool(const char *key, xpc_object_t value) {
        size_t index = 0;
        while (index < 14 && strcmp(key, keys[index]) != 0) index++;
        if (index == 14) { shape_valid = false; return false; }
        bool is_data = (index >= 2 && index <= 9) || index == 13;
        if (xpc_get_type(value) != (is_data ? XPC_TYPE_DATA : XPC_TYPE_UINT64)) shape_valid = false;
        return shape_valid;
    });
    if (!shape_valid || xpc_dictionary_get_uint64(message, "version") != JORT_JS_VERSION) return false;
    uint64_t operation = xpc_dictionary_get_uint64(message, "operation");
    uint64_t deadline = xpc_dictionary_get_uint64(message, "deadlineMilliseconds");
    uint64_t bytes = xpc_dictionary_get_uint64(message, "outputBytes");
    uint64_t lines = xpc_dictionary_get_uint64(message, "outputLines");
    if (operation < 1 || operation > 3 || deadline < 10 || deadline > 30000
        || bytes == 0 || bytes > 1024 * 1024 || lines == 0 || lines > 100000) return false;
    size_t nonce_length = 0, invocation_length = 0, generation_length = 0;
    const void *nonce = xpc_dictionary_get_data(message, "nonce", &nonce_length);
    const void *invocation = xpc_dictionary_get_data(message, "invocation", &invocation_length);
    const void *generation = xpc_dictionary_get_data(message, "generation", &generation_length);
    if (nonce_length != 16 || invocation_length != 16 || generation_length != 16) return false;
    const size_t maxima[] = {JORT_JS_CONTRACT_MAX, JORT_JS_SOURCE_MAX, JORT_JS_INPUT_MAX, JORT_JS_METADATA_MAX, 36, JORT_JS_METADATA_MAX};
    const void *payloads[JORT_JS_FIELD_COUNT];
    size_t lengths[JORT_JS_FIELD_COUNT], total = JORT_JS_HEADER_SIZE, metadata = 0;
    for (size_t i = 0; i < JORT_JS_FIELD_COUNT; i++) {
        payloads[i] = xpc_dictionary_get_data(message, payload_keys[i], &lengths[i]);
        if (lengths[i] > maxima[i] || lengths[i] > JORT_JS_REQUEST_MAX - total) return false;
        total += lengths[i];
        if (i >= 3) metadata += lengths[i];
    }
    if (metadata > JORT_JS_METADATA_MAX || lengths[0] == 0 || lengths[1] == 0 || lengths[4] != 36) return false;
    frame->kind = 1;
    frame->tag = (uint32_t)operation;
    memcpy(frame->nonce, nonce, 16);
    memcpy(frame->invocation, invocation, 16);
    memcpy(frame->generation, generation, 16);
    frame->deadline_ms = (uint32_t)deadline;
    frame->output_bytes = (uint32_t)bytes;
    frame->output_lines = (uint32_t)lines;
    for (size_t i = 0; i < JORT_JS_FIELD_COUNT; i++) {
        frame->lengths[i] = (uint32_t)lengths[i];
        if (!lengths[i]) continue;
        frame->fields[i] = calloc(lengths[i] + 1, 1);
        if (!frame->fields[i]) { jort_js_frame_destroy(frame); return false; }
        memcpy(frame->fields[i], payloads[i], lengths[i]);
    }
    return true;
}

xpc_object_t jort_broker_create_reply(xpc_object_t request, const JortJSFrame *response) {
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!reply) return NULL;
    xpc_dictionary_set_uint64(reply, "version", JORT_JS_VERSION);
    xpc_dictionary_set_data(reply, "nonce", response->nonce, 16);
    xpc_dictionary_set_data(reply, "invocation", response->invocation, 16);
    xpc_dictionary_set_data(reply, "generation", response->generation, 16);
    xpc_dictionary_set_uint64(reply, "status", response->tag);
    xpc_dictionary_set_data(reply, "output", response->fields[0], response->lengths[0]);
    const char *fallback = "JavaScript worker failed.";
    const void *error = response->fields[1];
    size_t error_length = response->lengths[1];
    if (response->tag != JORT_JS_OK && !error_length) {
        error = fallback; error_length = strlen(fallback);
    }
    xpc_dictionary_set_data(reply, "error", error, error_length);
    return reply;
}
