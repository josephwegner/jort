#ifndef JORT_JAVASCRIPT_CLIENT_H
#define JORT_JAVASCRIPT_CLIENT_H
#include <stddef.h>
#include <stdint.h>

typedef struct JortJSClient JortJSClient;
typedef struct {
    uint32_t operation;
    const uint8_t *nonce;
    const uint8_t *invocation;
    const uint8_t *generation;
    uint32_t deadline_ms, output_bytes, output_lines;
    const uint8_t *contract; size_t contract_length;
    const uint8_t *source; size_t source_length;
    const uint8_t *input; size_t input_length;
    const uint8_t *clock; size_t clock_length;
    const uint8_t *uuid; size_t uuid_length;
} JortJSClientRequest;
typedef void (^JortJSClientCompletion)(uint32_t status, const uint8_t *output,
    size_t output_length, const uint8_t *error, size_t error_length)
    __attribute__((swift_attr("@Sendable")));

// One send per client. send copies every request byte before returning. Completion
// runs once on a private serial queue; its byte pointers are valid only during it.
// cancel is safe before send. release relinquishes the caller's ownership; pending
// work retains the handle independently until all XPC/timer callbacks have drained.
JortJSClient *jort_js_client_create(void);
void jort_js_client_send(JortJSClient *client, const JortJSClientRequest *request,
                         JortJSClientCompletion completion);
void jort_js_client_cancel(JortJSClient *client);
void jort_js_client_release(JortJSClient *client);
#endif
