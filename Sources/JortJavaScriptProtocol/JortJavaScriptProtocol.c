#include "JortJavaScriptProtocol.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static uint32_t get32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static void put32(uint8_t *p, uint32_t n) {
    p[0] = n >> 24; p[1] = n >> 16; p[2] = n >> 8; p[3] = n;
}
void jort_js_clear(void *bytes, size_t length) {
    volatile uint8_t *p = bytes;
    while (length--) *p++ = 0;
}
int jort_js_lines_valid(const uint8_t *bytes, size_t length, size_t maximum) {
    size_t lines = 1;
    for (size_t i = 0; i < length; ++i) {
        uint8_t c = bytes[i];
        if (c == '\r' || (c == '\n' && (i == 0 || bytes[i - 1] != '\r')) ||
            (c == 0xc2 && i + 1 < length && bytes[i + 1] == 0x85) ||
            (c == 0xe2 && i + 2 < length && bytes[i + 1] == 0x80 &&
             (bytes[i + 2] == 0xa8 || bytes[i + 2] == 0xa9))) ++lines;
        if (lines > maximum) return 0;
    }
    return lines <= maximum;
}
double jort_js_monotonic(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// Strict UTF-8: no overlong forms, surrogate code points, NUL or out-of-range scalars.
int jort_js_utf8_valid(const uint8_t *s, size_t n) {
    if (!s && n) return 0;
    for (size_t i = 0; i < n;) {
        uint32_t c = s[i++], minimum;
        unsigned more;
        if (c == 0) return 0;
        if (c < 0x80) continue;
        if (c >= 0xc2 && c <= 0xdf) { c &= 0x1f; more = 1; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { c &= 0xf; more = 2; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { c &= 7; more = 3; minimum = 0x10000; }
        else return 0;
        if (more > n - i) return 0;
        while (more--) {
            uint8_t b = s[i++];
            if ((b & 0xc0) != 0x80) return 0;
            c = (c << 6) | (b & 0x3f);
        }
        if (c < minimum || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return 0;
    }
    return 1;
}

static int lengths_valid(const JortJSFrame *f) {
    uint64_t sum = JORT_JS_HEADER_SIZE;
    for (unsigned i = 0; i < JORT_JS_FIELD_COUNT; ++i) sum += f->lengths[i];
    if (f->kind == JORT_JS_REQUEST) {
        if (f->tag < JORT_JS_VALIDATE || f->tag > JORT_JS_VALIDATE_INPUT ||
            f->deadline_ms < 10 || f->deadline_ms > 30000 ||
            !f->output_bytes || f->output_bytes > JORT_JS_OUTPUT_MAX ||
            !f->output_lines || f->output_lines > JORT_JS_LINES_MAX ||
            !f->lengths[0] || f->lengths[0] > JORT_JS_CONTRACT_MAX ||
            !f->lengths[1] || f->lengths[1] > JORT_JS_SOURCE_MAX ||
            f->lengths[2] > JORT_JS_INPUT_MAX ||
            (uint64_t)f->lengths[3] + f->lengths[4] > JORT_JS_METADATA_MAX ||
            f->lengths[5] || sum > JORT_JS_REQUEST_MAX) return 0;
        if (f->tag == JORT_JS_VALIDATE && f->lengths[2]) return 0;
    } else if (f->kind == JORT_JS_RESPONSE) {
        if (f->tag > JORT_JS_ENGINE_LIMIT || f->deadline_ms || f->output_bytes || f->output_lines ||
            f->lengths[2] || f->lengths[3] || f->lengths[4] || f->lengths[5] ||
            f->lengths[0] > JORT_JS_OUTPUT_MAX || f->lengths[1] > JORT_JS_ERROR_MAX ||
            sum > JORT_JS_RESPONSE_MAX) return 0;
        if (f->tag == JORT_JS_OK ? f->lengths[1] != 0 : (f->lengths[0] != 0 || !f->lengths[1])) return 0;
    } else return 0;
    return 1;
}
int jort_js_frame_validate(const JortJSFrame *f) {
    if (!f || !lengths_valid(f)) return JORT_JS_IO_INVALID;
    for (unsigned i = 0; i < JORT_JS_FIELD_COUNT; ++i)
        if (!jort_js_utf8_valid(f->fields[i], f->lengths[i])) return JORT_JS_IO_INVALID;
    return JORT_JS_IO_OK;
}

static void payload_hash(const JortJSFrame *f, uint8_t hash[CC_SHA256_DIGEST_LENGTH]) {
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    for (unsigned i = 0; i < JORT_JS_FIELD_COUNT; ++i)
        if (f->lengths[i]) CC_SHA256_Update(&ctx, f->fields[i], f->lengths[i]);
    CC_SHA256_Final(hash, &ctx);
}
int jort_js_header_encode(const JortJSFrame *f, uint8_t h[JORT_JS_HEADER_SIZE]) {
    if (jort_js_frame_validate(f)) return JORT_JS_IO_INVALID;
    memset(h, 0, JORT_JS_HEADER_SIZE);
    memcpy(h, "JJS1", 4); h[5] = JORT_JS_VERSION; h[7] = f->kind;
    put32(h + 8, f->tag); memcpy(h + 12, f->nonce, 16); memcpy(h + 28, f->invocation, 16);
    memcpy(h + 44, f->generation, 8); memcpy(h + 88, f->generation + 8, 8);
    put32(h + 52, f->deadline_ms); put32(h + 56, f->output_bytes); put32(h + 60, f->output_lines);
    for (unsigned i = 0; i < JORT_JS_FIELD_COUNT; ++i) put32(h + 64 + 4 * i, f->lengths[i]);
    payload_hash(f, h + 96);
    return JORT_JS_IO_OK;
}
int jort_js_header_decode(const uint8_t h[JORT_JS_HEADER_SIZE], JortJSFrame *f) {
    memset(f, 0, sizeof(*f));
    if (memcmp(h, "JJS1", 4) || h[4] || h[5] != JORT_JS_VERSION || h[6]) return JORT_JS_IO_INVALID;
    f->kind = h[7]; f->tag = get32(h + 8);
    memcpy(f->nonce, h + 12, 16); memcpy(f->invocation, h + 28, 16);
    memcpy(f->generation, h + 44, 8); memcpy(f->generation + 8, h + 88, 8);
    f->deadline_ms = get32(h + 52); f->output_bytes = get32(h + 56); f->output_lines = get32(h + 60);
    for (unsigned i = 0; i < JORT_JS_FIELD_COUNT; ++i) f->lengths[i] = get32(h + 64 + 4 * i);
    return lengths_valid(f) ? JORT_JS_IO_OK : JORT_JS_IO_INVALID;
}

static int await_fd(int fd, short events, double deadline) {
    for (;;) {
        double remaining = deadline - jort_js_monotonic();
        if (remaining <= 0) return JORT_JS_IO_TIMEOUT;
        int millis = remaining >= INT_MAX / 1000.0 ? INT_MAX : (int)(remaining * 1000) + 1;
        struct pollfd p = { fd, events, 0 };
        int result = poll(&p, 1, millis);
        if (result > 0) {
            if (p.revents & POLLNVAL) return JORT_JS_IO_SYSTEM;
            // HUP is readable EOF; writes will fail promptly with EPIPE.
            if (p.revents & (events | POLLHUP | POLLERR)) return JORT_JS_IO_OK;
        } else if (result == 0) return JORT_JS_IO_TIMEOUT;
        else if (errno != EINTR) return JORT_JS_IO_SYSTEM;
    }
}
static int transfer(int fd, uint8_t *p, size_t n, double deadline, int writing) {
    while (n) {
        int result = await_fd(fd, writing ? POLLOUT : POLLIN, deadline);
        if (result) return result;
        // A bounded chunk fits macOS PIPE_BUF. Callers use nonblocking pipes for writes.
        size_t chunk = n > 512 ? 512 : n;
        ssize_t count = writing ? write(fd, p, chunk) : read(fd, p, chunk);
        if (count > 0) { p += count; n -= (size_t)count; }
        else if (count == 0) return JORT_JS_IO_CLOSED;
        else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) return JORT_JS_IO_SYSTEM;
    }
    return JORT_JS_IO_OK;
}
void jort_js_frame_destroy(JortJSFrame *f) {
    if (!f) return;
    for (unsigned i = 0; i < JORT_JS_FIELD_COUNT; ++i) {
        if (f->fields[i]) { jort_js_clear(f->fields[i], (size_t)f->lengths[i] + 1); free(f->fields[i]); }
    }
    memset(f, 0, sizeof(*f));
}
int jort_js_frame_read(int fd, JortJSFrame *f, double deadline) {
    uint8_t h[JORT_JS_HEADER_SIZE], hash[CC_SHA256_DIGEST_LENGTH];
    memset(f, 0, sizeof(*f));
    int result = transfer(fd, h, sizeof(h), deadline, 0);
    if (result) return result;
    result = jort_js_header_decode(h, f);
    if (result) return result;
    for (unsigned i = 0; i < JORT_JS_FIELD_COUNT; ++i) {
        if (!f->lengths[i]) continue;
        f->fields[i] = calloc((size_t)f->lengths[i] + 1, 1);
        if (!f->fields[i]) { result = JORT_JS_IO_MEMORY; goto failed; }
        result = transfer(fd, f->fields[i], f->lengths[i], deadline, 0);
        if (result) goto failed;
    }
    payload_hash(f, hash);
    if (memcmp(hash, h + 96, sizeof(hash)) || jort_js_frame_validate(f)) { result = JORT_JS_IO_INVALID; goto failed; }
    return JORT_JS_IO_OK;
failed:
    jort_js_frame_destroy(f);
    return result;
}
int jort_js_frame_write(int fd, const JortJSFrame *f, double deadline) {
    uint8_t h[JORT_JS_HEADER_SIZE];
    int result = jort_js_header_encode(f, h);
    if (result) return result;
    result = transfer(fd, h, sizeof(h), deadline, 1);
    for (unsigned i = 0; !result && i < JORT_JS_FIELD_COUNT; ++i)
        result = transfer(fd, f->fields[i], f->lengths[i], deadline, 1);
    return result;
}
int jort_js_expect_eof(int fd, double deadline) {
    uint8_t byte;
    int result = transfer(fd, &byte, 1, deadline, 0);
    return result == JORT_JS_IO_CLOSED ? JORT_JS_IO_OK : result == JORT_JS_IO_OK ? JORT_JS_IO_INVALID : result;
}
int jort_js_ready_write(int fd, const JortJSReady *ready, double deadline) {
    uint8_t bytes[JORT_JS_READY_SIZE] = { 'J', 'J', 'R', '1', 0, JORT_JS_VERSION, 0, JORT_JS_POLICY_VERSION };
    put32(bytes + 8, ready->status); put32(bytes + 12, ready->cpu_soft);
    put32(bytes + 16, ready->cpu_hard); put32(bytes + 20, ready->nofile);
    return transfer(fd, bytes, sizeof(bytes), deadline, 1);
}
int jort_js_ready_read(int fd, JortJSReady *ready, double deadline) {
    uint8_t bytes[JORT_JS_READY_SIZE];
    int result = transfer(fd, bytes, sizeof(bytes), deadline, 0);
    if (result) return result;
    if (memcmp(bytes, "JJR1", 4) || bytes[4] || bytes[5] != JORT_JS_VERSION || bytes[6] ||
        bytes[7] != JORT_JS_POLICY_VERSION) return JORT_JS_IO_INVALID;
    ready->status = get32(bytes + 8); ready->cpu_soft = get32(bytes + 12);
    ready->cpu_hard = get32(bytes + 16); ready->nofile = get32(bytes + 20);
    if (ready->status != JORT_JS_OK && ready->status != JORT_JS_BOOTSTRAP) return JORT_JS_IO_INVALID;
    if (ready->status == JORT_JS_OK && (!ready->cpu_soft || ready->cpu_soft > 30 ||
        ready->cpu_hard != ready->cpu_soft + 1 || ready->nofile != JORT_JS_NOFILE)) return JORT_JS_IO_INVALID;
    return JORT_JS_IO_OK;
}
