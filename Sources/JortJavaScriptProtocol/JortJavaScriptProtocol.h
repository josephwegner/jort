#ifndef JORT_JAVASCRIPT_PROTOCOL_H
#define JORT_JAVASCRIPT_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define JORT_JS_VERSION 1u
#define JORT_JS_POLICY_VERSION 1u
#define JORT_JS_HEADER_SIZE 128u
#define JORT_JS_READY_SIZE 24u
#define JORT_JS_FIELD_COUNT 6u
#define JORT_JS_CONTRACT_MAX 16384u
#define JORT_JS_SOURCE_MAX 262144u
#define JORT_JS_INPUT_MAX 1048576u
#define JORT_JS_METADATA_MAX 4096u
#define JORT_JS_REQUEST_MAX 1572864u
#define JORT_JS_OUTPUT_MAX 1048576u
#define JORT_JS_LINES_MAX 100000u
#define JORT_JS_ERROR_MAX 512u
#define JORT_JS_DIAGNOSTIC_MAX 4096u
#define JORT_JS_RESPONSE_MAX 1179648u
#define JORT_JS_HEAP_BYTES 16777216u
#define JORT_JS_STACK_BYTES 524288u
#define JORT_JS_NOFILE 16u
#define JORT_JS_CONCURRENCY 4u

enum { JORT_JS_REQUEST = 1, JORT_JS_RESPONSE = 2 };
enum { JORT_JS_VALIDATE = 1, JORT_JS_EXECUTE = 2, JORT_JS_VALIDATE_INPUT = 3 };
enum {
    JORT_JS_OK = 0, JORT_JS_IMPLEMENTATION = 1, JORT_JS_CANCELLED = 2,
    JORT_JS_TIMEOUT = 3, JORT_JS_OUTPUT_LIMIT = 4, JORT_JS_PROTOCOL = 5,
    JORT_JS_BOOTSTRAP = 6, JORT_JS_CPU_LIMIT = 7, JORT_JS_CRASH = 8,
    JORT_JS_UNAVAILABLE = 9, JORT_JS_BUSY = 10, JORT_JS_IDENTITY = 11,
    JORT_JS_LAUNCH = 12, JORT_JS_INTERNAL = 13, JORT_JS_ENGINE_LIMIT = 14
};
enum {
    JORT_JS_IO_OK = 0, JORT_JS_IO_INVALID = -1, JORT_JS_IO_TIMEOUT = -2,
    JORT_JS_IO_CLOSED = -3, JORT_JS_IO_SYSTEM = -4, JORT_JS_IO_MEMORY = -5
};

// The in-memory representation is never written directly. Wire integers are big endian;
// the generation UUID occupies bytes 44..51 and 88..95; SHA-256 is bytes 96..127.
// Request fields: normalized contract, source, exact content, clock, UUID, empty.
// Response fields: output (success) OR public error (failure); all others empty.
typedef struct {
    uint16_t kind;
    uint32_t tag;
    uint8_t nonce[16];
    uint8_t invocation[16];
    uint8_t generation[16];
    uint32_t deadline_ms;
    uint32_t output_bytes;
    uint32_t output_lines;
    uint32_t lengths[JORT_JS_FIELD_COUNT];
    uint8_t *fields[JORT_JS_FIELD_COUNT];
} JortJSFrame;

typedef struct {
    uint32_t status;
    uint32_t cpu_soft;
    uint32_t cpu_hard;
    uint32_t nofile;
} JortJSReady;

double jort_js_monotonic(void);
int jort_js_utf8_valid(const uint8_t *bytes, size_t length);
int jort_js_lines_valid(const uint8_t *bytes, size_t length, size_t maximum);
void jort_js_clear(void *bytes, size_t length);
int jort_js_frame_validate(const JortJSFrame *frame);
int jort_js_header_encode(const JortJSFrame *frame, uint8_t header[JORT_JS_HEADER_SIZE]);
int jort_js_header_decode(const uint8_t header[JORT_JS_HEADER_SIZE], JortJSFrame *frame);
int jort_js_frame_read(int fd, JortJSFrame *frame, double deadline);
int jort_js_frame_write(int fd, const JortJSFrame *frame, double deadline);
// Only use destroy for a frame allocated by frame_read; borrowed write fields remain owned by caller.
void jort_js_frame_destroy(JortJSFrame *frame);
int jort_js_expect_eof(int fd, double deadline);
int jort_js_ready_read(int fd, JortJSReady *ready, double deadline);
int jort_js_ready_write(int fd, const JortJSReady *ready, double deadline);

#endif
